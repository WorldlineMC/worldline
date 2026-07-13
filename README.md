# Worldline

Worldline is a Minecraft server software suite designed for one purpose: bringing distributed systems to Minecraft servers.

It allows a single survival world to be distributed across multiple backend servers while presenting players with one continuous world.

## How it works

A traditional Minecraft server can become constrained by its main game tick as its player count and active world area grow. Worldline distributes that workload across two components:

- **Worldline Proxy** — a fork of Velocity that accepts player connections and routes each player to a backend according to their current position in the world.
- **Worldline Server** — a fork of Paper that runs an authoritative partition of the world.

When a player attempts to cross into a partition owned by another Worldline Server, the proxy transfers player authority to that server seamlessly. The source does not authoritatively apply movement inside the remote-owned partition before the handoff commits. The transfer should not display a loading screen, require a reconnect, or otherwise reveal the backend change to the client.

## Infrastructure requirements

Production Worldline deployments require:

- **Redis** for distributed coordination, short-lived state, and retryable asynchronous messaging.
- **SQL database** for durable control-plane metadata and audit records.

Authoritative world data is stored owner-locally and replicated according to the accepted storage decisions in `docs/decisions/0004-owner-local-storage-and-boundary-visibility.md`; SQL is not the primary blob store for ordinary chunk, entity, or point-of-interest data.

Accepted ADRs may explicitly authorize a limited experimental vertical slice or protocol spike to substitute simpler infrastructure when the experiment is testing behavior rather than production durability.

## Documentation

Worldline's architecture and accepted design decisions live in [docs](docs/README.md). These documents are normative: implementation changes that conflict with an accepted decision must first supersede that decision.

## Status

Worldline is in early development.
