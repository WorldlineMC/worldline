# M5 Commit, Splice, and Activation Design

**Status:** Implementation design for the ADR 0005 vertical slice

## Goal

Complete roadmap milestone M5 so an on-foot player crossing the static west/east boundary changes authoritative servers at one fenced commit point, resumes on the destination from the exact staged M4 snapshot, and has buffered movement released to the destination in order without a client-visible server transition.

## Starting Point

The root repository currently pins the M2 submodule commits. The `proxy` and `server` branch tips contain the completed M3 boundary-preparation and M4 freeze/snapshot/staging work. M5 will first advance the root submodule pointers to those M4 tips, then add M5 commits in each submodule.

The M1 splice proves that a destination Paper connection can be driven through login and configuration without forwarding its login/respawn sequence to the client. M5 must replace M1's global `worldline.splice-target` heuristic with transfer-scoped, epoch-fenced state-machine integration.

## Authority and Ordering

The proxy-owned live player-session record remains the commit authority. The successful path is:

1. M4 reaches `SNAPSHOT_STAGED`; the source remains frozen and authoritative at epoch `n`.
2. The proxy conditionally commits the live session from source/epoch `n` to destination/epoch `n + 1`.
3. Once that local commit succeeds, the proxy route generation advances and rejects all gameplay output from every backend until the destination route is explicitly installed.
4. The proxy sends `COMMIT_DESTINATION` and `COMMIT_SOURCE` using M5 control protocol version 4 and waits for a two-command barrier before opening the resume connection. The destination records a transfer-scoped committed preparation; the source records `FROZEN(n) -> COMMITTED_AWAY(n + 1)` without unfreezing or persisting stale state. Neither infers commit from a connection or timeout.
5. The proxy opens the destination backend resume connection carrying the transfer ID, player UUID, client connection ID, route generation, and committed player-session epoch in immutable internal connection context.
6. Paper validates that context against the committed staged preparation and attaches the network connection to the prepared player on the main thread. The player remains unregistered, unticked, untracked, unpersisted, event-suppressed, and gameplay-output-suppressed in `CONNECTION_ATTACHED`.
7. The proxy receives the withheld readiness login packet, installs the destination route binding without forwarding a JoinGame, Respawn, or configuration transition to the client, then sends `ACTIVATE_DESTINATION`.
8. Paper atomically installs the exact prepared player into the world on the main thread and acknowledges activation only after the player is active. The proxy records `ACTIVE_DESTINATION` and only then drains buffered replayable input in original order. The held boundary-crossing movement is first.
9. The proxy sends `CLEAN_SOURCE`. Paper performs `COMMITTED_AWAY(n + 1) -> CLEANED(n + 1)` without stale persistence or duplicate quit effects, retains an idempotency tombstone, and the proxy records `SOURCE_CLEANED` before closing the obsolete source connection.
10. The proxy retires the active transfer into an `ACTIVE_SOURCE`-shaped steady record for the destination at epoch `n + 1`, while retaining a bounded transfer tombstone separately for duplicate terminal acknowledgements.

There may be a short post-commit interval with no backend allowed to emit gameplay. There is never an interval where both backends may emit authoritative gameplay or simulate the player.

## Proxy Changes

### Transfer-scoped connection context

Introduce an immutable backend binding for every Worldline backend connection containing the client connection ID, backend server ID, player-session epoch, route generation, and optional transfer ID. The initial source connection receives a binding when its live session record is registered. The destination resume context extends that binding with source epoch, committed epoch, source server, and destination server. Pass it directly from the M5 coordinator into `VelocityServerConnection`; do not derive authority from a global system property or destination name.

The backend handshake marker is an internal transport detail, not an authority grant. It carries enough identity to locate the already-committed preparation, and Paper rejects missing, malformed, stale, or mismatched values.

M5 increments the experimental direct-control protocol from version 3 to version 4. Version 4 defines explicit results and state changes for `COMMIT_DESTINATION`, `COMMIT_SOURCE`, `ACTIVATE_DESTINATION`, and `CLEAN_SOURCE`. The proxy rejects a version-3 peer during preparation compatibility checks, before the live session can commit.

### Commit coordinator

Extend `ClientPlaySessionHandler` with one post-stage future representing the M5 operation. All callbacks return to the player's Netty event loop before mutating connection or buffer state.

The coordinator:

- calls the conditional live-session commit exactly once;
- rereads and accepts `ALREADY_APPLIED` for the same transfer after an ambiguous acknowledgement;
- advances the route generation and disables all gameplay output immediately after the local commit;
- completes a two-command commit-notification barrier before destination attachment;
- starts the destination connection only for the committed transfer;
- installs the destination route only for the matching client connection, transfer, epoch, and route generation;
- activates the destination before replay and starts an overall post-commit deadline independent of packet arrival;
- drains the movement buffer exactly once;
- performs source cleanup last;
- never calls the pre-commit abort path after commit.

If destination connection or activation fails after commit, the source epoch is not resurrected. The player is disconnected safely and the committed state remains authoritative for later recovery work in M7.

The two-command barrier handles partial success explicitly:

