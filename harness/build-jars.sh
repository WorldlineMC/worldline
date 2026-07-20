#!/usr/bin/env bash
# Builds the proxy and server jars used by the slice harness.
# Run this before run-slice.sh or run-one.sh.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
revision_file="$repo_root/harness/.built-revisions"

echo "Applying server patches..."
(cd "$repo_root/server" && ./gradlew applyPatches)

echo "Building server jar (paper-server:createBundlerJar)..."
(cd "$repo_root/server" && ./gradlew :paper-server:createBundlerJar)

echo "Building proxy jar (velocity-proxy:shadowJar)..."
(cd "$repo_root/proxy" && ./gradlew :velocity-proxy:shadowJar)

printf 'proxy=%s\nserver=%s\n' \
    "$(git -C "$repo_root/proxy" rev-parse HEAD)" \
    "$(git -C "$repo_root/server" rev-parse HEAD)" > "$revision_file"

echo
echo "Built jars:"
ls -1 "$repo_root"/server/paper-server/build/libs/paper-bundler-*.jar
ls -1 "$repo_root"/proxy/proxy/build/libs/velocity-proxy-*-all.jar
