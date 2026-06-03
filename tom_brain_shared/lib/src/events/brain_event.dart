// `BrainEvent` — the universal base for typed observability events emitted
// by every Tom Brain component (Plan step A.14).
//
// The base class is intentionally minimal. It owns only the three fields
// every component must contribute for the brain's cross-component trace
// graph to be reconstructable:
//
//   * [occurredAt] — wall-clock UTC timestamp of the event.
//   * [runId]      — opaque pointer to the procedure run that produced the
//                    event. Nullable because events outside any run
//                    (boot-time integrity, migration progress, MCP-server
//                    lifecycle) are legitimate.
//   * [causedBy]   — opaque pointer to the prior event that caused this
//                    one. Nullable for the same reason.
//
// Two extension points are *abstract* and must be supplied by subclasses:
//
//   * [kind]         — a stable kebab-case discriminator used by transport
//                      layers to route, filter, and (later) deserialise the
//                      event. Convention: `<component>.<event-name>`, e.g.
//                      `memory.node-persisted`, `substrate.completion-failed`.
//   * [payloadJson]  — the subclass-specific data. Whatever's *not* one of
//                      the three base fields. Returned as a fresh map per
//                      call (the base never caches; subclasses should not
//                      either unless they intern the result).
//
// What is deliberately NOT here:
//
//   * `fromJson` — there is no central event registry at the `tom_brain_shared`
//     layer. Each owning module registers its own decoder; the shared layer
//     should not import knowledge of subclasses defined elsewhere. When
//     deserialisation is added (A.46+ trail readback), it will return
//     `Result<BrainEvent, FormatException>` as flagged in the A.13 notes,
//     and the registry lives in the consuming module.
//   * Equality / hashCode — subclasses decide what equality means for them.
//     The base does not impose value semantics because not every subclass
//     wants them (some carry a snapshot that's only meaningful as identity).
//
// Why `String?` for [runId] and [causedBy] instead of typed IDs: the brain
// has *two* distinct procedure-related IDs — a `ProcedureId` (the d4rt
// script's identity, defined in A.10) and a procedure-run identity (an
// instance of one execution, not yet defined; arrives with the engine in
// Phase C). The base class cannot import a type that does not yet exist;
// it would also be wrong to couple every event in every component to one
// specific ID shape. The opaque-string contract is the small interface
// that the engine and dispatcher will satisfy when they assign run ids.

/// Universal base class for typed observability events across Tom Brain
/// components.
///
/// Subclasses live in the component that owns the event semantics (e.g.
/// `MemoryEvent` and its leaves in `tom_brain_memory`). The shared layer
/// only declares the contract that lets the dispatcher, the trail writer,
/// and the Forge inspector treat events uniformly.
///
/// Usage from a subclass:
///
/// ```dart
/// final class NodePersisted extends BrainEvent {
///   final NodeId nodeId;
///   final String nodeType;
///
///   const NodePersisted({
///     required this.nodeId,
///     required this.nodeType,
///     required super.occurredAt,
///     super.runId,
///     super.causedBy,
///   });
///
///   @override
///   String get kind => 'memory.node-persisted';
///
///   @override
///   Map<String, Object?> payloadJson() => {
///         'nodeId': nodeId.toString(),
///         'nodeType': nodeType,
///       };
/// }
/// ```
abstract class BrainEvent {
  /// Wall-clock timestamp at which the event occurred.
  ///
  /// Must be UTC. The base class does not coerce — coercing would silently
  /// hide bugs where a local-time `DateTime` slipped in. Subclasses
  /// constructing from a local clock should call `.toUtc()` at the call
  /// site. [toJson] throws an [ArgumentError] if the invariant is violated
  /// on serialisation — a local-time timestamp must never ride the
  /// observability wire.
  final DateTime occurredAt;

  /// Opaque pointer to the procedure run that produced this event.
  ///
  /// Null when the event was emitted outside any run (e.g. boot-time
  /// integrity checks, migration progress, MCP-server lifecycle).
  final String? runId;

  /// Opaque pointer to the prior event that directly caused this one.
  ///
  /// Used by the trace stitcher to reconstruct the brain's causal graph
  /// across components. Null for root events of a chain.
  final String? causedBy;

  /// Base constructor. Subclasses pass through via `super`.
  const BrainEvent({
    required this.occurredAt,
    this.runId,
    this.causedBy,
  });

  /// Stable kebab-case discriminator for this event subtype.
  ///
  /// Convention: `<component>.<event-name>` — for example
  /// `memory.node-persisted`, `substrate.completion-failed`,
  /// `dispatcher.run-preempted`. Used by transport / filter / decoder
  /// layers; must NOT change between releases without a migration.
  String get kind;

  /// Subclass-specific payload as a JSON-encodable map.
  ///
  /// Implementations must not include the base fields ([occurredAt],
  /// [runId], [causedBy]); [toJson] composes those itself. Implementations
  /// must return a fresh map (callers may mutate). Values must be limited
  /// to JSON-encodable types: `String`, `num`, `bool`, `null`,
  /// `List<Object?>`, `Map<String, Object?>`.
  Map<String, Object?> payloadJson();

  /// Full JSON representation: kind + base fields + subclass payload.
  ///
  /// Shape:
  ///
  /// ```json
  /// {
  ///   "kind": "memory.node-persisted",
  ///   "occurredAt": "2026-05-30T14:22:33.123Z",
  ///   "runId": "r_01J...",        // omitted when null
  ///   "causedBy": "ev_01J...",    // omitted when null
  ///   "payload": { ... subclass fields ... }
  /// }
  /// ```
  ///
  /// The null-omission rule keeps the on-wire shape compact and avoids
  /// teaching downstream parsers to distinguish "missing" from "explicitly
  /// null". Parsers re-introduce nulls structurally when they hit absent
  /// keys.
  Map<String, Object?> toJson() {
    if (!occurredAt.isUtc) {
      throw ArgumentError.value(
        occurredAt,
        'occurredAt',
        'BrainEvent.occurredAt must be UTC; a local-time timestamp on the '
            'observability wire corrupts cross-component trace ordering',
      );
    }
    return <String, Object?>{
      'kind': kind,
      'occurredAt': occurredAt.toIso8601String(),
      if (runId != null) 'runId': runId,
      if (causedBy != null) 'causedBy': causedBy,
      'payload': payloadJson(),
    };
  }
}
