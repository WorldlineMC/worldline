# ADR 0006: Transparent Paper and Spigot plugin compatibility

- **Status:** Accepted
- **Date:** 2026-07-12
- **Extends:** ADR 0001, ADR 0002, ADR 0003, ADR 0004, and ADR 0005

## Context

Worldline presents multiple backend processes as one logical Minecraft server. Existing Bukkit, Spigot, and Paper plugins are overwhelmingly written with the assumption that there is one server process, one logical world, one player registry, one scheduler, one plugin data directory, and one authoritative copy of mutable game state.

A naive distributed implementation breaks that assumption in several ways:

- The same plugin may be loaded on multiple physical Worldline Servers.
- A scheduled task or lifecycle callback may run once per process instead of once per logical server.
- A player, entity, chunk, or world object may be authoritative on another server.
- A plugin may mutate a local projection even though another server owns the real state.
- `config.yml`, YAML files, JSON files, SQLite databases, or other plugin-owned files may diverge between nodes.
- Persistent Data Containers may move with players, entities, chunks, or worlds across ownership boundaries.
- A player handoff may move live authority while plugins continue to retain references or issue mutations.

Worldline's product goal is not merely to provide a new distributed plugin API. Existing, unmodified Paper and Spigot plugins should work wherever technically possible and should observe the same logical server model they were written for.

This requirement is expected to be implemented late in development, near the 1.0 milestone, but it is an architectural constraint immediately. Earlier implementation work must not make transparent compatibility impossible without a redesign.

Absolute compatibility with arbitrary JVM code cannot be guaranteed. A plugin can bypass Bukkit and Paper entirely by writing to arbitrary filesystem paths, opening sockets, connecting to external databases, using JNI, depending on process-local static state, modifying server internals through reflection, or performing other side effects outside Worldline's observable compatibility boundary. This ADR therefore defines a strong compatibility contract and an explicit boundary rather than making an untestable promise.

## Decision

### Compatibility goal

For a plugin targeting the Worldline-supported Paper version and using supported Bukkit, Spigot, or Paper contracts, Worldline MUST aim to make the unmodified plugin behave as though it were running on one conventional Paper server.

The physical distribution of players, worlds, chunks, entities, plugin execution, and storage across Worldline processes MUST remain an implementation detail unless a plugin explicitly opts into Worldline-specific APIs.

The default compatibility target is:

> One logical server, one logical plugin installation, one authoritative mutation, and one externally visible result, regardless of how many Worldline processes participate in producing that result.

This is a 1.0 product requirement. It is not required for the initial vertical slice described by ADR 0005, but accepted changes before 1.0 MUST preserve a viable path to it.

### Supported compatibility boundary

Transparent compatibility applies to behavior Worldline can observe and control, including:

- Supported Bukkit, Spigot, and Paper API calls.
- Plugin lifecycle, command, event, and scheduler integration points exposed by the supported server API.
- Files located inside the plugin's conventional data directory returned by `Plugin#getDataFolder()`.
- Persistent Data Containers attached to supported worlds, chunks, entities, block entities, players, items, and other persistent data holders.
- Server-managed world, player, entity, inventory, scoreboard, metadata, and offline-player state reachable through supported APIs.
- Worldline-owned player handoff, partition ownership, projection, replication, and recovery paths.

The following are outside the unconditional transparent-compatibility guarantee unless a dedicated adapter or later ADR brings them inside it:

- Arbitrary filesystem paths outside a plugin's managed data directory.
- External databases, caches, brokers, web services, sockets, or other network side effects directly owned by a plugin.
- JNI or native libraries with process-local assumptions.
- Unsupported NMS internals, reflection into implementation details, bytecode instrumentation of unsupported internals, or assumptions tied to a different Paper revision.
- Operating-system resources and side effects Worldline cannot safely virtualize or coordinate.

These exceptions do not prohibit support. Worldline SHOULD provide compatibility adapters for important plugins or common patterns when transparent support is feasible.

### Authority first, propagation second

A state-changing plugin call MUST have cluster-correct semantics. Worldline MUST NOT generally implement compatibility as:

~~~text
mutate independently on every server
then attempt to reconcile the results
~~~

The preferred model is:

