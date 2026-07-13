#!/usr/bin/env bash
# One-command boot for the vertical-slice topology (docs/vertical-slice-roadmap.md M0):
# one Worldline Proxy on 25565 and two Worldline Servers on 25566/25567.
# Requires previously built jars:
#   proxy:  (cd proxy && ./gradlew :velocity-proxy:shadowJar)   -> proxy/proxy/build/libs/velocity-proxy-*-all.jar
#   server: (cd server && ./gradlew :paper-server:createBundlerJar) -> server/paper-server/build/libs/paper-bundler-*.jar
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
harness_dir="$repo_root/harness"
log_dir="$harness_dir/logs"
proxy_run_dir="$repo_root/proxy/proxy/run"
server_run_dir="$repo_root/server/run"
memory_gb="${WORLDLINE_RUN_MEMORY_GB:-2}"

proxy_jar="$(ls "$repo_root"/proxy/proxy/build/libs/velocity-proxy-*-all.jar 2>/dev/null | head -1 || true)"
server_jar="$(ls "$repo_root"/server/paper-server/build/libs/paper-bundler-*.jar 2>/dev/null | head -1 || true)"

[[ -n "$proxy_jar" ]] || { echo "error: proxy jar not found; build it with: cd proxy && ./gradlew :velocity-proxy:shadowJar" >&2; exit 1; }
[[ -n "$server_jar" ]] || { echo "error: server jar not found; build it with: cd server && ./gradlew :paper-server:createBundlerJar" >&2; exit 1; }
for d in "$server_run_dir/server-a" "$server_run_dir/server-b"; do
    [[ -f "$d/eula.txt" ]] || { echo "error: $d is not initialized (missing eula.txt); run 'cd server && ./gradlew :paper-server:runServers' once first" >&2; exit 1; }
done

for port in 25565 25566 25567; do
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
        exec 3>&- || true
        echo "error: port $port is already in use; is the slice already running?" >&2
        exit 1
    fi
done

# The harness directory holds the canonical slice config; run dirs are
# gitignored scratch space, so install a fresh copy on every boot.
mkdir -p "$proxy_run_dir" "$log_dir"
cp "$harness_dir/velocity.toml" "$proxy_run_dir/velocity.toml"
cp "$harness_dir/forwarding.secret" "$proxy_run_dir/forwarding.secret"
cp "$harness_dir/worldline.toml" "$proxy_run_dir/worldline.toml"
for d in "$server_run_dir/server-a" "$server_run_dir/server-b"; do
    cp "$harness_dir/worldline.toml" "$d/worldline.toml"
    cmp -s "$harness_dir/worldline.toml" "$d/worldline.toml" || { echo "error: failed to install worldline.toml into $d" >&2; exit 1; }
done
cmp -s "$harness_dir/worldline.toml" "$proxy_run_dir/worldline.toml" || { echo "error: failed to install worldline.toml into $proxy_run_dir" >&2; exit 1; }

pids=()
touch "$log_dir/proxy.log" "$log_dir/server-a.log" "$log_dir/server-b.log"
tail -n 0 -F "$log_dir/proxy.log" "$log_dir/server-a.log" "$log_dir/server-b.log" &
pids+=($!)
cleanup() {
    trap - EXIT INT TERM
    echo "Stopping slice topology..."
    for pid in "${pids[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    echo "Slice topology stopped."
}
trap cleanup EXIT INT TERM

start_server() {
    local name="$1" port="$2"
    local resume=""
    [[ "$name" == "server-b" ]] && resume=-Dworldline.resume=true
    echo "Starting $name on port $port (log: $log_dir/$name.log)"
    (cd "$server_run_dir/$name" && exec java "-Xms${memory_gb}G" "-Xmx${memory_gb}G" \
        ${resume:+"$resume"} \
        -Dworldline.config=worldline.toml \
        -Dworldline.server-id="$name" \
        -Dterminal.jline=false \
        -Dnet.kyori.adventure.text.warnWhenLegacyFormattingDetected=true \
        -Dio.papermc.paper.suppress.sout.nags=true \
        -jar "$server_jar" --nogui --port "$port" </dev/null >"$log_dir/$name.log" 2>&1) &
    pids+=($!)
}

start_server server-a 25566
start_server server-b 25567

echo "Starting proxy on port 25565 (log: $log_dir/proxy.log)"
(cd "$proxy_run_dir" && exec java -Xms512M -Xmx512M -Dworldline.config=worldline.toml \
    -Dworldline.splice-target=server-b -Dvelocity.packet-decode-logging=true -Dterminal.jline=false \
    -jar "$proxy_jar" </dev/null >"$log_dir/proxy.log" 2>&1) &
pids+=($!)

wait_for_port() {
    local name="$1" port="$2" deadline=$((SECONDS + 180))
    until (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; do
        for pid in "${pids[@]}"; do
            if ! kill -0 "$pid" 2>/dev/null; then
                echo "error: a slice process exited before $name opened port $port; see $log_dir/*.log" >&2
                exit 1
            fi
        done
        if (( SECONDS >= deadline )); then
            echo "error: $name did not open port $port within 180s; see $log_dir/$name.log" >&2
            exit 1
        fi
        sleep 1
    done
    exec 3>&- || true
    echo "$name is listening on $port"
}

wait_for_port server-a 25566
wait_for_port server-b 25567
wait_for_port proxy 25565

echo
echo "Slice topology is up. Connect a client to 127.0.0.1:25565 (lands on server-a)."
echo "Press Ctrl-C to stop all three processes."
wait
