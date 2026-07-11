# ADR 0002: Messaging, coordination, and durable state

- **Status:** Accepted
- **Date:** 2026-07-11

## Context

Continuity needs low-latency coordination, synchronous transfer commands, best-effort notifications, retryable asynchronous work, and permanent storage. These workloads have different delivery and durability requirements and must not be forced through one messaging primitive.

Kafka provides a durable distributed event log, but its operational and semantic model is not required for Continuity's latency-sensitive control plane. Redis is already useful for short-lived distributed state, but Redis Pub/Sub alone can permanently lose messages when a subscriber is unavailable.

## Decision

Continuity uses different mechanisms according to the required semantics:

| Workload | Mechanism |
| --- | --- |
| Synchronous handoff commands and acknowledgements | Persistent direct proxy/server control connection |
| Presence, leases, partition ownership, and temporary transfer state | Redis keys with expirations and atomic transitions |
| Reconstructible notifications and cache invalidation | Redis Pub/Sub |
| Retryable asynchronous commands and events | Redis Streams |
| Permanent state and durable audit records | SQL database |

Redis Pub/Sub is used only when a recipient can recover by rereading authoritative state. No correctness-critical transition may depend solely on receiving a Pub/Sub message.

Redis Streams consumers use acknowledgements and may receive a message more than once. Stream handlers must therefore be idempotent and carry stable message or operation identifiers.

A player transfer carries enough information to reject stale or duplicate work, including a transfer identifier, player identifier, source and destination server identifiers, partition identifier, ownership epoch, state version, and protocol version.

SQL is the permanent source of truth. Redis may accelerate and coordinate operations, but loss of Redis must result in safe recovery or loss of availability rather than conflicting authority or duplicated permanent state.

Kafka is not a required Continuity dependency. A future optional integration may export telemetry or domain events to Kafka without placing Kafka in the player-transfer path.

Ordinary per-tick movement is processed by the proxy and authoritative server rather than being published through Redis Streams, Redis Pub/Sub, or Kafka.

## Consequences

### Benefits

- Latency-sensitive request/response traffic avoids broker queues and consumer lag.
- Best-effort and reliable workloads have explicit, different semantics.
- Continuity does not require operators to deploy Kafka for the core runtime.
- Durable state remains separate from temporary coordination state.

### Costs and risks

- The system must implement and test more than one communication pattern.
- Redis Streams provide at-least-once processing, so duplicate handling is mandatory.
- Direct control connections require reconnect, timeout, backpressure, and protocol-version handling.
- Redis high availability and SQL consistency still require deliberate deployment and failure testing.

## Rejected alternatives

- **Redis Pub/Sub for every message:** cannot recover messages missed during a disconnect or crash.
- **Kafka for all inter-component communication:** adds a durable-log platform while still not replacing leases, synchronous request/response, or SQL.
- **SQL polling as the message bus:** couples temporary coordination to the permanent store and adds polling latency and load.

## Compliance

Every new message type must document whether it is best-effort, retryable, or synchronous; its ordering requirements; its idempotency key; and the authoritative state used for recovery.