~~~text
plugin invokes mutation
-> Worldline resolves authoritative owner
-> mutation executes exactly once under the current authority epoch
-> authoritative result is committed
-> resulting state, events, projections, and invalidations propagate to interested nodes
~~~

If a plugin invokes a mutating API on a non-authoritative server, Worldline MUST either route the operation to the authoritative owner or provide an equivalent mechanism that preserves the same single-logical-server result.

A stale owner, stale projection, or stale player-session epoch MUST NOT commit an authoritative plugin mutation.

Retries MUST use stable operation identity where duplicate delivery could otherwise duplicate externally visible effects.

### World, chunk, entity, and player mutations

Supported mutating API calls affecting world, chunk, entity, player, inventory, scoreboard, offline-player, or other server-managed state MUST ultimately execute against the current authoritative state.

Examples include, but are not limited to:

- Changing block data or biome state.
- Spawning, removing, teleporting, damaging, or modifying entities.
- Teleporting a player or changing health, food, inventory, experience, effects, abilities, metadata, or game mode.
- Updating Persistent Data Containers.
- Modifying world or chunk state that is persisted by the server.
- Updating offline-player data or other server-managed persistent records.

A remote boundary projection is not an independent mutable copy. A plugin mutation targeting a projected remote player, entity, chunk, or block MUST be routed to the authoritative owner and fenced by the relevant player-session epoch, partition ownership epoch, or equivalent authority token.

After an authoritative mutation commits, Worldline MUST propagate the resulting state to every node that requires it for visibility, reads, handoff, migration, replication, recovery, or plugin compatibility.

Propagation does not mean replaying the same mutating API call independently on every node. The mutation occurs authoritatively once; other nodes receive the resulting committed state or an equivalent authoritative update.

### Persistent Data Containers

Persistent Data Containers are part of the authoritative object state to which they are attached.

Therefore:

- Player PDC state follows player authority and is included in player handoff and persistence.
- Entity PDC state follows authoritative entity state.
- Chunk and world PDC state follows partition and world persistence rules.
- A PDC mutation issued from a non-owner is routed to the owner.
- Replicas and projections remain read-only and MUST reject or route local PDC mutation attempts rather than silently diverging.

A handoff, migration, recovery, snapshot, or replication path MUST NOT silently omit supported plugin-owned PDC state.

### Cluster-wide plugin data namespace

Each plugin's conventional data directory MUST appear as one logical cluster-wide namespace.

For example, when a plugin writes:

~~~text
plugins/ExamplePlugin/config.yml
plugins/ExamplePlugin/players/<uuid>.yml
plugins/ExamplePlugin/data.json
~~~

those paths MUST NOT become unrelated node-local copies that silently diverge.

Worldline MUST provide versioned, durable, conflict-aware semantics for plugin-owned files inside the managed plugin data directory. At minimum:

- A committed write becomes visible cluster-wide.
- Reads after a committed write do not permanently observe an older divergent node-local copy.
- Writes to the same logical path have a defined global order or explicit conflict result.
- Atomic replacement patterns commonly used for configuration and data files are preserved where the underlying API promises them.
- Node failure cannot silently create two independent authoritative histories for one logical path.
- File updates produce invalidation or synchronization signals so other nodes stop serving stale cached content.

The exact implementation is deliberately deferred. It may use a virtualized filesystem boundary, managed volume, content-addressed objects, a journaled storage service, operation interception, or another design that satisfies the contract.

A simple best-effort file watcher that notices changes after arbitrary local writes is not sufficient as the sole correctness mechanism because it cannot by itself guarantee ordering, atomicity, conflict handling, or safe recovery.

Updating a `config.yml` file makes the updated bytes available through the logical plugin data namespace. Worldline does not imply that a plugin which never re-reads its configuration must magically change its in-memory behavior; automatic hot reload is only required when the plugin or supported server API would ordinarily perform that reload.

### File-backed databases and special storage engines

Some plugins place SQLite databases, embedded key-value stores, memory-mapped files, lock files, or other storage engines inside their data directory. Blindly copying an actively written database file between nodes can corrupt it or violate its consistency model.

Worldline MUST NOT claim transparent safety for such files merely because they are under `getDataFolder()`.

For common file-backed engines, Worldline MUST choose one of the following before claiming compatibility:

