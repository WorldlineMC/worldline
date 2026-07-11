# ADR 0004: Owner-local partition storage and boundary visibility

- **Status:** Accepted
- **Date:** 2026-07-11
- **Extends:** ADR 0001, ADR 0002, and ADR 0003

## Context

Continuity needs fast world I/O, exclusive authority, safe partition migration, and recovery after owner failure. It must also make server boundaries invisible to players.

These requirements involve two different forms of replication:

| Replication plane | Purpose | Representative data |
| --- | --- | --- |
| Durability replication | Migration and crash recovery | World-file snapshots, journals, and final deltas |
| Boundary projection | Live client-visible continuity | Nearby chunks, players, entities, block changes, and visible effects |

Conflating the two would be unsafe. A boundary projection contains only the state required to present or interact with a neighboring partition; it is not necessarily complete or durable enough to recover that partition.

## Decision

### Owner-local authoritative storage

The authoritative Continuity Server stores its partition's writable world data on local storage using Paper's native storage formats where practical.

Exactly one server may write a partition's world data. Partition boundaries and storage layout must ensure that two owners never write the same physical storage file. If a native file would span multiple logical partitions, Continuity must adjust the partition layout or isolate writes through a storage adapter before those partitions can have different owners.

SQL stores directory and metadata state rather than serving as the primary blob store for ordinary chunk, entity, or point-of-interest data.

### Durability replication

An owner replicates a consistent base snapshot and subsequent changes to one or more read-only durability targets. A target may be another Continuity Server or a future durable storage service, but it cannot tick, modify, or serve the partition as authoritative without a coordinator-approved ownership change and newer epoch.

Migration uses the following shape:

1. Transfer or make available a consistent base snapshot.
2. Continue serving the partition while recording or streaming subsequent mutations.
3. Bring the destination current with ordered changes.
4. Freeze mutations briefly at a tick boundary.
5. Flush and transfer the final delta.
6. Commit the new owner and ownership epoch.
7. Start the destination and retire the old writable copy.

The exact snapshot format, journal format, replication target, replication factor, synchronous or asynchronous acknowledgement policy, recovery point objective, and recovery time objective remain undecided. Continuity must expose the actual protection state and must not claim zero-data-loss recovery unless a later accepted decision provides it.

### Visibility halos

Each Continuity Server maintains an interest-based visibility halo for its local players. When that halo overlaps a partition owned by another server, the viewer server subscribes to the authoritative owner for the required projected state.

The halo covers the configured client view distance, entity-tracking distances, and any additional margin required by supported interactions. It is calculated from current configuration rather than hardcoded.

Interest should be aggregated per receiving server where possible. The owner streams a shared superset of relevant state to that server, which then filters and fans it out to individual local players.

Projected state may include:

- Read-only chunk and lighting snapshots
- Block and block-entity changes
- Player and entity spawn state
- Position, rotation, velocity, pose, and metadata
- Equipment, profile, and skin information
- Animations, particles, sounds, and other visible effects

The viewer server emits ordinary Minecraft packets for projected state. The proxy coordinates backend ownership and connection continuity but does not become a centralized per-tick packet compositor for every neighboring partition.

Boundary projection uses persistent direct server connections rather than Redis Pub/Sub or Redis Streams. Reliable lifecycle messages establish and remove projections. High-rate transient updates carry ordering information and support snapshot resynchronization after a gap or reconnect. The exact wire protocol remains a separate decision.

### Remote entity projections

A remote player or entity is represented on the viewer server by a read-only projection rather than a normal locally authoritative entity.

A projection:

- Does not tick or run AI
- Does not perform local physics or collision resolution
- Is not persisted to local world files
- Cannot be mutated through ordinary local ownership paths
- Carries the authoritative owner's server identifier and ownership epoch
- Is discarded or resynchronized when its stream becomes stale

Remote projections are not exposed as ordinary mutable Paper entities. A future Continuity API may expose read-only remote-player and remote-entity views to plugins.

Entities use a stable cluster identity independent of their current owner. Viewer-facing protocol identities remain stable across a handoff whenever the entity stays visible, preventing an unnecessary despawn and respawn.

### Player handoff visibility