- both acknowledgements succeed: continue to destination connection;
- either acknowledgement is lost: reread the committed proxy record and retry that same command and transfer ID idempotently;
- destination applies while source is pending: keep all gameplay routes fenced and do not attach the destination until the source acknowledges `COMMITTED_AWAY`;
- source applies while destination is pending: keep the source frozen/committed-away and all gameplay routes fenced; retry destination commit;
- either server rejects after the local proxy commit: never abort or unfreeze; safely disconnect, retain the committed live record, and run bounded retry/retirement handling.

The post-commit deadline bounds this barrier. Expiry cannot roll authority back.

### Backend output fencing

`BackendPlaySessionHandler` must check its immutable binding and the proxy route state before forwarding authoritative gameplay. Output is accepted only when all of these are true:

- the binding's client connection ID matches the current player connection;
- its backend server and player-session epoch match the live session record;
- its route generation is the installed route generation;
- the installed handoff phase permits destination gameplay (`ACTIVE_DESTINATION` or the post-cleanup steady state).

The old source is rejected immediately after commit, even if the player later returns to the same physical server at a newer epoch. Destination gameplay is also rejected during `COMMITTED` and `CONNECTION_ATTACHED`.

Protocol-control traffic needed to finish or close a connection remains explicitly handled through transition handlers; the gameplay fence is not implemented as blind packet replay.

### Ordered movement replay

The existing bounded M4 movement buffer is generalized to an ordered replay buffer whose entries carry a monotonic sequence and the committed route generation. M5 supports decoded movement as replayable gameplay input; later replayable packet families require an explicit classification addition and test. Replay writes supported entries to the active destination connection on the player's event loop only after activation, preserving insertion order and binding them to epoch `n + 1` through the destination connection binding. The crossing packet remains first by construction.

### Packet classification

For the M5 vertical slice, packet handling is explicit:

| Direction and phase | Packet family | Action |
| --- | --- | --- |
| Serverbound, before source freeze | Movement within source | Forward to source |
| Serverbound, crossing/frozen/committed | Decoded movement | Withhold in bounded ordered buffer; replay after activation |
| Serverbound, any handoff phase | Source keepalive response | Route only to the connection that issued the keepalive |
| Serverbound, frozen through activation | Teleport confirmation | Route only when its connection-scoped teleport ID owner is known; otherwise fail safely |
| Serverbound, frozen through activation | Signed-chat/session update or chat acknowledgement | Slice runs unsigned as documented; never replay or transfer acknowledgement state |
| Serverbound, frozen through activation | Unknown or unsupported gameplay | Pre-commit abort; post-commit safe disconnect |
| Clientbound, before commit | Source gameplay | Forward |
| Clientbound, after commit | Source gameplay | Reject |
| Clientbound, before destination activation | Destination readiness/control | Consume in proxy transition handler |
| Clientbound, before destination activation | Destination gameplay | Reject |
| Clientbound, after destination activation | Destination gameplay | Forward only through installed binding |
| Either direction | Unexpected configuration/respawn transition | Fail safely; never forward a visible transition |

Keepalive and teleport ownership are connection-scoped, not inferred from the current server name. Tests cover both connections during the transition. Expanding support beyond movement is a packet-classification change, not generic buffering.

## Server Changes

### Committed preparation lifecycle

Extend `WorldlineControlServer` preparation state with an explicit committed epoch and lifecycle:

~~~text
PREPARED -> SNAPSHOT_STAGED -> COMMITTED -> CONNECTION_ATTACHED -> ACTIVE -> CLEANED
                               |                |             |
                               +----------------+-------------+-> RETIRED
~~~

`COMMIT_DESTINATION` conditionally changes a staged preparation to committed. Duplicate commands for the same transfer and epochs return the recorded result; mismatched transfers or epochs are rejected. The prepared M4 `ServerPlayer` is adopted by the resume connection rather than copied into an independently active player.

Attaching the connection does not call ordinary `placeNewPlayer` side-effect paths. The prepared player stays outside the player list and level entity tracker, cannot tick or receive damage, fires no join/plugin events, emits no gameplay, and cannot persist until `ACTIVATE_DESTINATION` runs on the main thread. That command atomically registers the exact prepared player and only then acknowledges. `ABORT` cannot discard a committed preparation.

`RETIRE_DESTINATION` is the idempotent post-commit cleanup command and is legal from `COMMITTED`, `CONNECTION_ATTACHED`, or `ACTIVE`. On the main thread it closes/detaches the resume connection, removes any active tracking/player-list registration without a second logical event, prevents stale persistence, releases the prepared player and chunk ticket, and records a bounded `RETIRED` tombstone containing the transfer and committed epoch. It does not move authority back to the source. A future M7 recovery may replace or recreate destination authority from the committed record; M5 failure handling may disconnect the client but never fabricate a new owner.

### Exact snapshot consumption

The Paper resume join path resolves its transfer-scoped context through `WorldlineControlServer`. It must:

- find the matching committed preparation;
- reject UUID, transfer, server, partition, state-version, or epoch mismatches;
- consume the staged snapshot once;
- retain the already-loaded persistent and transient state on the exact prepared `ServerPlayer` before that player can tick or cause authoritative side effects;
- preserve the M1 suppression of initial client-visible packets;
- expose activation readiness to the `ACTIVATE_DESTINATION` command.