- Provide a storage-engine-aware adapter.
- Pin that plugin's mutable storage execution to one logical authority and route access through it.
- Provide another mechanism that preserves the engine's transactional and locking semantics.
- Mark the storage mode as unsupported with a specific, testable compatibility reason.

The compatibility matrix MUST distinguish ordinary replicated files from storage engines requiring stronger coordination.

### Plugin execution semantics

Running the same unmodified plugin independently on every Worldline Server is not sufficient. It can multiply externally visible behavior.

Worldline MUST define one logical execution model for plugin lifecycle, commands, events, and scheduled work.

The required semantic rules are:

- A command submitted once is logically handled once unless the plugin itself intentionally fans out work.
- A synchronous event tied to authoritative world, entity, or player state executes in the authoritative mutation path so cancellation and modification can affect the real operation before commit where ordinary Paper semantics require that.
- A remote projection update MUST NOT spuriously recreate canonical server events as though the projected object had independently changed on another Paper server.
- A scheduled task registered once by an unmodified plugin MUST NOT unintentionally execute once per physical node when single-server semantics require one logical execution.
- Plugin lifecycle callbacks and initialization side effects MUST NOT unintentionally multiply merely because plugin code is physically present on several nodes.
- Worldline-specific plugins MAY explicitly request node-local, partition-local, owner-affine, or other distributed execution modes through a future dedicated API.

The exact runtime mechanism is deferred. Possible implementations include logical plugin coordinators, owner-affine execution, distributed scheduler records, execution fencing, bytecode or API interception, or plugin-specific adapters.

Earlier architecture MUST NOT assume that every physical plugin instance is an independent logical plugin installation.

### Reads and object identity

Supported reads SHOULD return the logical cluster state a plugin would expect from one Paper server, subject only to explicitly documented consistency limitations.

A node MUST NOT present a stale projection as authoritative merely because the plugin invoked the read locally. When correctness requires fresh authoritative state, Worldline MUST route the read, use a sufficiently current authoritative cache, or fail explicitly rather than silently returning a contradictory value.

Cluster identities for players, entities, worlds, chunks, plugin files, scheduled tasks, and operations MUST remain stable enough to prevent physical-node transitions from appearing as unrelated logical objects.

Object handles retained across a player handoff or ownership change require fencing or indirection. A stale handle MUST NOT regain authority or commit a mutation under an obsolete epoch.

### External databases and plugin-owned network services

Worldline does not automatically replicate or coordinate data already owned by an external database or service. Such a system may already be cluster-safe, may require single-writer execution, or may have semantics unknown to Worldline.

However, Worldline's execution model still MUST avoid multiplying plugin callbacks, scheduled tasks, or lifecycle behavior in ways that cause duplicate external side effects compared with one conventional Paper server.

Important plugins that use external services MAY receive dedicated compatibility profiles or adapters.

### Compatibility levels

Worldline tracks plugin support using three explicit levels:

1. **Transparent** — the unmodified plugin works correctly under the standard compatibility runtime.
2. **Adapter-assisted** — the plugin remains unmodified, but Worldline applies a built-in compatibility profile or adapter.
3. **Unsupported distributed behavior** — the plugin depends on behavior outside the compatibility boundary or on semantics Worldline cannot safely reproduce.

The existence of these levels does not weaken the 1.0 goal. Worldline SHOULD maximize the Transparent tier and treat significant popular-plugin incompatibilities as product defects or explicit roadmap items rather than silently accepting divergent behavior.

### 1.0 delivery requirement

Full implementation of this ADR may occur late in development. The initial vertical slice and early milestones may omit the compatibility runtime.

However:

- No accepted architecture may intentionally make this contract impossible without a superseding ADR.
- New ownership, storage, handoff, scheduler, or projection designs MUST be reviewed for their effect on transparent plugin compatibility.
- Worldline MUST NOT declare 1.0 without a documented compatibility matrix and automated multi-node conformance testing for the supported contract.

## Consequences

### Benefits

