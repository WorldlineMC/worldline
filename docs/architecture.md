# Architecture overview

**Status:** Normative

## Goal

Continuity presents one logical Minecraft server and world while distributing simulation work across multiple backend server processes. A player may move between backend servers without a reconnect, loading screen, or other client-visible server transition.

## Components

### Continuity Proxy

The Continuity Proxy is derived from Velocity. It:

- Owns the player-facing connection.
- Tracks the backend currently serving each player.
- Owns the authoritative live player-session record for each connected client in the initial single-proxy topology.
- Routes players according to their position and the current partition map.
- Coordinates seamless player handoffs between Continuity Servers.
- Holds the active partition-coordinator role in the initial single-proxy topology.

### Continuity Server

A Continuity Server is derived from Paper. It:

- Simulates the partitions currently assigned to it.
- Acts as the sole authority for players and game state committed to those partitions.
- Participates in transfer preparation, commit, abort, and recovery.
- Maintains read-only boundary projections needed by its local players.

### Coordinator role

The active coordinator serializes partition materialization, allocation, migration, and membership-driven ownership changes. In the initial single-proxy topology, the Continuity Proxy holds this role. A future highly available coordinator or leader-election design requires a separate accepted ADR.

### Redis

Redis provides distributed coordination, short-lived state, leases, notifications, and retryable asynchronous messaging. Redis data is not the permanent source of truth.

### SQL database

The SQL database stores permanent control-plane state and durable records that must survive the loss or replacement of Redis and individual Continuity processes. This includes the authoritative partition directory, sticky server assignments, and durable audit records. Ordinary chunk, entity, and point-of-interest world data is stored owner-locally according to ADR 0004 rather than using SQL as the primary blob store.

## Partition directory and membership

The world is divided into fixed rectangular partitions containing whole chunks. Partitions have stable logical identifiers and configurable dimensions rather than identities derived from the server currently hosting them.

The SQL partition directory stores each materialized partition's durable assignment and ownership epoch. Redis stores the corresponding live lease, cached directory data, server presence, and short-lived coordination state.

Unexplored parts of the world do not require preallocated directory rows. A partition is materialized atomically by the active coordinator when first approached, assigned to an active server, and then remains sticky until the coordinator explicitly migrates it.

Adding a server does not recalculate existing ownership. The server becomes eligible for new allocations and may receive existing partitions through gradual, rate-limited rebalancing. Graceful removal drains and migrates every owned partition before shutdown. A draining server is not eligible to receive new player-session handoffs into its partitions, and it may become offline only after it owns no partitions, has no authoritative player sessions, and has no transfer or migration in progress. Unexpected failure requires lease expiry, recoverable partition state, and a higher ownership epoch before replacement authority is granted.

## Storage and boundary visibility

The authoritative owner stores its partition's writable world files locally. Durability replication copies snapshots and subsequent changes to read-only targets for migration and recovery. No two Continuity Servers may write the same physical world-storage file.

Durability replication is distinct from live boundary projection. A server whose local players can see into a neighboring partition subscribes to a visibility halo containing the required read-only chunks, entities, players, block changes, and visible effects.

Remote entity projections are presentation objects. They do not tick, run AI or physics, persist data, or gain authority. A player remains visible across a server boundary whenever that player would be tracked on one Paper server. Stable cluster identity and viewer-side protocol identity prevent a visible despawn and respawn during handoff. Player projection updates are fenced by player-session epoch; partition and non-player entity updates use the relevant partition ownership epoch or equivalent authority token.

Interactions with projected remote state are routed to the authoritative owner, which validates and applies them. Retryable interactions carry stable operation identifiers so duplicate delivery cannot apply the same authoritative action twice. Ordinary chunk boundaries do not trigger transfers; only configured partition boundaries do.

## Player handoff

A player attempting to cross a partition boundary triggers a player handoff, not a partition migration. The destination partition keeps its existing owner and the durable partition directory does not change.

The destination may be prepared before the player reaches the boundary. When a movement input would cross into a partition owned by another server, the source does not authoritatively apply the remote-side position. The proxy freezes and snapshots the source session, commits player-session authority to the destination, and releases the held crossing input to the destination only after commit.

The Continuity Proxy retains the client connection and coordinates an explicit prepare, freeze, snapshot-stage, commit, activate, and cleanup state machine. The proxy's live player-session record stores the current authoritative server, player-session epoch, active transfer identifier, and current handoff phase. In the initial single-proxy topology, the conditional transition of this record is the atomic handoff commit.

