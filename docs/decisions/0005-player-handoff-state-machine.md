# ADR 0005: Player handoff state machine and packet continuity

- **Status:** Accepted
- **Date:** 2026-07-11
- **Extends:** ADR 0001, ADR 0002, ADR 0003, and ADR 0004

## Context

Continuity's defining behavior is moving a player between authoritative backend servers without disconnecting the client, displaying a loading screen, losing player state, or revealing the backend transition to nearby players.

A player handoff is not a partition migration. During a player handoff, the source and destination partitions retain their existing owners. Only the player's live simulation authority and backend packet route change.

The handoff begins when a player approaches or attempts to cross into a partition owned by another Continuity Server. The source must not authoritatively apply a position inside the remote-owned partition before destination authority commits, because the source does not own that world state and boundary projections do not run authoritative physics or collision.

The protocol must define one commit point, prevent dual authority, preserve packet ordering, fence stale messages, recover safely from failures in every phase, and maintain remote projections for observers.

## Decision

### Identities and epochs

Every handoff has a globally unique transfer identifier. Every connected player session has a monotonically increasing player-session epoch that is independent from partition ownership epochs.

All handoff commands and snapshots identify at least:

~~~text
protocol_version
transfer_id
player_uuid
source_server_id
destination_server_id
source_partition_id
source_partition_epoch
destination_partition_id
destination_partition_epoch
player_session_epoch
player_state_version
~~~

Only one transfer may be active for a player. Duplicate commands for the same transfer are idempotent. Messages for an older player-session or partition epoch are rejected.

### Coordinator and preconditions

The Continuity Proxy retains the client-facing connection and coordinates the handoff.

Before preparing a destination, the proxy verifies that:

- The destination server still owns the destination partition at the expected epoch.
- The destination server is healthy, active, and not draining.
- The destination can load the target chunk and surrounding visibility data.
- The source and destination support compatible Continuity protocols.
- Registry, dimension, and client-facing configuration are compatible with a same-world transparent transfer.
- No other transfer is active for the player.

A partition migration involving the source or destination must either wait for the player transfer or cause the transfer to abort and resolve ownership again.

### Live player-session record and commit authority

In the initial single-proxy topology, the Continuity Proxy owns the authoritative live player-session record for every connected client. That record contains at least:

~~~text
player_uuid
client_connection_id
authoritative_server_id
player_session_epoch
active_transfer_id
handoff_phase
~~~

The player-session record is live control-plane state tied to the proxy-owned client connection. It is not the same record as partition ownership in SQL and is not reconstructed by guessing from backend state.

The handoff commit is an atomic conditional transition of this authoritative live session record from the source server and current player-session epoch to the destination server and next epoch. It succeeds only if the expected source, current session epoch, transfer identifier, destination partition owner, and destination partition epoch still match.

A lost commit acknowledgement is resolved by rereading this authoritative proxy session record and returning the already-recorded result idempotently. The source and destination must never infer commit success solely from timeout or connection loss.

Because a proxy process failure currently terminates its client connections, the initial design does not require durable live-session takeover by another proxy. Any future proxy high-availability design that preserves client sessions across proxy failure must define replication, consensus, and takeover semantics for the live player-session record in a separate accepted ADR.

### Boundary approach and crossing semantics

Destination preparation may begin before the player reaches the partition boundary so chunk loading and protocol setup can be hidden from the client.

When a replayable movement input would place the player inside a partition owned by another server:

1. The source does not authoritatively apply the remote-side position.
2. The proxy begins or completes destination preparation.
3. The source freezes the player at the last authoritative source-side state at a tick boundary.
4. The crossing input and subsequent replayable gameplay input are held in a bounded ordered buffer.
5. The source produces the final player-state snapshot.
6. The destination stages that exact snapshot while remaining non-authoritative.
7. The proxy commits player-session authority to the destination and increments the player-session epoch.
8. The destination activates the staged snapshot.
9. The buffered crossing input is released first, followed by later replayable input in order.

The destination therefore performs authoritative collision, physics, and world interaction for the first position inside its partition. The source never simulates the player authoritatively against remote-owned blocks or entities.

If destination preparation is not ready when the player reaches the boundary, the proxy and source may briefly hold or constrain the crossing according to later packet-classification and timeout rules, but they must not fake successful remote-side movement or allow unbounded buffering.

### State machine

The player handoff follows:

~~~text
ACTIVE_SOURCE
    -> PREPARING_DESTINATION
    -> DESTINATION_READY
    -> SOURCE_FROZEN
    -> SNAPSHOT_STAGED
    -> COMMITTED
    -> ACTIVE_DESTINATION
    -> SOURCE_CLEANED
~~~

Before COMMITTED, the source is the sole authoritative player simulator. The destination may allocate resources, load chunks, validate state, and construct a non-authoritative prepared player, but it cannot tick the player or create authoritative side effects.

The commit operation conditionally changes the authoritative live player-session record from the source and current epoch to the destination and next epoch under the rules above.

After COMMITTED, the destination is the sole authority. The source cannot resume or mutate the committed player session under its previous epoch.