- Existing plugins can target the logical server rather than being rewritten around physical nodes.
- World, player, entity, and PDC mutations preserve the existing authority model instead of introducing a second replication model.
- Plugin configuration and ordinary data files do not silently diverge between servers.
- Player handoffs and partition boundaries remain invisible to well-behaved plugins wherever technically feasible.
- Compatibility becomes a testable product contract instead of a vague aspiration.
- Early architecture is forced to preserve the ability to virtualize plugin storage and execution later.

### Costs and risks

- Transparent compatibility is one of the highest-complexity requirements in the project.
- Synchronous remote API calls may add latency or require owner-affine execution and proxy objects.
- Plugin lifecycle and scheduler semantics are difficult because arbitrary plugin code can create external side effects.
- File-backed databases cannot be handled safely by naive file replication.
- Some plugins depend on unsupported internals or process-local behavior and will require adapters or remain unsupported.
- Maintaining compatibility across Paper revisions requires a versioned test matrix and ongoing work.
- Strong file semantics, execution fencing, and compatibility routing add operational state that must itself be recovered safely.

## Alternatives considered

- **Require all plugins to be rewritten for Worldline:** rejected because it would discard the existing Paper and Spigot ecosystem and make adoption substantially harder.
- **Run every plugin independently on every node and synchronize only Minecraft state:** rejected because scheduled tasks, lifecycle hooks, commands, external side effects, and plugin-owned files can be duplicated or diverge.
- **Replicate every plugin mutation by replaying it on every node:** rejected because it creates multiple writers, duplicated side effects, ordering conflicts, and disagreement with the existing authoritative-owner model.
- **Use only filesystem watchers for plugin data:** rejected as the sole correctness mechanism because post-hoc observation does not guarantee atomicity, ordering, conflict handling, or recovery.
- **Promise literal compatibility with arbitrary JVM behavior:** rejected because Worldline cannot safely virtualize unobservable external databases, arbitrary sockets, native code, unsupported internals, and every operating-system side effect.
- **Defer all compatibility design until implementation near 1.0:** rejected because ownership, storage, scheduling, handoff, and projection choices made earlier could otherwise make transparent compatibility prohibitively expensive or impossible.

## Compliance

An implementation conforms to this ADR only when compatibility behavior is validated against both a multi-node Worldline cluster and, where practical, a conventional single-server Paper reference environment.

The automated compatibility harness MUST cover at least:

- `config.yml` and ordinary plugin data-file writes, reads, replacement, concurrent update, restart, and node-failure behavior.
- Player, inventory, offline-player, world, chunk, block, entity, scoreboard, metadata, and PDC mutations through supported APIs.
- Mutations issued on the authoritative node and through a non-authoritative node or remote projection.
- Player handoff while plugin-owned player state and PDC data are present.
- Event cancellation and modification in authoritative mutation paths.
- Commands, lifecycle callbacks, and scheduled tasks that would expose duplicate physical-node execution.
- Duplicate message delivery, stale epochs, retries, owner failure, and recovery.
- At least one ordinary file-backed plugin state format and explicit tests for storage engines requiring adapters or affinity.

For every tested operation, the harness SHOULD compare externally visible outcomes with the single-server reference and verify:

- No duplicate authoritative mutation.
- No missing committed mutation.
- No stale owner commits after authority transfer.
- No silent divergence of managed plugin files.
- No unintended duplicate command, lifecycle, event, task, or external side effect caused solely by physical node count.
- Correct observer and plugin-visible behavior across a partition boundary and player handoff.

The project MUST maintain a compatibility matrix identifying the Paper version, plugin version, Worldline version, compatibility level, tested features, known limitations, and required adapter where applicable.

## References

- [ADR 0001: Transparent spatial sharding](0001-transparent-spatial-sharding.md)
- [ADR 0002: Messaging, coordination, and durable state](0002-messaging-coordination-and-state.md)
- [ADR 0003: Partition directory, allocation, and membership changes](0003-partition-directory-allocation-and-membership.md)
- [ADR 0004: Owner-local partition storage and boundary visibility](0004-owner-local-storage-and-boundary-visibility.md)
- [ADR 0005: Player handoff state machine and packet continuity](0005-player-handoff-state-machine.md)
- [Paper plugin configuration documentation](https://docs.papermc.io/paper/dev/plugin-configurations/)
- [Paper Persistent Data Container documentation](https://docs.papermc.io/paper/dev/pdc/)