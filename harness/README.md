# Vertical-slice dev harness

Local two-node topology for the [vertical-slice roadmap](../docs/vertical-slice-roadmap.md) (M0): one Worldline Proxy on `25565`, `server-a` on `25566`, `server-b` on `25567`. Both servers run identical world files; the static partition boundary in `worldline.toml` splits the world at chunk X = 0.

Everything here is slice-only development tooling under the ADR 0005 experimental exception. The `forwarding.secret` is a local-development secret shared with each server's `config/paper-global.yml`; it protects nothing outside this harness.

## One-command boot

```sh
harness/run-slice.sh
```

Requires built jars and initialized server run directories:

```sh
cd server && ./gradlew :paper-server:createBundlerJar   # server jar
cd proxy  && ./gradlew :velocity-proxy:shadowJar        # proxy jar
cd server && ./gradlew :paper-server:runServers         # first-time run-dir init (accept EULA, generate world)
```

The script installs `velocity.toml`, `forwarding.secret`, and `worldline.toml` into the gitignored `proxy/proxy/run`, copies `worldline.toml` into both server run dirs, starts all three processes, waits until each port accepts connections, and tears everything down on Ctrl-C. Process output is shown live and retained in `harness/logs/`.

Connect a vanilla client to `127.0.0.1:25565`; you land on `server-a`.

For the M1 splice spike, stand still and run `/server server-b`. The proxy silently drives the
second backend connection and swaps packet routing without putting the client through configuration
or forwarding Paper's login packet. This manual path is deliberately limited to `server-a` to
`server-b`; restart the harness before repeating it.

## World sync

```sh
harness/sync-worlds.sh
```

Copies `server-a`'s world over `server-b`'s (keeping a `world.pre-sync-backup`) so both backends serve identical terrain. Run it whenever `server-a`'s world has changed and the slice is stopped — chunk continuity across the backend splice depends on the files matching.

## Prepare-abort script

```sh
harness/run-prepare-abort.sh
```

Runs the M2 placeholder prepare→abort round trip against the proxy control skeleton. This is in-process until the experimental proxy↔server transport exists.

## Files

- `run-slice.sh` — boots proxy + both servers, health-checks the ports
- `run-prepare-abort.sh` — runs the scripted M2 prepare→abort round trip
- `sync-worlds.sh` — copies the world from server-a to server-b
- `velocity.toml` — canonical proxy config (installed into the run dir on each boot)
- `forwarding.secret` — modern-forwarding secret (local dev only)
- `worldline.toml` — static partition map; installed for proxy and servers on each boot
