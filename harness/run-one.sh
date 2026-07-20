#!/usr/bin/env bash
# Runs a single slice component (proxy, server-a, or server-b) in the foreground,
# so the three processes can live in separate terminals. Uses the same topology,
# config installation, and JVM flags as run-slice.sh.
# Build the jars first with harness/build-jars.sh.
set -euo pipefail

usage() {
    echo "usage: $0 proxy|server-a|server-b" >&2
    exit 2
}
[[ $# -eq 1 ]] || usage
component="$1"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
harness_dir="$repo_root/harness"
proxy_run_dir="$repo_root/proxy/proxy/run"
server_run_dir="$repo_root/server/run"
memory_gb="${WORLDLINE_RUN_MEMORY_GB:-2}"
revision_file="$harness_dir/.built-revisions"

[[ -f "$revision_file" ]] || { echo "error: build revision record not found; run harness/build-jars.sh" >&2; exit 1; }
expected_revisions=$(printf 'proxy=%s\nserver=%s' \
    "$(git -C "$repo_root/proxy" rev-parse HEAD)" \
    "$(git -C "$repo_root/server" rev-parse HEAD)")
actual_revisions=$(sed -e '${/^$/d;}' "$revision_file")
[[ "$actual_revisions" == "$expected_revisions" ]] || {
    echo "error: built jars do not match the checked-out submodules; run harness/build-jars.sh" >&2
    echo "built:    ${actual_revisions//$'\n'/, }" >&2
    echo "expected: ${expected_revisions//$'\n'/, }" >&2
    exit 1
}

case "$component" in
    proxy)    port=25565 ;;
    server-a) port=25566; control_port=25576; partition=west ;;
    server-b) port=25567; control_port=25577; partition=east ;;
    *) usage ;;
esac

if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
    exec 3>&- || true
    echo "error: port $port is already in use; is $component already running?" >&2
    exit 1
fi

if [[ "$component" == "proxy" ]]; then
    proxy_jar="$(ls "$repo_root"/proxy/proxy/build/libs/velocity-proxy-*-all.jar 2>/dev/null | head -1 || true)"
    [[ -n "$proxy_jar" ]] || { echo "error: proxy jar not found; build it with harness/build-jars.sh" >&2; exit 1; }

    mkdir -p "$proxy_run_dir"
    cp "$harness_dir/velocity.toml" "$proxy_run_dir/velocity.toml"
    cp "$harness_dir/forwarding.secret" "$proxy_run_dir/forwarding.secret"
    cp "$harness_dir/worldline.toml" "$proxy_run_dir/worldline.toml"
    cmp -s "$harness_dir/worldline.toml" "$proxy_run_dir/worldline.toml" || { echo "error: failed to install worldline.toml into $proxy_run_dir" >&2; exit 1; }

    echo "Starting proxy on port $port"
    cd "$proxy_run_dir"
    proxy_m1_flag=""
    if [[ "${WORLDLINE_M1_MANUAL_SPLICE:-0}" == "1" ]]; then
        proxy_m1_flag=-Dworldline.splice-target=server-b
    fi
    exec java -Xms512M -Xmx512M -Dworldline.config=worldline.toml \
        ${proxy_m1_flag:+"$proxy_m1_flag"} -Dworldline.m5.post-commit-timeout-seconds=10 \
        -Dworldline.trace=true -Dvelocity.packet-decode-logging=true -Dterminal.jline=false \
        -jar "$proxy_jar"
fi

if (exec 3<>"/dev/tcp/127.0.0.1/$control_port") 2>/dev/null; then
    exec 3>&- || true
    echo "error: control port $control_port is already in use" >&2
    exit 1
fi

server_jar="$(ls "$repo_root"/server/paper-server/build/libs/paper-bundler-*.jar 2>/dev/null | head -1 || true)"
[[ -n "$server_jar" ]] || { echo "error: server jar not found; build it with harness/build-jars.sh" >&2; exit 1; }

d="$server_run_dir/$component"
[[ -f "$d/eula.txt" ]] || { echo "error: $d is not initialized (missing eula.txt); run 'cd server && ./gradlew :paper-server:runServers' once first" >&2; exit 1; }

cp "$harness_dir/worldline.toml" "$d/worldline.toml"
cmp -s "$harness_dir/worldline.toml" "$d/worldline.toml" || { echo "error: failed to install worldline.toml into $d" >&2; exit 1; }
# The client's signed-chat session does not survive the M1 silent splice, so the slice
# runs with secure-profile enforcement off; see run-slice.sh and the harness README.
if grep -q '^enforce-secure-profile=' "$d/server.properties" 2>/dev/null; then
    sed -e 's/^enforce-secure-profile=.*/enforce-secure-profile=false/' "$d/server.properties" > "$d/server.properties.tmp"
    mv "$d/server.properties.tmp" "$d/server.properties"
else
    printf 'enforce-secure-profile=false\n' >> "$d/server.properties"
fi

resume=""
[[ "$component" == "server-b" ]] && resume=-Dworldline.resume=true

echo "Starting $component on port $port"
cd "$d"
exec java "-Xms${memory_gb}G" "-Xmx${memory_gb}G" \
    ${resume:+"$resume"} \
    -Dworldline.config=worldline.toml \
    -Dworldline.server-id="$component" \
    -Dworldline.partition-id="$partition" \
    -Dworldline.partition-epoch=1 \
    -Dworldline.compatibility-id=m5-vanilla-26.2-v1 \
    -Dworldline.control-port="$control_port" \
    -Dworldline.trace=true \
    -Dterminal.jline=false \
    -Dnet.kyori.adventure.text.warnWhenLegacyFormattingDetected=true \
    -Dio.papermc.paper.suppress.sout.nags=true \
    -jar "$server_jar" --nogui --port "$port"
