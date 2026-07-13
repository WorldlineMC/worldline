# Vertical-slice roadmap: player handoff state machine

**Status:** Informative — this is an execution plan for the vertical slice authorized by [ADR 0005](decisions/0005-player-handoff-state-machine.md). It is not a decision record. Where this plan and an accepted ADR disagree, the ADR wins.

## Objective

Prove Worldline's highest-risk product claim end to end: a player walks across a manually configured partition boundary between two Worldline Server processes, through one Worldline Proxy, with an unmodified Minecraft client — no disconnect, no loading screen, no lost or duplicated state, no tick of dual authority, and no visible flicker for a second player observing from the source server.

The slice deliberately substitutes simple infrastructure (in-memory ownership map, in-memory live player-session record, direct experimental transport) under the explicit exception in ADR 0005. Its output is a working demonstration plus the measured findings that inform the later wire-protocol ADR.

## Starting point (2026-07-12)

- `proxy/` is an unmodified Velocity fork (`3.6.0-SNAPSHOT`); `server/` is an unmodified Paper fork (MC 26.2). Neither contains any Worldline code yet.
- The server fork has a `runServers` Gradle task in progress that boots a fixed two-node topology (`server-a` on 25566, `server-b` on 25567).
- ADRs 0001–0006 and the architecture overview are accepted and define the constraints this plan must satisfy.

## Out of scope

Redis, SQL, automatic partition allocation, durability replication, the production wire protocol, partition migration, proxy high availability, plugin compatibility (ADR 0006), and handoffs involving vehicles, open containers, sleeping, or portals. An unsupported player state aborts or delays the handoff; it is never silently dropped.

## Sequencing rationale

The single question that can kill the project is whether an unmodified client can be spliced from one backend to another mid-play without a loading screen. Everything else in ADR 0005 — the state machine, buffering, epochs, failure handling — is demanding but conventional distributed-systems work. So the plan buys down the protocol risk first with a throwaway spike (M1) before investing in the full state machine, and builds failure-injection hooks into the state machine from day one (M2) rather than bolting them on at the end.

## Milestones

### M0 — Two-node development harness

Everything later needs a repeatable local topology.

