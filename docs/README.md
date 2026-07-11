# Continuity design documentation

This directory records Continuity's architecture and accepted design decisions. It is the project's source of truth for architectural intent.

If an implementation conflicts with an accepted decision, the implementation is non-conforming until either it is corrected or a new decision explicitly supersedes the old one.

## Documents

- [Architecture overview](architecture.md)
- [ADR 0001: Transparent spatial sharding](decisions/0001-transparent-spatial-sharding.md)
- [ADR 0002: Messaging, coordination, and durable state](decisions/0002-messaging-coordination-and-state.md)
- [ADR 0003: Partition directory, allocation, and membership changes](decisions/0003-partition-directory-allocation-and-membership.md)
- [ADR 0004: Owner-local partition storage and boundary visibility](decisions/0004-owner-local-storage-and-boundary-visibility.md)
- [ADR 0005: Player handoff state machine and packet continuity](decisions/0005-player-handoff-state-machine.md)
- [ADR template](decisions/template.md)

## Decision lifecycle

Architecture Decision Records use one of these statuses:

- **Proposed** — under discussion and not yet binding.
- **Accepted** — normative for new and existing implementation work.
- **Deprecated** — retained for historical context but no longer recommended.
- **Superseded** — replaced by another ADR, which must be linked.

To introduce or change an architectural decision:

1. Copy the ADR template and assign the next sequential number.
2. Describe the constraints, decision, rejected alternatives, and consequences.
3. Mark the ADR as Proposed while it is being discussed.
4. Accept the ADR before merging implementation that depends on it.
5. Replace an accepted decision with a new ADR instead of silently rewriting history.

Corrections and clarifications may be applied to an accepted ADR only when they do not change its meaning.

An accepted ADR may explicitly authorize a limited experimental vertical slice or protocol spike to substitute simpler infrastructure or reduced scope. Such an exception is conforming only within the exact experiment described by that ADR and does not weaken production requirements.

## Review rule

A change must update these documents or add an ADR when it alters any of the following:

- Component responsibilities or trust boundaries
- Ownership, consistency, or failure semantics
- Inter-component protocols or compatibility guarantees
- Required infrastructure or persistence behavior
- Player-visible behavior during routing or transfer

Pull requests should identify the ADRs they implement or state why no design documentation change is required.