Before commit, the source is the sole player authority and the destination may only prepare. After commit, the destination is the sole authority and the source cannot resume its previous epoch. Gameplay packets are routed or briefly buffered according to the current phase; protocol-control packets are handled separately and are never blindly replayed.

The destination applies a versioned final player-state snapshot before buffered gameplay input is released. The source converts its tracked player into a boundary projection for nearby observers without an unnecessary client-visible removal.

## Plugin compatibility

Continuity targets transparent compatibility with existing unmodified Bukkit, Spigot, and Paper plugins for behavior inside the supported compatibility boundary defined by ADR 0006. To a compatible plugin, physical Continuity nodes are an implementation detail and the cluster behaves as one logical Paper server.

Supported state-changing API calls execute against the current authoritative owner exactly once and then propagate resulting committed state to interested nodes. A plugin mutation targeting a remote player, entity, chunk, block, or other projection is routed to authority rather than mutating an independent local copy.

Each plugin's conventional data directory is one logical cluster-wide namespace. Committed configuration and ordinary plugin-data file changes become visible across the cluster with defined ordering, conflict, and recovery semantics. File-backed databases and special storage engines require storage-aware handling rather than blind file copying.

Plugin lifecycle, command, event, and scheduler behavior must preserve one-logical-server semantics. Physical plugin copies must not unintentionally multiply scheduled work, lifecycle side effects, commands, authoritative events, or external effects solely because the cluster contains multiple nodes.

This compatibility runtime is a late-stage 1.0 requirement and is not required for the initial vertical slice. Earlier ownership, storage, handoff, scheduler, and projection designs must preserve a viable path to the ADR 0006 contract.

## Non-negotiable invariants

1. A player or partition has at most one authoritative Continuity Server at any instant.
2. Authority changes are fenced by an ownership epoch or equivalent monotonic token. A stale owner cannot commit mutations after authority has moved.
3. The source remains authoritative until a transfer commits. Preparing a destination does not grant it authority.
4. A failed transfer must resolve to a known owner or safely stop progress; it must never create two owners.
5. Missing a best-effort notification cannot corrupt world or player state.
6. Critical operations are idempotent and recoverable after duplicate delivery or process failure.
7. Redis loss may reduce availability, but must not silently violate ownership or duplicate permanent state.
8. Ordinary per-tick player movement is not routed through a centralized message broker.
9. Only an authoritative owner writes partition world data; replicas and projections remain read-only.
10. Players and entities remain visible across partition boundaries within the normal configured tracking rules.
11. Boundary projections never become authoritative without an explicit coordinator commit and a newer ownership epoch.
12. Player-session authority has its own epoch and exactly one authoritative server.
13. A destination cannot create authoritative player side effects before handoff commit.
14. A source can resume after a pre-commit abort, but can never resume an epoch that has committed to another server.
15. A movement input that would cross into a remote-owned partition is not authoritatively applied by the source; it is processed by the destination only after player-session authority commits.
16. Player projection updates are rejected when they carry a stale player-session epoch.
17. A partition migration cannot commit while authoritative player sessions remain inside that partition unless a future accepted ADR defines an atomic compound migration protocol.
18. A supported plugin mutation has one logical authoritative effect regardless of which physical node receives the call.
19. Managed plugin data paths do not silently diverge into unrelated node-local authoritative histories.
20. Physical plugin instances must not multiply logical lifecycle, command, scheduler, event, or external side effects solely because the cluster has multiple nodes.
21. Plugin mutations against remote projections route to the current authority and are fenced by the relevant epoch or equivalent authority token.

## Undecided details

This document intentionally does not yet choose:

- Exact partition dimensions or automatic rebalancing heuristics
- Durability replica placement, replication factor, journal format, synchronous mode, or recovery objectives
- The SQL database engine or schema
- The wire protocol, packet classification, buffer limits, and timeout budgets used by direct proxy/server control connections
- Production behavior for handoffs involving vehicles, open containers, sleeping, portals, or other complex player states
- Complete mechanics for cross-boundary collisions, projectiles, explosions, fluids, redstone, or mob AI
- The exact plugin compatibility runtime, remote-object proxy mechanism, managed plugin-filesystem implementation, scheduler coordination model, or compatibility-adapter framework
- The deployment topology for high availability
- An atomic compound protocol for migrating an occupied partition together with its player sessions

Those choices require separate ADRs.