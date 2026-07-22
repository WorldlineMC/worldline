# M5 Handoff Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Correct the audited M5 packet/replay and control-plane failure modes without changing the accepted authority model.

**Architecture:** Preserve the proxy live-session record as the commit authority and Paper's prepared-player lifecycle. Close races at the existing event-loop and control-command boundaries, make all affected work transfer-fenced and retryable, and keep every buffer and retry bounded.

**Tech Stack:** Java 25, Velocity 3.6 fork, Paper 26.2 fork, Netty, JUnit 5, Gradle.

**Normative references:** `docs/decisions/0005-player-handoff-state-machine.md`, `docs/superpowers/specs/2026-07-18-m5-commit-splice-activation-design.md`, and `docs/superpowers/plans/2026-07-18-m5-commit-splice-activation.md`.

---

### Task 0: Record the reviewed hardening plan

**Files:**
- Create: `docs/superpowers/plans/2026-07-22-m5-handoff-hardening.md`

- [x] Review this plan against the accepted M5 design and ADR 0005.
- [x] Commit in the root repository: `docs: plan M5 handoff hardening`.

### Task 1: Close the replay handoff race and align its deadline

**Files:**
- Modify: `proxy/proxy/src/main/java/com/velocitypowered/proxy/worldline/HandoffReplayGate.java`
- Modify: `proxy/proxy/src/main/java/com/velocitypowered/proxy/worldline/HandoffReplayBuffer.java`
- Modify: `proxy/proxy/src/main/java/com/velocitypowered/proxy/connection/client/ClientPlaySessionHandler.java`
- Test: `proxy/proxy/src/test/java/com/velocitypowered/proxy/worldline/HandoffReplayBufferTest.java`

- [ ] Add failing tests proving a pending replay buffer captures movement during `SNAPSHOT_STAGED`, does not age out before local commit, and uses the same absolute deadline as the post-commit coordinator after local commit.
- [ ] Run the focused replay tests and confirm the new assertions fail for the current five-second/phase-limited behavior.
- [ ] Gate movement whenever a replay buffer exists, including the event-loop window before local commit becomes visible.
- [ ] Keep the replay count-bounded but unarmed before local commit; after local commit, atomically arm it with the coordinator's exact absolute deadline and schedule the terminal timeout from that same value.
- [ ] Run the complete proxy Worldline suite and `git diff --check`.
- [ ] Commit in `proxy`: `fix: close M5 replay transition race`.

### Task 2: Fence connection-sensitive callbacks and keep M5 chat unsigned

**Files:**
- Create: `proxy/proxy/src/main/java/com/velocitypowered/proxy/worldline/AsyncHandoffFence.java`
- Modify: `proxy/proxy/src/main/java/com/velocitypowered/proxy/connection/client/ClientPlaySessionHandler.java`
- Test: `proxy/proxy/src/test/java/com/velocitypowered/proxy/worldline/AsyncHandoffFenceTest.java`
- Test: `proxy/proxy/src/test/java/com/velocitypowered/proxy/worldline/ServerboundHandoffTrafficTest.java`
- Test: add handler-level coverage under `proxy/proxy/src/test/java/com/velocitypowered/proxy/connection/client/`

- [ ] Add failing tests for callback fences across client-connection, transfer, epoch, route-generation, phase, and backend changes.
- [ ] Add handler-level failing tests proving delayed plugin-message and cookie callbacks cannot write or enqueue after any fence field or backend changes.
- [ ] Add failing packet-policy tests proving resource-pack responses are rejected before their handler can target an in-flight destination and M5 sessions drop both chat-session updates and chat acknowledgements.
- [ ] Capture an immutable fence before firing plugin/cookie events and ignore callbacks unless all identity and backend fields still match.
- [ ] Apply the handoff gameplay gate before resource-pack processing.
- [ ] Drop chat-session updates and isolate acknowledgement state whenever the M5 boundary router is enabled, retaining the explicit M1 compatibility mode.
- [ ] Run the complete proxy Worldline suite and `git diff --check`.
- [ ] Commit in `proxy`: `fix: fence M5 connection-sensitive packets`.

### Task 3: Make an unknown movement origin fail safe

**Files:**
- Modify: `proxy/proxy/src/main/java/com/velocitypowered/proxy/worldline/BoundaryCrossingDetector.java`
- Modify: `proxy/proxy/src/main/java/com/velocitypowered/proxy/worldline/ServerboundMovementRouter.java`
- Test: `proxy/proxy/src/test/java/com/velocitypowered/proxy/worldline/BoundaryCrossingDetectorTest.java`
- Test: `proxy/proxy/src/test/java/com/velocitypowered/proxy/worldline/ServerboundMovementRouterTest.java`

- [ ] Add a failing test where the first positional packet is already in a remote-owned partition.
- [ ] Confirm it currently returns `FORWARD`.
- [ ] Classify an unknown origin from current backend authority and withhold remote-owned first movement instead of forwarding it.
- [ ] Preserve source/destination partition identity in the resulting decision and keep ordinary first movement inside the source unchanged.
- [ ] Run the focused router tests, complete proxy Worldline suite, and `git diff --check`.
- [ ] Commit in `proxy`: `fix: fence initial boundary movement`.

### Task 4: Reconcile ambiguous precommit aborts

