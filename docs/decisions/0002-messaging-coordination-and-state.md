# ADR 0002: Messaging, coordination, and durable state

- **Status:** Accepted
- **Date:** 2026-07-11

## Context

Worldline needs low-latency coordination, synchronous transfer commands, best-effort notifications, retryable asynchronous work, and permanent storage. These workloads have different delivery and durability requirements and must not be forced through one messaging primitive.

Kafka provides a durable distributed event log, but its operational and semantic model is not required for Worldline's latency-sensitive control plane. Redis is already useful for short-lived distributed state, but Redis Pub/Sub alone can permanently lose messages when a subscriber is unavailable.

## Decision

Worldline uses different mechanisms according to the required semantics:

| Workload | Mechanism |
| --- | --- |
| Synchronous handoff commands and acknowledgements | Persistent direct proxy/server control connection |
| Presence, live partition leases, cached ownership, and temporary transfer state | Redis keys with expirations and atomic transitions |
| Reconstructible notifications and cache invalidation | Redis Pub/Sub |
| Retryable asynchronous commands and events | Redis Streams |
| Permanent control-plane metadata and durable audit records | SQL database |

[ADR 0003](0003-partition-directory-allocation-and-membership.md) clarifies the partition-ownership entry above: SQL stores the durable partition directory and sticky assignment, while Redis stores the live ownership lease and cached directory state. [ADR 0004](0004-owner-local-storage-and-boundary-visibility.md) separately defines owner-local authoritative world storage and durability replication for chunks, entities, and other world data.

Redis Pub/Sub is used only when a recipient can recover by rereading authoritative state. No correctness-critical transition may depend solely on receiving a Pub/Sub message.

Redis Streams consumers use acknowledgements and may receive a message more than once. Stream handlers must therefore be idempotent and carry stable message or operation identifiers.

Player-handoff commands and snapshots follow the identity and fencing model in [ADR 0005](0005-player-handoff-state-machine.md). They carry enough information to reject stale or duplicate work, including at least:

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

SQL is the permanent source of truth for durable control-plane metadata, including partition assignments, sticky ownership, and audit records. Redis may accelerate and coordinate operations, but loss of Redis must result in safe recovery or loss of availability rather than conflicting authority or duplicated permanent state. SQL is not the primary blob store for ordinary chunk, entity, or point-of-interest world data; that data follows ADR 0004.

Kafka is not a required Worldline dependency. A future optional integration may export telemetry or domain events to Kafka without placing Kafka in the player-transfer path.

Ordinary per-tick movement is processed by the proxy and authoritative server rather than being published through Redis Streams, Redis Pub/Sub, or Kafka.

## Consequences

### Benefits

- Latency-sensitive request/response traffic avoids broker queues and consumer lag.
- Best-effort and reliable workloads have explicit, different semantics.
- Worldline does not require operators to deploy Kafka for the core runtime.
- Durable control-plane state remains separate from temporary coordination state and owner-local world storage.

### Costs and risks

- The system must implement and test more than one communication pattern.
- Redis Streams provide at-least-once processing, so duplicate handling is mandatory.
- Direct control connections require reconnect, timeout, backpressure, and protocol-version handling.
- Redis high availability, SQL consistency, and world-storage durability still require deliberate deployment and failure testing.

## Rejected alternatives

- **Redis Pub/Sub for every message:** cannot recover messages missed during a disconnect or crash.
- **Kafka for all inter-component communication:** adds a durable-log platform while still not replacing leases, synchronous request/response, or SQL.
- **SQL polling as the message bus:** couples temporary coordination to the permanent store and adds polling latency and load.

## Compliance

Every new message type must document whether it is best-effort, retryable, or synchronous; its ordering requirements; its idempotency key or duplicate-handling rule; and the authoritative state used for recovery. Later ADRs that introduce message types must satisfy this contract explicitly or state why a field is not applicable.
