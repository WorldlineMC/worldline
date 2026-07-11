# Architecture overview

**Status:** Normative

## Goal

Continuity presents one logical Minecraft server and world while distributing simulation work across multiple backend server processes. A player may move between backend servers without a reconnect, loading screen, or other client-visible server transition.

## Components

### Continuity Proxy

The Continuity Proxy is derived from Velocity. It:

- Owns the player-facing connection.
- Tracks the backend currently serving each player.
- Routes players according to their position and the current partition map.
- Coordinates seamless transfers between Continuity Servers.

### Continuity Server

A Continuity Server is derived from Paper. It:

- Simulates the partitions currently assigned to it.
- Acts as the sole authority for players and game state committed to those partitions.
- Participates in transfer preparation, commit, abort, and recovery.
- Maintains read-only boundary projections needed by its local players.

### Redis

Redis provides distributed coordination, short-lived state, leases, notifications, and retryable asynchronous messaging. Redis data is not the permanent source of truth.

### SQL database

The SQL database stores permanent state and durable records that must survive the loss or replacement of Redis and individual Continuity processes. This includes the authoritative partition directory and sticky server assignments.

## Partition directory and membership

The world is divided into fixed rectangular partitions containing whole chunks. Partitions have stable logical identifiers and configurable dimensions rather than identities derived from the server currently hosting them.

The SQL partition directory stores each materialized partition's durable assignment and ownership epoch. Redis stores the corresponding live lease, cached directory data, server presence, and short-lived coordination state.

Unexplored parts of the world do not require preallocated directory rows. A partition is materialized atomically when first approached, assigned to an active server, and then remains sticky until the coordinator explicitly migrates it.

Adding a server does not recalculate existing ownership. The server becomes eligible for new allocations and may receive existing partitions through gradual, rate-limited rebalancing. Graceful removal drains and migrates every owned partition before shutdown. Unexpected failure requires lease expiry and a higher ownership epoch before replacement authority is granted.

## Storage and boundary visibility

The authoritative owner stores its partition's writable world files locally. Durability replication copies snapshots and subsequent changes to read-only targets for migration and recovery. No two Continuity Servers may write the same physical world-storage file.

Durability replication is distinct from live boundary projection. A server whose local players can see into a neighboring partition subscribes to a visibility halo containing the required read-only chunks, entities, players, block changes, and visible effects.

Remote entity projections are presentation objects. They do not tick, run AI or physics, persist data, or gain authority. A player remains visible across a server boundary whenever that player would be tracked on one Paper server. Stable cluster identity and viewer-side protocol identity prevent a visible despawn and respawn during handoff.

Interactions with projected remote state are routed to the authoritative owner, which validates and applies them. Ordinary chunk boundaries do not trigger transfers; only configured partition boundaries do.

## Player handoff

A player crossing a partition boundary triggers a player handoff, not a partition migration. The destination partition keeps its existing owner and the durable partition directory does not change.

The Continuity Proxy retains the client connection and coordinates an explicit prepare, freeze, snapshot-stage, commit, activate, and cleanup state machine. A player-session epoch fences the player's live authority independently from the destination partition's ownership epoch.

Before commit, the source is the sole player authority and the destination may only prepare. After commit, the destination is the sole authority and the source cannot resume its previous epoch. Gameplay packets are routed or briefly buffered according to the current phase; protocol-control packets are handled separately and are never blindly replayed.

The destination applies a versioned final player-state snapshot before buffered gameplay input is released. The source converts its tracked player into a boundary projection for nearby observers without an unnecessary client-visible removal.

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

## Undecided details

This document intentionally does not yet choose:

- Exact partition dimensions or automatic rebalancing heuristics
- Durability replica placement, replication factor, journal format, synchronous mode, or recovery objectives
- The SQL database engine or schema
- The wire protocol, packet classification, buffer limits, and timeout budgets used by direct proxy/server control connections
- Production behavior for handoffs involving vehicles, open containers, sleeping, portals, or other complex player states
- Complete mechanics for cross-boundary collisions, projectiles, explosions, fluids, redstone, or mob AI
- Plugin API behavior for projected remote players and entities
- The deployment topology for high availability

Those choices require separate ADRs.