The staged snapshot remains the source of player state. Paper must not silently fall back to ordinary disk player data on a Worldline resume failure.

### Source cleanup

`COMMIT_SOURCE` is the fenced proof that the proxy live record moved away. It conditionally changes `FROZEN(n)` to `COMMITTED_AWAY(n + 1)` and suppresses future player-data saves for epoch `n`. `CLEAN_SOURCE` accepts only that state and removes the frozen source player on the main thread without broadcasting a second logical quit, persisting stale player state, or unfreezing it. The control server owns logical cleanup; closing the source TCP connection afterward performs transport cleanup only. A bounded tombstone makes duplicate cleanup acknowledgements idempotent.

## Failure Handling

- **Commit rejected before the live-record transition:** use the existing pre-commit abort and safely resume the source.
- **Destination COMMIT acknowledgement lost:** resolve from the authoritative proxy live session and retry the same transfer ID; server handling is idempotent.
- **Destination connection or snapshot consumption fails after commit:** reject old-source output and disconnect safely; never roll back authority.
- **Activation rejected:** do not replay input; disconnect safely and send `RETIRE_DESTINATION`.
- **Replay write fails:** disconnect safely and leave the old source fenced.
- **Cleanup acknowledgement lost:** retrying the same cleanup is idempotent.
- **Stale source output:** drop and log with transfer and epoch context.
- **Malformed or oversized internal resume identity:** reject before lookup or allocation.
- **Client disconnect before commit:** abort, unfreeze the source, and discard the buffer.
- **Client disconnect after commit:** never send `ABORT`; discard replay once, send `RETIRE_DESTINATION` when destination resources exist, clean source resources, and retain the committed/tombstone records needed for safe retry.
- **Post-commit deadline:** if the commit-notification barrier, connection, attachment, activation, replay, or cleanup does not finish within the configured bound, safely disconnect and run phase-appropriate `RETIRE_DESTINATION`/source cleanup without source resurrection.

Every asynchronous completion is ignored unless client connection ID, transfer ID, epoch, and route generation still match.

## Security and Robustness Constraints

- Control and resume identities are fully fenced by UUID, client connection ID, transfer ID, route generation, server IDs, partition epochs, player-session epochs, and player-state version.
- No global destination-name property grants resume authority.
- Version-3 peers cannot acknowledge version-4 lifecycle commands.
- Payload bounds from M4 remain enforced.
- No blocking control socket operation runs on a Netty event loop or Paper main thread.
- Asynchronous completions verify that they still belong to the active transfer before mutating state.
- Buffers remain time- and count-bounded and are drained or discarded once.
- Logs identify transfers but do not include snapshot contents, forwarding secrets, or authentication material.

## Testing

Test-driven implementation will add focused tests for:

- conditional commit before destination connection and activation;
- old-source output rejection immediately after commit;
- destination output rejection until route installation and activation;
- stale same-server connections from an older epoch/route generation;
- same-transfer duplicate commit/activate/cleanup idempotency;
- both one-sided commit-command application and lost-acknowledgement outcomes;
- stale transfer and epoch rejection;
- committed snapshot consumption exactly once;
- no fallback to disk state when resume validation fails;
- connection attachment leaves the prepared player unticked, untracked, event-suppressed, output-suppressed, and byte-equivalent to the staged snapshot;
- activation atomically installs that exact player and acknowledges afterward;
- crossing movement replayed first, followed by later movement in order;
- no replay before activation;
- safe post-commit destination failure without source resurrection;
- source cleanup only after activation and replay;
- source cleanup never persists old-epoch state or duplicates logical quit effects;
- pre-commit versus post-commit disconnect and deadline behavior;
- destination retirement from committed, attached, and active phases, including duplicate/lost acknowledgements and resource release;
- keepalive, teleport-confirmation, chat-acknowledgement, unexpected configuration, and unknown-packet classification;
- protocol-version-3 rejection before commit;
- malformed resume context rejection.

Server-side acceptance instrumentation records transfer ID, epoch, route generation, source freeze/cleanup ticks, destination attachment/activation ticks, first processed movement sequence and position, and rejected stale output. A trace assertion proves no dual-authority tick, no source-side authoritative position past the boundary, crossing input first on destination, and no clientbound JoinGame/Respawn/configuration transition.

Verification includes focused proxy tests, focused Paper tests, the relevant Gradle checks after Paper patches are applied, the live harness prepare/freeze/stage flow, the trace assertion, and an M5 harness path where local run directories and a client-capable environment are available.

## Documentation

Update canonical harness flags/configuration and `harness/README.md` to use transfer-scoped M5 handoffs instead of the global M1 splice target. If the manual M1 command remains, give it an explicit separate opt-in mode.

After verification, update the vertical-slice roadmap to mark M5 complete only if its exit criteria are actually demonstrated. If automated checks pass but a vanilla-client acceptance run is unavailable, record implementation completion separately from the still-unverified manual acceptance criterion.
