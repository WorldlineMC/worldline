# Vertical-slice dev harness

Local two-node topology for the [vertical-slice roadmap](../docs/vertical-slice-roadmap.md) (M0): one Worldline Proxy on `25565`, `server-a` on `25566`, `server-b` on `25567`. M2 control endpoints listen on `25576` and `25577`. Both servers run identical world files; the static partition boundary in `worldline.toml` splits the world at chunk X = 0.

Everything here is slice-only development tooling under the ADR 0005 experimental exception. The `forwarding.secret` is a local-development secret shared with each server's `config/paper-global.yml`; it protects nothing outside this harness.

## One-command boot

```sh
harness/run-slice.sh
```

Requires built jars and initialized server run directories:

```sh
harness/build-jars.sh                                   # server + proxy jars
cd server && ./gradlew :paper-server:runServers         # first-time run-dir init (accept EULA, generate world)
```

The script installs `velocity.toml`, `forwarding.secret`, and `worldline.toml` into the gitignored `proxy/proxy/run`, copies `worldline.toml` into both server run dirs, starts all three processes, waits until each port accepts connections, and tears everything down on Ctrl-C. Process output is shown live and retained in `harness/logs/`.

Connect a vanilla client to `127.0.0.1:25565`; you land on `server-a`.

Normal startup enables the M5 boundary-driven handoff and resume on both backends, allowing a
west → east → west round trip. It does not arm the old global M1 target.
Walk from chunk X = -1 across X = 0 to trigger the full prepare/freeze/stage/commit/resume/
activate/replay/cleanup path. Afterward, validate the retained logs with:

```sh
harness/assert-m5-trace.sh harness/logs
```

For the deterministic M5 acceptance run, use a vanilla client in survival and prepare this state
while still west of the boundary:

1. Clear the inventory, then give at least three distinct item stacks (for example stone, bread,
   and an iron pickaxe); place one stack in hotbar slot 3 and select that slot.
2. Take non-lethal damage so health is partial, and sprint/jump until the hunger bar is partial.
3. Run `/experience add <player> 7 points` and
   `/effect give <player> minecraft:speed 120 1 true` from a permitted console/account.
4. Walk across X = 0 without opening a container, mounting, sleeping, or entering a portal.
5. Confirm in the same unmodified client that there was no disconnect, reconnect, loading screen,
   JoinGame/Respawn transition, inventory duplication, selected-slot change, or effect reset.
6. Run `harness/assert-m5-trace.sh harness/logs`. It requires matching SHA-256 snapshot hashes at
   source freeze and destination activation, contiguous ordered proxy replay beginning at sequence 0,
   matching transfer/player/route evidence, actual applied destination X/Y/Z, ordered authority
   phase timestamps, and no client-transition trace. It handles both crossing directions.
   Historical `processed first replay movement` receipt markers are insufficient and are rejected.

The visual vanilla-client observation is mandatory acceptance evidence; the log assertion does not
replace it.

For the legacy M1 splice spike only, start the harness with
`WORLDLINE_M1_MANUAL_SPLICE=1`, stand still, and run `/server server-b`. The proxy silently drives the
second backend connection and swaps packet routing without putting the client through configuration
or forwarding Paper's login packet. This manual path is deliberately limited to `server-a` to
`server-b`; restart the harness before repeating it.

The slice runs with `enforce-secure-profile=false` on both backends (`run-slice.sh` enforces this
at boot). The client's signed-chat session is established once per connection and is never re-sent
to a spliced-in backend, so the destination server has no profile public key for the player and
would reject chat under secure-profile enforcement. On splice the proxy also clears the client's
own remembered chat session (a player-info `INITIALIZE_CHAT` with no session), since the new
backend broadcasts the player's chat unsigned and the client would otherwise fail to validate its
own messages. The client only accepts unsigned chat when the login packet it saw advertised
`enforce-secure-profile=false`, so both halves of this workaround depend on that setting. Relaxed
chat-signing is the residual constraint anticipated by risk 1 in the
[vertical-slice roadmap](../docs/vertical-slice-roadmap.md); carrying signed-chat sessions across
a handoff needs its own design work later.

## Separate terminals

To run each process in its own terminal instead of the single-terminal boot:

```sh
harness/run-one.sh server-a   # terminal 1
harness/run-one.sh server-b   # terminal 2
harness/run-one.sh proxy      # terminal 3
```

Each invocation installs the same canonical config as `run-slice.sh`, then runs the component in
the foreground with identical flags, so logs and the server console stay in that terminal.
Start order doesn't strictly matter (the proxy retries backend connections), but starting the
servers first avoids join failures while they boot.

## World sync

```sh
harness/sync-worlds.sh
```

Copies `server-a`'s world over `server-b`'s (keeping a `world.pre-sync-backup`) so both backends serve identical terrain. Run it whenever `server-a`'s world has changed and the slice is stopped — chunk continuity across the backend splice depends on the files matching.

## Prepare-abort script

```sh
harness/run-prepare-abort.sh
```

With the slice topology running, sends the M2 placeholder prepare→abort round trip from the proxy
control plane to the real Paper control endpoint on `server-b`. The command validates the full
identity envelope and partition epoch at both ends.

The M2 transport opens one framed TCP connection per request and performs no hidden reconnect or
retry. A caller resolves ambiguous commit delivery from the proxy session record, then explicitly
retries the same `transfer_id` only when that authoritative state permits it.

Inject a transition failure with `-Dworldline.failure.<phase>=drop|delay:<ms>|duplicate|crash` on
the proxy; phase names are lowercase values such as `preparing_destination` and `committed`.

## Files

- `build-jars.sh` — builds the server bundler jar and the proxy shadow jar
- `run-slice.sh` — boots proxy + both servers, health-checks the ports
- `run-one.sh` — boots a single component in the foreground (for separate terminals)
- `run-prepare-abort.sh` — runs the scripted M2 prepare→abort round trip
- `assert-m5-trace.sh` — validates M5 authority ordering and replay/state trace invariants
- `sync-worlds.sh` — copies the world from server-a to server-b
- `velocity.toml` — canonical proxy config (installed into the run dir on each boot)
- `forwarding.secret` — modern-forwarding secret (local dev only)
- `worldline.toml` — static partition map; installed for proxy and servers on each boot

## Tonight's client check

See [the reproducible test checklist](tonight-test.md). The trace checker requires Python 3
(standard library only). Run its positive and negative fixtures without starting Minecraft:

```sh
harness/assert-m5-trace.sh --self-test
python3 -B harness/test_harness_launch.py
```

The checker validates logged proxy replay ordering and the first movement's applied position.
It cannot establish that every replayed packet was applied exactly once, observe every simulation
tick, or replace the unmodified-client observation. All three logs must come from the same run on
the same host; authority timestamp comparisons assume a common clock.
