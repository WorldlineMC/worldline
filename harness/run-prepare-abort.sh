#!/usr/bin/env bash
# Scripted placeholder M2 prepare-abort round trip. This intentionally runs
# in-process against the proxy control skeleton until the real transport exists.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$repo_root/proxy"
./gradlew -q :velocity-proxy:testClasses
java -cp "proxy/build/classes/java/main:proxy/build/classes/java/test" \
    com.velocitypowered.proxy.worldline.HandoffControlPlaneDemo