### Preparation and player-state snapshot

The destination loads the target chunk, negotiates the supported snapshot schema and features, and prepares all resources needed to activate the player before declaring DESTINATION_READY.

The source freezes the player at a tick boundary and produces a final, versioned snapshot. The snapshot contains all authoritative state required to continue behavior without duplication or loss, including:

- World, dimension, position, rotation, velocity, and movement state
- Inventory, selected slot, carried item, and equipment
- Health, absorption, food, saturation, exhaustion, air, fire, and freeze state
- Experience, game mode, abilities, attributes, and active effects
- Item, attack, and other gameplay cooldowns
- Fall, damage, combat, and portal-related state
- Player-specific protocol synchronization state required for continuity
- The source tick, player-state version, transfer identifier, and all relevant epochs

After SOURCE_FROZEN, the destination validates and stages the actual final snapshot without ticking the player or creating authoritative side effects. It acknowledges SNAPSHOT_STAGED only when it can activate that exact state. A transfer cannot commit if the destination would silently discard state it does not understand.

Vehicles, passengers, open containers, sleeping, active portals, and similar multi-entity or UI-bound states require explicit support. Until production behavior is defined, an implementation must abort or delay an unsupported handoff rather than silently corrupting or dropping that state.

### Packet routing and buffering

During ACTIVE_SOURCE and PREPARING_DESTINATION:

- Replayable serverbound gameplay packets continue to the source while they remain valid for source-owned world state.
- Authoritative clientbound gameplay packets continue from the source to the client.
- Clientbound gameplay output from the prepared destination is withheld.

When a replayable movement input would cross into the destination partition, that crossing input is not forwarded for authoritative application on the source. It becomes the first item in the bounded ordered handoff buffer described below.

After SOURCE_FROZEN and before COMMITTED:

- The proxy holds a bounded, ordered buffer of replayable serverbound gameplay input.
- The source may continue only the protocol activity required to keep the session valid.
- The destination remains non-authoritative and its gameplay output remains withheld.

After COMMITTED:

- Clientbound gameplay output from the old source is rejected.
- The destination activates the staged final snapshot before processing buffered gameplay input.
- Buffered replayable input is released to the destination in order and tagged with the new session epoch.
- The held boundary-crossing movement input is processed by the destination, never by the source.
- The destination becomes the only backend allowed to emit authoritative gameplay output for that player.

Protocol-control traffic is not blindly buffered or replayed. Keepalives, teleport confirmations, signed-chat state, acknowledgements, configuration-state packets, and other connection-sensitive traffic must be classified and handled according to protocol semantics.

Buffers have explicit time and size bounds. Overflow or timeout before commit aborts the transfer and resumes the source when safe; the implementation must not accumulate unbounded input while a destination stalls. On abort, any held crossing input that would place the player inside remote-owned world state is not replayed to the source as authoritative movement.

A same-world, same-dimension partition handoff must not intentionally issue a reconnect, respawn, configuration transition, or other packet sequence that exposes a loading screen. The vertical slice must determine the exact packet classification and translation required to satisfy this constraint.

### Observer continuity

When the handoff commits, the source converts the player's locally authoritative tracked representation into the remote projection defined by ADR 0004.

If Alex remains on the source while Steve moves to the destination:

1. Steve's viewer-facing entity identity remains stable for Alex.
2. Steve's player-session epoch advances at commit.
3. The source does not remove Steve solely because simulation authority changed.
4. The destination begins streaming Steve's projected state to the source using the committed player-session epoch.
5. The source continues sending updates while Steve remains within Alex's configured tracking range.

The destination must not publish Steve as an authoritative entity to remote viewers before commit. A viewer server rejects projection updates from an older player-session epoch even when the surrounding partition ownership epochs have not changed.

### Failure behavior

Failure handling depends on the commit point:

| Failure | Required behavior |
| --- | --- |
| Destination rejects or times out during preparation | Discard destination state; source continues |
| Transfer aborts while source is frozen but before commit | Unfreeze source and release only input that is still safe for source-owned world state; never replay remote-side crossing movement to the source |
| Source fails before commit | Destination cannot assume authority autonomously; the proxy may commit only if a final snapshot was staged and every fencing precondition still holds, otherwise use normal recovery or disconnect safely |
| Commit acknowledgement is lost | Read the authoritative proxy live player-session record and resolve idempotently; never guess |
| Destination fails after commit | Never reactivate the source's old epoch; hold, recover, or disconnect the player safely |
| Client disconnects before commit | Abort and clean both prepared and source session state |
| Client disconnects after commit | Clean the destination session and source projection |
| Stale or duplicated message arrives | Reject it or return the already-recorded idempotent result |

A proxy process failure currently terminates its client connection. Proxy high availability and live client-session takeover remain a separate decision.

### Vertical-slice validation

The first implementation validates this state machine before introducing Redis, SQL, automatic partition allocation, durability replication, or the final wire protocol. This is an explicit experimental exception to the production infrastructure requirements in ADR 0002 and the repository README; it applies only to the vertical slice described here and does not change the production architecture.