Consider Steve moving from a partition on Server A into a partition on Server B while Alex remains on Server A:

1. Server B becomes Steve's sole authority after the handoff commits.
2. Server A converts Steve's local tracked representation into a remote projection without removing Steve from Alex's view.
3. Server B streams Steve's visible state to Server A.
4. Server A continues emitting updates to Alex while Steve remains within Alex's configured tracking range.
5. Server A removes the projection normally after no local player has interest in it.

If Alex later crosses to Server B, the same cluster identity and viewer-facing mapping preserve continuity through her backend handoff.

This guarantee applies at partition boundaries. Crossing an ordinary chunk boundary inside one partition does not change servers.

[ADR 0005](0005-player-handoff-state-machine.md) defines the player-session state machine, packet routing, commit point, and failure behavior used for this transition.

### Cross-boundary interactions

When a local player targets a projected remote entity or block, the viewer server routes the interaction to the authoritative owner with the actor identity, target identity, relevant state version, and ownership epoch.

The authoritative owner validates the request against current position, line of sight, cooldowns, permissions, and world state before applying any mutation. Results are returned through normal authoritative updates and boundary projection.

Direct player interactions across a boundary must use this ownership route. Complete semantics for collisions, projectiles, explosions, fluids, redstone, and AI spanning multiple owners remain undecided and require later decisions.

## Consequences

### Benefits

- Authoritative world I/O remains local to the ticking server.
- Two servers never write the same world-storage file.
- Storage replicas support migration and future crash recovery without creating multiple authorities.
- Players can see one another and surrounding terrain across a server boundary.
- The proxy avoids becoming a centralized fan-in for every world tick.
- Boundary bandwidth scales with active interest instead of total world size.

### Costs and risks

- Continuity must modify Paper's chunk and entity tracking paths.
- Projection state requires versioning, resynchronization, backpressure, and stale-stream handling.
- Stable viewer-facing entity identity requires protocol-aware bookkeeping across handoffs.
- Plugins cannot safely treat projected players as ordinary mutable local players.
- Exact durability guarantees and many cross-boundary mechanics remain unresolved.
- Small partitions would cause excessive halo overlap and transfer frequency.

## Rejected alternatives

- **Shared writable world directory:** risks concurrent access to native world files and makes network storage part of every active I/O path.
- **Store ordinary chunks directly in SQL:** centralizes durability but requires a large storage rewrite and places chunk blobs on the metadata database path.
- **Tick the same boundary entities on both servers:** creates conflicting simulation authority.
- **Treat live projections as durability replicas:** projected state is partial, transient, and insufficient for safe recovery.
- **Compose every neighboring server's packets in the proxy:** centralizes per-tick world traffic and duplicates backend tracking logic.
- **Expose projections as normal mutable Paper entities:** permits plugins and local systems to mutate non-authoritative state.
- **Transfer at every chunk boundary:** creates constant handoffs and makes boundary replication dominate the system.

## References

- [ADR 0001: Transparent spatial sharding](0001-transparent-spatial-sharding.md)
- [ADR 0002: Messaging, coordination, and durable state](0002-messaging-coordination-and-state.md)
- [ADR 0003: Partition directory, allocation, and membership changes](0003-partition-directory-allocation-and-membership.md)
- [ADR 0005: Player handoff state machine and packet continuity](0005-player-handoff-state-machine.md)
- [Paper entity-tracking configuration](https://docs.papermc.io/paper/reference/spigot-configuration/#entity-tracking-range)

## Compliance

An implementation conforms to this decision only if:

- A partition has one writable owner and no physical world-storage file has multiple writers.
- Durability replicas and boundary projections remain read-only until an explicit fenced ownership change.
- A local player receives remote players and entities within the same configured tracking rules used for local entities.
- Steve remains visible to Alex across a handoff when he remains within tracking range.
- A visible handoff does not unnecessarily despawn and respawn the transferred entity.
- Projected chunks and entities never tick or persist on the viewer server.
- Interactions with projected state are routed to and validated by the authoritative owner.
- Stream gaps, stale epochs, reconnects, and lost lifecycle messages trigger safe removal or full resynchronization.
- Tests cover viewers on both sides of every partition edge and corner, including simultaneous handoffs.
