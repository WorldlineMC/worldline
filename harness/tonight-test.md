# M5 disposable local test checklist

Use the parent integration revision approved for tonight, including its pinned server and proxy
commits. This checklist is a test procedure, not a claim that live acceptance has passed.

## Prepare the checkout and artifacts

Use a separate disposable checkout, not an existing world or a live server. Install JDK 25 (server
build/runtime), JDK 21 (proxy build toolchain), Python 3, Git, and Bash. The pinned server targets
**Minecraft Java Edition 26.2**; use an unmodified client of that exact version.

From the approved parent checkout:

```sh
git status --short                 # stop if this checkout contains work you need to preserve
git submodule update --init --recursive
git rev-parse HEAD
git submodule status
export GRADLE_USER_HOME="$PWD/.gradle-tonight"
export GRADLE_OPTS="-Dorg.gradle.workers.max=2 -Dorg.gradle.parallel=false"
java -version                     # the java on PATH must be JDK 25 for run-slice/run-one
harness/assert-m5-trace.sh --self-test
python3 -B harness/test_harness_launch.py
harness/build-jars.sh
cat harness/.built-revisions
```

Builds run sequentially. `build-jars.sh` records the submodule revisions only after both jar builds
succeed; the launch scripts refuse mismatched revisions. Preserve the printed parent revision and
`.built-revisions` with the test evidence. CI packaging success does not put jars into this checkout.

For an already initialized disposable fixture, reuse its agreed local forwarding configuration.
For a fresh fixture, initialize the run directories:

```sh
(cd server && ./gradlew --max-workers=2 :paper-server:runServers)
```

Read and accept the Minecraft EULA yourself in each generated `server/run/server-{a,b}/eula.txt`
if you agree, then rerun initialization until both worlds are generated. Stop initialization before
continuing. This task does not accept the EULA for you. The fixture must already have the matching
local Velocity forwarding configuration described in `README.md`; a fresh Paper default configuration
is not ready for proxy login. Do not apply these fixture settings to any real host.

With both servers stopped, synchronize the disposable world files and launch:

```sh
harness/sync-worlds.sh
harness/run-slice.sh
```

Default memory is 2 GiB per server plus 512 MiB for the proxy. The script refuses occupied ports.
It enables resume on **both** servers and prints readiness for all five ports:

| Component | Client/game port | Control port |
| --- | --- | --- |
| Proxy | 25565 | — |
| server-a, west (`x < 0`) | 25566 | 25576 |
| server-b, east (`x >= 0`) | 25567 | 25577 |

Connect the vanilla 26.2 client to **127.0.0.1:25565**. Do not join a backend directly. Leave
`WORLDLINE_M1_MANUAL_SPLICE` unset. The initial join routes to server-a.

## Observe a round trip

Use a permitted test operator account/console to arrange a safe walking surface around X=0,
with the same Y/Z and identical terrain on both worlds. Begin west of the boundary in survival.
Do not use teleportation to cross. Avoid mounts, containers, sleep, and portals during the transfer.

1. Record inventory (three different stacks), selected hotbar slot, partial health, partial hunger,
   XP, and a timed effect. For example, use `/experience add <player> 7 points` and
   `/effect give <player> minecraft:speed 120 1 true` before crossing.
2. Walk east across X=0, stop, then walk west across X=0. Repeat once. Keep a recording showing
   coordinates and the state before/after each crossing.
3. Check for uninterrupted control and movement, no loading/reconnect screen, no duplicated/lost
   inventory, and preserved selected slot, health, food, XP, and effect duration (allow normal elapsed
   ticks). Test ordinary chat after the crossing as a separate observation.
4. Stop with Ctrl-C before archiving logs; the next `run-slice.sh` launch overwrites them.

```sh
harness/assert-m5-trace.sh harness/logs
stamp=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "harness/evidence-$stamp"
cp harness/logs/*.log harness/.built-revisions "harness/evidence-$stamp/"
git rev-parse HEAD > "harness/evidence-$stamp/parent-revision.txt"
```

For each completed transfer UUID, expect correlated proxy `COMMITTED`, `ACTIVE_DESTINATION`,
ordered `Worldline replay ... sequence=0` onward, `SOURCE_CLEANED`, then
`Worldline M5 completed transfer ... client_transition_packets=0`. Source logs must contain
freeze → committed-away → cleaned; destination logs must contain inert attachment → activation →
`Worldline applied first replay movement`. The latter must report actual post-application X/Y/Z,
not merely the packet's requested position. Snapshot hashes and player UUIDs must match.

A receipt-only `processed first replay movement` marker is deliberately insufficient. If the checker
fails, retain all three logs, the transfer UUID, revisions, direction, client recording, and exact
failure. If a crossing never completes, absence of a completed transfer is failure to establish
acceptance, even if a previous transfer in the same logs passed. Confirm the expected four completed
transfers for the two round trips; a checker pass for fewer transfers does not finish this procedure.

The log checker supports the observation; it does not prove every packet was applied exactly once or
that no simultaneous simulation tick occurred. Passing CI plus this script is not live acceptance
until the visual and state checks above have been completed.
