# ADR 0001: Transparent spatial sharding

- **Status:** Accepted
- **Date:** 2026-07-11

## Context

A large survival world can place more simulation work on a single Minecraft server's main game tick than it can complete on time. Separating players into unrelated worlds or exposing explicit server switches reduces load, but breaks the experience of one continuous world.

## Decision

Continuity distributes one logical world across multiple Continuity Servers using spatial partitions.

The Continuity Proxy keeps the player-facing connection and routes each player to the Continuity Server authoritative for the player's current position. When the player crosses an ownership boundary, Continuity transfers backend authority without requiring a reconnect or exposing a loading screen or server transition to the client.

Every player and partition has at most one authoritative server at a time. Authority changes use an epoch or equivalent fencing token so delayed work from a previous owner cannot mutate current state.

This decision does not fix the shape or size of partitions. Those policies may evolve independently as long as they preserve the authority and transparency invariants.

## Consequences

### Benefits

- Simulation load can be spread across multiple server processes.
- Players experience one world and one logical server.
- Partition placement and reassignment can evolve without changing the client-facing model.

### Costs and risks

- Transfers require an explicit distributed commit and recovery protocol.
- Interactions across partition boundaries require synchronization or clearly defined ownership.
- The proxy and partition map become critical coordination components.
- Testing must cover delay, duplication, disconnection, and process failure during every transfer phase.

## Rejected alternatives

- **One vertically scaled server:** preserves behavior but does not remove the single-process simulation ceiling.
- **Independent worlds or game instances:** scales more easily but does not provide one continuous survival world.
- **Visible proxy server switches:** distributes players but violates the seamless-transfer requirement.

## Compliance

An implementation conforms to this decision only if it preserves single authority, position-based routing, and a client-transparent backend transfer.