- Finish the `runServers` task; add a matching proxy run task and a one-command boot for proxy + both servers.
- Both servers run the same world and dimension from identical world files (copied, not shared — ADR 0004 forbids two writers on one file; identical terrain is what lets the client's already-loaded chunks stay valid across the splice).
- Static partition boundary and ownership config (e.g. chunk X < 0 owned by `server-a`, X ≥ 0 by `server-b`) read by proxy and servers.
- Velocity config registering both backends; consistent forwarding/auth settings.
- Structured logging with a per-transfer correlation ID, ready for phase timings.

**Exit:** one command boots the topology; a vanilla client connects through the proxy and plays normally on `server-a`.

### M1 — Connection-splice spike (throwaway code)

Prove the transparent backend switch in isolation, with a standing-still player and no state machine, before designing around it.

- Proxy side: bypass Velocity's normal server switch (`TransitionSessionHandler`, which drives the JoinGame/Respawn sequence the client renders as a loading screen). Open a second backend connection, drive its handshake/login/config phases silently, suppress its clientbound output, then swap which `VelocityServerConnection` backs the client's `ClientPlaySessionHandler` at play state.
- Server side: add a "resume" join path to the Paper fork — inject the `ServerPlayer` (via a modified `PlayerList` placement path and `CommonListenerCookie`) at a given position without emitting the initial JoinGame/Respawn/spawn sequence, on the assumption the client is already synchronized.
- Work through the known protocol landmines: player entity ID parity or remapping, registry and dimension parity, keepalive and teleport-confirmation ownership across the swap, signed-chat session state, chunk view continuity (identical world files + matched view distance), tick-synchronization packets.
- Deliverable: a demo (recorded) plus **packet-classification notes v0** — the per-packet table of forward / withhold / translate / proxy-owned that ADR 0005 requires the slice to determine. The spike code itself is disposable; the notes are the product.

**Exit:** a stationary player is switched `server-a` → `server-b` with no loading screen or disconnect, and can move, chat, and take damage normally afterward. If this proves impossible without client modification, stop and write the findings into a superseding ADR — nothing after this milestone is worth building first.

### M2 — Handoff control plane and state machine skeleton

- Direct experimental proxy↔server control transport (simplest thing that works — a dedicated TCP connection or a channel on the existing backend connection). Every message carries the ADR 0005 identity envelope: `protocol_version`, `transfer_id`, `player_uuid`, server IDs, partition IDs and epochs, `player_session_epoch`, `player_state_version`.
- In-memory ownership map in the proxy; servers are told which partition they own at boot.
- The authoritative live player-session record in the proxy (`player_uuid`, `client_connection_id`, `authoritative_server_id`, `player_session_epoch`, `active_transfer_id`, `handoff_phase`) with an atomic conditional-transition primitive — this is the commit operation, implemented and tested before anything depends on it.
- The full eight-state machine (`ACTIVE_SOURCE` … `SOURCE_CLEANED`) with logged, timed phase transitions; one active transfer per player; duplicate commands idempotent; stale-epoch messages rejected.
- Failure-injection hooks (drop, delay, duplicate, crash) at every state transition, built in now so M7 is a test-writing exercise rather than a refactor.

**Exit:** a scripted prepare→abort round trip with placeholder payloads passes; unit tests demonstrate idempotent duplicates, stale-epoch rejection, and conditional commit semantics including the lost-acknowledgement reread path.

### M3 — Boundary detection and destination preparation

- Proxy inspects replayable serverbound movement against the boundary config: begin preparation on approach; on an input that would cross into remote-owned space, do **not** forward it to the source — it becomes the first entry in the handoff buffer.
- `PREPARING_DESTINATION`: proxy verifies ADR 0005 preconditions (ownership at expected epoch, health, no draining, protocol and registry compatibility, no other active transfer), then the destination loads the target chunk and visibility halo and constructs a non-authoritative prepared player, answering `DESTINATION_READY`.
- Slow-preparation behavior: briefly hold or constrain the crossing per the ADR; never fake remote-side movement, never buffer unbounded.

**Exit:** walking toward the boundary reliably triggers preparation ahead of arrival; the crossing input is verifiably withheld from the source; preparation timeout or rejection discards destination state and the player continues on the source unaffected.

### M4 — Freeze, snapshot, and staging

- Source freezes the player at a tick boundary (`SOURCE_FROZEN`): no further authoritative simulation, while keepalive and other session-critical protocol traffic continues.
- Versioned final snapshot covering the slice's required state: position/rotation/velocity and movement state, inventory and selected slot, health and food state, experience, game mode and abilities, active effects — plus source tick, `player_state_version`, `transfer_id`, and all epochs.
- Proxy holds the bounded, ordered buffer of replayable input (crossing input first) with explicit size and time limits; overflow or timeout aborts and safely resumes the source.
- Destination validates and stages the exact snapshot without ticking (`SNAPSHOT_STAGED`); any state it cannot activate exactly fails staging and aborts the transfer. Detection of out-of-scope states (vehicle, open container, sleeping, portal) aborts before freeze.

**Exit:** snapshot round-trips losslessly (byte-exact re-serialization test); pre-commit abort unfreezes the source and replays only source-safe input, never the crossing movement; buffer limits demonstrably abort rather than grow.

### M5 — Commit, splice, and activation

The M1 spike findings become real code, driven by the state machine.

- Atomic conditional commit of the live session record; `player_session_epoch` increments; `COMMITTED`.
- Packet routing flips exactly at commit: clientbound gameplay from the old source is rejected; the destination becomes the sole emitter of authoritative gameplay output.
- Destination activates the staged snapshot, then processes the held crossing input first — performing the first authoritative collision and physics inside its partition — then the remaining buffered input in order, tagged with the new epoch.
- Source enters cleanup (`SOURCE_CLEANED`) without disturbing the client.

**Exit:** a player walks across the boundary in survival, on foot, with a mixed inventory, partial health/hunger, experience, and an active potion effect — no loading screen, no state loss or duplication, logs prove no tick of dual authority and no source-side authoritative position past the boundary.

### M6 — Observer continuity

- At commit, the source converts its locally tracked player into the ADR 0004-style remote projection — same viewer-facing entity identity, no despawn/respawn.
- The destination streams the transferred player's projected state to the source over the control transport, fenced by the committed `player_session_epoch`; the source relays it to observers in tracking range.
- Viewer-side epoch fencing rejects projection updates carrying the previous session epoch.

**Exit:** a second player watching from the source sees the transferred player walk across the boundary continuously — no disappearance, teleport-snap, or duplicate; an injected stale-epoch projection update is rejected and logged.

### M7 — Failure matrix

Implement and verify every row of the ADR 0005 failure table using the M2 injection hooks:

- Destination rejection/timeout during preparation → source unaffected.
- Abort while frozen, pre-commit → unfreeze; replay only source-safe input.
- Source failure before commit → proxy commits only if the snapshot is staged and all fencing preconditions hold; otherwise safe recovery or disconnect.
- Lost commit acknowledgement → resolved by rereading the proxy session record, idempotently, never by inference from timeout.
- Destination failure after commit → the source's old epoch is never reactivated; hold, recover, or disconnect safely.
- Client disconnect before and after commit → correct cleanup on both sides.
- Duplicate and stale messages at every phase → idempotent result or rejection.

**Exit:** an automated failure-injection suite exercises every state transition and passes; no scenario ever yields two authoritative simulators or a resurrected stale epoch.

### M8 — Instrumentation, acceptance run, and findings

- Record per-transfer metrics: end-to-end handoff latency, source-freeze duration, buffered-packet count, and per-phase timings.
- Execute the full ADR 0005 acceptance checklist (traceability below) and record the results.
- Write the findings document: measured numbers, the final packet-classification and translation table, protocol pain points, and what the slice implies for the production wire-protocol ADR and for buffer/timeout budgets. This document is the input to the next ADR, per the ADR 0005 rule that the slice informs rather than fixes the wire protocol.

**Exit:** every acceptance criterion demonstrated and recorded; findings document reviewed and merged.

## Traceability to ADR 0005 acceptance criteria

| ADR acceptance criterion | Proven by |
| --- | --- |
| No disconnect, reconnect, loading screen, or respawn transition | M1 (feasibility), M5 (in-system) |
| No lost or duplicated tested player state | M4, M5 |
| No tick of dual authority | M2 (commit semantics), M5, M7 |
| No source-side authoritative position inside destination partition before commit | M3, M5 |
| Crossing input processed first by the destination after commit | M5 |
| No unnecessary disappearance/respawn for the observer | M6 |
| Stale player-session-epoch projection updates rejected | M6 |
| Safe duplicates, destination timeout, pre-commit abort, lost commit ack | M2, M7 |
| Recorded latency, freeze duration, buffer counts, phase timings | M8 |
| Failure injection at every state transition | M2 (hooks), M7 (suite) |

## Dependencies

M0 → M1 → M2 → M3 → M4 → M5 → M6 → M7 → M8, with two useful overlaps: M2 (control plane) can start while M1 runs, since only M5 consumes the spike's findings; and M6 depends only on M5 plus a projection channel, so it can proceed in parallel with M7.

## Top risks

1. **The splice is impossible or version-fragile.** Some client state (chunk cache, lighting, signed-chat session, tick sync) may not survive a backend swap without a visible transition. Mitigated by doing M1 first with an explicit stop rule; fallbacks include constraining the slice (identical view distance, relaxed chat-signing config) and documenting the residual constraint for the wire-protocol ADR.
2. **Freeze-but-alive is awkward in Paper.** Halting authoritative simulation at a tick boundary while keeping the protocol session valid touches the tick loop. Mitigate by scoping freeze to the single `ServerPlayer` (skip its tick, keep `ServerGamePacketListenerImpl` connection handling running), not the server tick.
3. **Boundary detection from the proxy is protocol-deep.** The proxy must parse movement packets and share exact boundary math with the servers. Mitigate with one shared boundary/config definition and property tests on crossing detection.
4. **Fork drift.** Both forks track fast-moving upstreams; the splice work touches upstream-hot files. Mitigate by isolating Worldline code behind small patch surfaces and pinning upstream versions for the duration of the slice.
5. **Scope creep toward production.** Redis/SQL/wire-protocol work is explicitly deferred; anything the slice reveals about them goes into the M8 findings and subsequent ADRs, not into slice code.