**Files:**
- Modify: `proxy/proxy/src/main/java/com/velocitypowered/proxy/worldline/HandoffControlPlane.java`
- Modify: `proxy/proxy/src/main/java/com/velocitypowered/proxy/connection/client/ClientPlaySessionHandler.java`
- Test: `proxy/proxy/src/test/java/com/velocitypowered/proxy/worldline/HandoffControlPlaneTest.java`
- Test: add handler-level abort-state coverage under `proxy/proxy/src/test/java/com/velocitypowered/proxy/connection/client/`

- [ ] Add failing tests where the first `ABORT_SOURCE` acknowledgement is lost and the identical retry converges, and where bounded exhaustion leaves an explicit unavailable result.
- [ ] Add a handler-level failing test proving local transfer state remains ordered behind the pending abort and permanent exhaustion remains explicitly pending/unavailable rather than silently starting a new transfer.
- [ ] Retry the same fenced abort command with a bounded attempt count.
- [ ] Retire local handler state only after the ordered abort converges; retain a pending abort fence and keep failure visible when all attempts fail.
- [ ] Send destination abort after source/local convergence and keep it idempotent.
- [ ] Run focused control tests, the complete proxy Worldline suite, and `git diff --check`.
- [ ] Commit in `proxy`: `fix: retry ambiguous M5 aborts`.

### Task 5: Remove Paper control head-of-line blocking and late timed-out mutations

**Files:**
- Create: `server/paper-server/src/main/java/io/papermc/paper/worldline/WorldlineMainThreadOperation.java`
- Create: `server/paper-server/src/main/java/io/papermc/paper/worldline/WorldlineControlRequestExecutor.java`
- Modify: `server/paper-server/src/main/java/io/papermc/paper/worldline/WorldlineControlServer.java`
- Create: `server/paper-server/src/test/java/io/papermc/paper/worldline/WorldlineMainThreadOperationTest.java`
- Create: `server/paper-server/src/test/java/io/papermc/paper/worldline/WorldlineControlRequestExecutorTest.java`
- Modify: `server/paper-server/src/test/java/org/bukkit/support/suite/WorldlineTestSuite.java`

- [ ] Add failing tests proving a queued operation that times out never runs later, while an operation that has already started completes with its real result rather than a false rejection.
- [ ] Add executor tests proving a blocked request does not prevent another accepted request from running and that bounded saturation rejects excess work without leaking permits or sockets.
- [ ] Introduce a small queued/running/timed-out state machine used by `onServerThread`.
- [ ] Dispatch accepted sockets independently through a bounded virtual-thread executor; retain socket and payload limits.
- [ ] Run the Paper Worldline suite, compile task, and `git diff --check`.
- [ ] Commit in `server`: `fix: harden M5 control scheduling`.

### Task 6: Give preparation an explicit timeout margin

**Files:**
- Modify: `proxy/proxy/src/main/java/com/velocitypowered/proxy/worldline/WorldlineControlTransport.java`
- Modify: `proxy/proxy/src/main/java/com/velocitypowered/proxy/worldline/ServerboundMovementRouter.java`
- Test: `proxy/proxy/src/test/java/com/velocitypowered/proxy/worldline/WorldlineControlTransportTest.java`
- Test: `proxy/proxy/src/test/java/com/velocitypowered/proxy/worldline/ServerboundMovementRouterTest.java`

- [ ] Add failing tests that expose separate bounded connect/read and movement-preparation deadlines with deliberate margin above Paper's 1.5-second preparation wait.
- [ ] Make timeout values explicit and testable; preserve a finite control timeout and a longer finite movement-preparation timeout.
- [ ] Run focused transport/router tests, the complete proxy Worldline suite, and `git diff --check`.
- [ ] Commit in `proxy`: `fix: widen M5 preparation timeout margin`.

### Task 7: Retry and verify terminal retirement and cleanup

**Files:**
- Modify: `proxy/proxy/src/main/java/com/velocitypowered/proxy/connection/client/ClientPlaySessionHandler.java`
- Modify: `proxy/proxy/src/main/java/com/velocitypowered/proxy/worldline/HandoffControlPlane.java`
- Test: `proxy/proxy/src/test/java/com/velocitypowered/proxy/worldline/HandoffControlPlaneTest.java`
- Test: add a focused retry-policy test under `proxy/proxy/src/test/java/com/velocitypowered/proxy/worldline/`

- [ ] Add failing tests for unavailable-then-success retirement and cleanup, bounded permanent failure, and status inspection rather than exception-only handling.
- [ ] Centralize bounded terminal-command retries with a small backoff and explicit success predicate.
- [ ] Require destination retirement success before claiming it completed; retain and log pending cleanup when exhaustion occurs.
- [ ] Preserve the no-resurrection rule and keep all retry work off the Netty event loop.
- [ ] Run the complete proxy Worldline suite and `git diff --check`.
- [ ] Commit in `proxy`: `fix: retry M5 terminal cleanup`.

### Task 8: Advance gitlinks, verify, and publish

**Files:**
- Modify: root `proxy` gitlink
- Modify: root `server` gitlink
- Modify: this plan's checkboxes as tasks are completed

- [ ] Run fresh proxy Worldline tests with `--rerun-tasks`.
- [ ] Run fresh Paper `WorldlineTestSuite` with `--rerun-tasks` and `:paper-server:compileJava`.
- [ ] Run `git diff --check` and inspect status/diffs in root and both submodules.
- [ ] Commit root completed checklist and advanced gitlinks: `fix: harden M5 handoff failure paths`.
- [ ] Push proxy, server, and root `codex/m5-commit-splice` branches.
