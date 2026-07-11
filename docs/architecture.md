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

### Redis

Redis provides distributed coordination, short-lived state, leases, notifications, and retryable asynchronous messaging. Redis data is not the permanent source of truth.

### SQL database

The SQL database stores permanent state and durable records that must survive the loss or replacement of Redis and individual Continuity processes.

## Non-negotiable invariants

1. A player or partition has at most one authoritative Continuity Server at any instant.
2. Authority changes are fenced by an ownership epoch or equivalent monotonic token. A stale owner cannot commit mutations after authority has moved.
3. The source remains authoritative until a transfer commits. Preparing a destination does not grant it authority.
4. A failed transfer must resolve to a known owner or safely stop progress; it must never create two owners.
5. Missing a best-effort notification cannot corrupt world or player state.
6. Critical operations are idempotent and recoverable after duplicate delivery or process failure.
7. Redis loss may reduce availability, but must not silently violate ownership or duplicate permanent state.
8. Ordinary per-tick player movement is not routed through a centralized message broker.

## Undecided details

This document intentionally does not yet choose:

- Partition geometry, size, or reassignment policy
- The SQL database engine or schema
- The wire protocol used by direct proxy/server control connections
- The representation and synchronization of cross-boundary entities, blocks, or redstone
- The deployment topology for high availability

Those choices require separate ADRs.
