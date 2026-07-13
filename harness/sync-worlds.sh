#!/usr/bin/env bash
# Copy server-a's world to server-b so both backends serve identical terrain
# (docs/vertical-slice-roadmap.md M0). The client's already-loaded chunks stay
# valid across the M1/M5 backend splice only if the world files match.
# Run while both servers are stopped.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$repo_root/server/run/server-a/world"
dst="$repo_root/server/run/server-b/world"

[[ -d "$src" ]] || { echo "error: $src does not exist; boot the servers once to generate it" >&2; exit 1; }

for port in 25566 25567; do
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
        exec 3>&- || true
        echo "error: a server is listening on $port; stop the slice before syncing worlds" >&2
        exit 1
    fi
done

if [[ -d "$dst" ]]; then
    backup="$dst.pre-sync-backup"
    rm -rf "$backup"
    mv "$dst" "$backup"
    echo "Existing server-b world moved to $backup"
fi

rsync -a --exclude session.lock "$src/" "$dst/"
echo "server-a world copied to server-b ($(du -sh "$dst" | cut -f1))"