The vertical slice uses:

- One Continuity Proxy process
- Two Continuity Server processes
- One world and dimension
- One manually configured partition boundary
- An in-memory ownership map
- An in-memory authoritative live player-session record owned by the proxy
- An unmodified Minecraft client
- An on-foot player with no vehicle, open container, sleep, or portal transition

The slice transfers at least:

- Position and rotation
- Velocity
- Inventory and selected slot
- Health and food state
- Experience
- Game mode and abilities
- Active effects

It includes a second player who remains on the source and continuously observes the transferred player.

Acceptance requires:

- No client disconnect, reconnect, loading screen, or intentional respawn transition
- No lost or duplicated tested player state
- No tick in which both servers consider the player authoritative
- No source-side authoritative position inside the destination-owned partition before commit
- The boundary-crossing movement input is processed first by the destination after commit
- No unnecessary disappearance or respawn for the observing player
- Stale player projection updates from the previous player-session epoch are rejected
- Safe behavior for duplicate messages, destination timeout, pre-commit abort, and lost commit acknowledgement
- Recorded handoff latency, source-freeze duration, buffered-packet count, and phase timings
- Failure injection at every state transition

The vertical slice may use the simplest direct experimental transport. Its results inform the later wire-protocol decision rather than prematurely making that protocol permanent.

## Consequences

### Benefits

- Player and partition ownership changes have separate, understandable semantics.
- The explicit commit point prevents two authoritative player simulations.
- The source never authoritatively simulates the player against world state owned by another server.
- Preparation hides chunk loading and destination setup from the client.
- Bounded buffering preserves short input windows without allowing unlimited memory growth.
- Epochs and transfer identifiers make retries and delayed messages safe.
- The live session commit has a defined authoritative record rather than an unspecified atomic transition.
- The vertical slice tests the highest-risk product claim before infrastructure work expands.

### Costs and risks

- The proxy and both server forks require protocol-aware handoff code.
- The player snapshot is versioned, broad, and must evolve with Minecraft.
- Packet classification is complex and version-sensitive.
- Boundary approach may require temporarily constraining movement when destination preparation is slow.
- Some player states cannot be transferred safely until additional protocols exist.
- Post-commit destination failure cannot simply roll back to the stale source.
- Perfect observer continuity requires coordination with boundary projection.
- Future proxy high availability will require a new consensus or takeover design for the authoritative live player-session record.

## Rejected alternatives

- **Use an ordinary visible proxy server switch:** violates the transparent-transfer requirement.
- **Save to SQL and reload the player on the destination:** adds persistence latency and cannot preserve all live protocol and simulation state.
- **Tick the player on source and destination during overlap:** creates dual authority and duplicate side effects.
- **Activate the destination before an atomic commit:** allows conflicting ownership during races or retries.
- **Let the source commit movement inside the remote-owned partition before handoff:** requires the source to authoritatively resolve physics and world interactions against state it does not own.
- **Buffer every packet without classification:** replays connection-sensitive protocol traffic incorrectly.
- **Use unbounded buffering:** turns a stalled handoff into a memory-exhaustion path.
- **Infer handoff commit from backend acknowledgements or timeout:** creates ambiguous authority after message loss; the authoritative live session record must be read instead.
- **Use one generic state machine for player handoff and partition migration:** conflates different ownership records, payloads, and failure behavior.
- **Finalize the production wire protocol before a spike:** hardens assumptions before the core transition is proven.

## References

- [ADR 0001: Transparent spatial sharding](0001-transparent-spatial-sharding.md)
- [ADR 0002: Messaging, coordination, and durable state](0002-messaging-coordination-and-state.md)
- [ADR 0003: Partition directory, allocation, and membership changes](0003-partition-directory-allocation-and-membership.md)
- [ADR 0004: Owner-local partition storage and boundary visibility](0004-owner-local-storage-and-boundary-visibility.md)

## Compliance

An implementation conforms to this decision only if:

- A player has one authoritative server and a separately fenced player-session epoch.
- The Continuity Proxy owns a defined authoritative live player-session record in the initial single-proxy topology.
- The destination remains non-authoritative until an atomic conditional commit of that live session record.
- The source cannot resume an epoch after ownership has committed elsewhere.
- A movement input that would cross into a remote-owned partition is not authoritatively applied by the source.
- The destination validates and stages the complete supported snapshot before commit.
- Packet routing changes only at the commit point and buffering remains bounded.
- The held boundary-crossing movement input is processed by the destination only after commit.
- Connection-sensitive protocol packets are classified rather than blindly replayed.
- Lost commit acknowledgements are resolved by reading the authoritative live session record rather than guessing.
- The partition directory does not change merely because a player crosses a boundary.
- Nearby observers retain the projected player without an unnecessary despawn and respawn.
- Player projection updates are fenced by player-session epoch.
- The experimental vertical-slice infrastructure exception remains limited to the exact scope defined here.
- Failure tests demonstrate the documented behavior at every phase.
