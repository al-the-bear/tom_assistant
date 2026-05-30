// EdgeWriter — the in-process owner of the edge-write path
// (Plan step A.36).
//
// What this file owns:
//
//   - Endpoint existence checks against `memory.db.nodes`. A
//     missing endpoint throws `EdgeEndpointMissing`; this is the
//     first guard because the alphabet / permission check is
//     pointless when the endpoints don't exist.
//   - Endpoint type resolution via `NodeTypeRegistry`. An
//     endpoint whose `type_name` is no longer registered throws
//     `UnknownNodeTypeForEdge` — that's a memory-DB integrity
//     tripwire, surfaced explicitly instead of silently ignored.
//   - Closed-alphabet enforcement. The `EdgeType` enum *is* the
//     alphabet: callers cannot construct an off-alphabet value
//     without going through `EdgeType.fromWireName` (which throws
//     on unknown wires). The writer does not re-check the
//     alphabet; the type system carries that constraint.
//   - Per-endpoint permission checks against the registry's
//     `allowedOutgoing` / `allowedIncoming` sets. A violation
//     throws `EdgeNotPermitted` and emits `EdgeRejected`.
//   - The single SQLite-side `INSERT INTO edges` (the composite
//     indexes from schema-v1 § 4.2 are already in place).
//   - `EdgeCreated` event emission on successful commit;
//     `EdgeRejected` event emission on every refusal path.
//
// What this file does NOT own:
//
//   - The full `SqliteTomBrainMemory` concrete class. Same pattern
//     as `NodePersister` — per-operation owner, composed into the
//     concrete store at a later step.
//   - `edgesOf` queries. Lands at A.37.
//   - Symmetric `NodeRejected` events on `NodePersister` failures.
//     The asymmetry (NodePersister throws-only; EdgeWriter
//     throws-and-emits) is documented in `edge_events.dart` and
//     in **Q-A.36.1**.
//
// What this file owns since A.67:
//
//   - Producer attribution. The abstract `TomBrainMemory.edge`
//     signature now requires a `Scope`; `scope.producer` lands in
//     the `produced_by` column so the trace stitcher can attribute
//     every edge to the agent run that wrote it (closes Q-A.36.2).
//   - `Scope.idempotencyKey` enforcement, mirroring `NodePersister`
//     (spec § 9.1). A second `edge` call under the same key returns
//     the original `EdgeId` without inserting a duplicate row and
//     without emitting an `EdgeCreated` event. The DB-level guard
//     is `uniq_edges_idempotency_key`, the partial-unique index on
//     `edges(idempotency_key)`.
//
// Layering:
//
//   - The writer takes a raw `sqlite3` `Database` handle and a
//     `NodeTypeRegistry`. It does not own either — the higher-level
//     store opener gives them both and shares them across
//     per-operation owners.
//   - The event sink is an optional `void Function(MemoryEvent)`.
//     The concrete `SqliteTomBrainMemory` wires this to the same
//     `StreamController` that backs `TomBrainMemory.events()`.

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show EdgeId, NodeId;

import '../api/memory_event.dart';
import '../api/scope.dart';
import '../nodes/node_type_registry.dart';
import 'edge_events.dart';
import 'edge_type.dart';
import 'edge_write_exception.dart';

/// In-process owner of the edge-write path.
///
/// One `EdgeWriter` per open memory store; constructed by the store
/// opener and handed to the higher-level `SqliteTomBrainMemory` once
/// that class lands.
final class EdgeWriter {
  /// Live SQLite handle on `memory.db`. Owned by the store; the
  /// writer does NOT close it.
  final Database _db;

  /// Live registry of node types. The writer reads it to enforce
  /// `allowedOutgoing` / `allowedIncoming`.
  final NodeTypeRegistry _registry;

  /// Fresh-id factory. Defaults to `EdgeId.generate`; tests
  /// override it to make edge ids deterministic.
  final EdgeId Function() _idMint;

  /// Wall-clock source for `created_at_*` stamps. Defaults to
  /// `DateTime.now`; tests override it for determinism.
  final DateTime Function() _now;

  /// Optional sink for `MemoryEvent`s. The concrete store opener
  /// wires this to the `events()` stream; tests pass a list-backed
  /// sink to inspect emissions.
  final void Function(MemoryEvent)? _eventSink;

  /// Constructs the writer around an already-opened, already-migrated
  /// `memory.db` handle and a registry bound to the same store.
  ///
  /// `idMint` and `now` are only overridden in tests.
  EdgeWriter({
    required Database memoryDb,
    required NodeTypeRegistry registry,
    EdgeId Function()? idMint,
    DateTime Function()? now,
    void Function(MemoryEvent)? eventSink,
  })  : _db = memoryDb,
        _registry = registry,
        _idMint = idMint ?? EdgeId.generate,
        _now = now ?? DateTime.now,
        _eventSink = eventSink;

  // ─── Public surface ──────────────────────────────────────────────

  /// Creates an edge `from --type--> to`, returning the new edge id.
  ///
  /// Contract (spec § 3.1, § 4.2, § 9.1, § 15):
  ///
  ///   * Idempotency. When [scope].idempotencyKey is non-null AND an
  ///     edge already exists under that key, the existing [EdgeId]
  ///     is returned, no row is inserted, and no event is emitted —
  ///     the call is a silent no-op. The existing endpoints / label
  ///     / weight / attrs are *not* compared against the in-flight
  ///     request; the key alone is the deduplication contract
  ///     (mirroring `NodePersister.persist`). A re-running agent
  ///     supplies the same key on retry and gets the same edge.
  ///
  ///   * Endpoints must name live rows in `nodes`. A missing endpoint
  ///     throws [EdgeEndpointMissing] and emits [EdgeRejected]. No
  ///     row is inserted.
  ///
  ///   * Both endpoint types must be currently registered. An
  ///     endpoint whose `type_name` is not in the `NodeTypeRegistry`
  ///     throws [UnknownNodeTypeForEdge] and emits [EdgeRejected].
  ///     This is a tripwire for memory-DB integrity drift.
  ///
  ///   * [type] must be in the from-type's `allowedOutgoing` AND the
  ///     to-type's `allowedIncoming`. A violation throws
  ///     [EdgeNotPermitted] (the exception names which side rejected)
  ///     and emits [EdgeRejected]. The closed 12-edge alphabet is
  ///     carried by the [EdgeType] enum itself — there is no
  ///     additional alphabet check.
  ///
  ///   * On success: a fresh [EdgeId] is minted, a row is inserted
  ///     into `edges` (composite indexes idx_edges_from_type /
  ///     idx_edges_to_type / idx_edges_type_from_to update
  ///     transparently), `scope.producer` is recorded in
  ///     `produced_by`, `scope.idempotencyKey` (when supplied) is
  ///     recorded in `idempotency_key`, and [EdgeCreated] is
  ///     emitted.
  ///
  /// [weight] defaults to `1.0`. [attrs] defaults to an empty map;
  /// the only attribute currently in use is `{'kind': 'depends_on'}`
  /// on `part_of` edges between `PlanStep` nodes (spec § 4.1
  /// `PlanStep`).
  Future<EdgeId> edge(
    NodeId from,
    EdgeType type,
    NodeId to, {
    required Scope scope,
    double weight = 1.0,
    Map<String, Object?>? attrs,
  }) async {
    final effectiveAttrs = attrs ?? const <String, Object?>{};

    // 0. Idempotency hit? Cheapest check first — a single indexed
    //    lookup. On hit we return immediately without touching the
    //    registry or any endpoint validation; the prior write already
    //    satisfied those checks. Mirrors `NodePersister.persist`
    //    (spec § 9.1).
    if (scope.idempotencyKey != null) {
      final existing = _lookupByIdempotencyKey(scope.idempotencyKey!);
      if (existing != null) {
        return existing;
      }
    }

    // 1. Endpoint existence + type lookup. Two SELECTs (one per
    //    endpoint). The from-side is checked first — when both fail,
    //    the from-side rejection takes precedence so callers don't
    //    have to enumerate cascading failures.
    final fromTypeName = _lookupNodeType(from);
    if (fromTypeName == null) {
      _rejectEndpointMissing(
        from: from,
        type: type,
        to: to,
        side: EdgeEndpointSide.from,
      );
    }
    final toTypeName = _lookupNodeType(to);
    if (toTypeName == null) {
      _rejectEndpointMissing(
        from: from,
        type: type,
        to: to,
        side: EdgeEndpointSide.to,
      );
    }

    // 2. Type-decl resolution. An endpoint whose type is no longer
    //    registered means the registry / nodes table have drifted —
    //    surface explicitly.
    // After the rejection helpers above (Never return), the type
    // names are guaranteed non-null.
    final fromDecl = _registry.get(fromTypeName);
    if (fromDecl == null) {
      _rejectUnknownTypeForEdge(
        from: from,
        type: type,
        to: to,
        side: EdgeEndpointSide.from,
        unknownTypeName: fromTypeName,
      );
    }
    final toDecl = _registry.get(toTypeName);
    if (toDecl == null) {
      _rejectUnknownTypeForEdge(
        from: from,
        type: type,
        to: to,
        side: EdgeEndpointSide.to,
        unknownTypeName: toTypeName,
      );
    }

    // 3. Permission checks. `allowedOutgoing` first, then
    //    `allowedIncoming` — the order doesn't matter for
    //    correctness but lets the error message attribute the
    //    refusal to a single side.
    if (!fromDecl.allowedOutgoing.contains(type)) {
      _rejectNotPermitted(
        from: from,
        type: type,
        to: to,
        side: EdgeEndpointSide.from,
        rejectingTypeName: fromTypeName,
        otherTypeName: toTypeName,
      );
    }
    if (!toDecl.allowedIncoming.contains(type)) {
      _rejectNotPermitted(
        from: from,
        type: type,
        to: to,
        side: EdgeEndpointSide.to,
        rejectingTypeName: toTypeName,
        otherTypeName: fromTypeName,
      );
    }

    // 4. Commit. Single INSERT — no transaction needed: a single-row
    //    edge insert is atomic in SQLite. The composite indexes from
    //    schema-v1 § 4.2 keep query plans tight without extra work
    //    here.
    final id = _idMint();
    final at = _now().toUtc();
    final atMs = at.millisecondsSinceEpoch;
    final atIso = at.toIso8601String();

    _db.execute(
      'INSERT INTO edges ('
      'id, from_node, to_node, type, weight, attrs_json, produced_by, '
      'created_at_ms, created_at_iso, idempotency_key'
      ') VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        id.toString(),
        from.toString(),
        to.toString(),
        type.wireName,
        weight,
        effectiveAttrs.isEmpty ? null : jsonEncode(effectiveAttrs),
        // produced_by carries Scope.producer for trace stitching
        // (A.67 closes Q-A.36.2).
        scope.producer,
        atMs,
        atIso,
        scope.idempotencyKey,
      ],
    );

    _eventSink?.call(
      EdgeCreated(
        edgeId: id,
        from: from,
        type: type,
        to: to,
        fromTypeName: fromTypeName,
        toTypeName: toTypeName,
        weight: weight,
        attrs: effectiveAttrs,
        occurredAt: at,
      ),
    );

    return id;
  }

  // ─── Internal: idempotency ───────────────────────────────────────

  /// Looks up an existing edge by `Scope.idempotencyKey`. Returns
  /// the existing [EdgeId] when a row matches, `null` otherwise.
  ///
  /// The lookup goes through `uniq_edges_idempotency_key` — the
  /// partial-unique index defined in schema-v1 — so it is a single
  /// index seek even when the table is large.
  EdgeId? _lookupByIdempotencyKey(String key) {
    final rows = _db.select(
      'SELECT id FROM edges WHERE idempotency_key = ? LIMIT 1',
      <Object?>[key],
    );
    if (rows.isEmpty) return null;
    return EdgeId.fromString(rows.first['id'] as String);
  }

  // ─── Internal: endpoint lookup ───────────────────────────────────

  /// Returns the type_name of the live node at [id], or `null` when
  /// no live row exists. Mirrors `NodeReader.get` without
  /// materialising the full `Node` — we only need the type column.
  String? _lookupNodeType(NodeId id) {
    final rows = _db.select(
      'SELECT type_name FROM nodes WHERE id = ? LIMIT 1',
      <Object?>[id.toString()],
    );
    if (rows.isEmpty) return null;
    return rows.first['type_name'] as String;
  }

  // ─── Internal: rejection helpers (emit + throw) ──────────────────

  Never _rejectEndpointMissing({
    required NodeId from,
    required EdgeType type,
    required NodeId to,
    required EdgeEndpointSide side,
  }) {
    final message = side == EdgeEndpointSide.from
        ? 'from-node ${from.toString()} has no live row in nodes '
            '(it was never persisted, was forgotten, or the id is '
            'mistyped).'
        : 'to-node ${to.toString()} has no live row in nodes '
            '(it was never persisted, was forgotten, or the id is '
            'mistyped).';
    _emitRejected(
      from: from,
      type: type,
      to: to,
      reason: side == EdgeEndpointSide.from
          ? EdgeRejectionReason.fromEndpointMissing
          : EdgeRejectionReason.toEndpointMissing,
      message: message,
    );
    throw EdgeEndpointMissing(
      from: from,
      type: type,
      to: to,
      side: side,
      message: message,
    );
  }

  Never _rejectUnknownTypeForEdge({
    required NodeId from,
    required EdgeType type,
    required NodeId to,
    required EdgeEndpointSide side,
    required String unknownTypeName,
  }) {
    final message = side == EdgeEndpointSide.from
        ? 'from-node ${from.toString()} carries type_name '
            '"$unknownTypeName" which is not in the NodeTypeRegistry. '
            'A type was unregistered while a node of that type still '
            'lived — this is a memory.db integrity tripwire.'
        : 'to-node ${to.toString()} carries type_name '
            '"$unknownTypeName" which is not in the NodeTypeRegistry. '
            'A type was unregistered while a node of that type still '
            'lived — this is a memory.db integrity tripwire.';
    _emitRejected(
      from: from,
      type: type,
      to: to,
      reason: side == EdgeEndpointSide.from
          ? EdgeRejectionReason.fromEndpointTypeUnregistered
          : EdgeRejectionReason.toEndpointTypeUnregistered,
      message: message,
      fromTypeName: side == EdgeEndpointSide.from ? null : unknownTypeName,
      toTypeName: side == EdgeEndpointSide.to ? null : unknownTypeName,
    );
    throw UnknownNodeTypeForEdge(
      from: from,
      type: type,
      to: to,
      side: side,
      unknownTypeName: unknownTypeName,
      message: message,
    );
  }

  Never _rejectNotPermitted({
    required NodeId from,
    required EdgeType type,
    required NodeId to,
    required EdgeEndpointSide side,
    required String rejectingTypeName,
    required String otherTypeName,
  }) {
    final message = side == EdgeEndpointSide.from
        ? 'edge label "${type.wireName}" is not in the '
            'allowedOutgoing set of type "$rejectingTypeName" — '
            'propose a NodeTypeDecl evolution via '
            'propose_node_type_v1 if this edge is genuinely needed, '
            'or pick a permitted label.'
        : 'edge label "${type.wireName}" is not in the '
            'allowedIncoming set of type "$rejectingTypeName" — '
            'propose a NodeTypeDecl evolution via '
            'propose_node_type_v1 if this edge is genuinely needed, '
            'or pick a permitted label.';
    _emitRejected(
      from: from,
      type: type,
      to: to,
      reason: side == EdgeEndpointSide.from
          ? EdgeRejectionReason.notInAllowedOutgoing
          : EdgeRejectionReason.notInAllowedIncoming,
      message: message,
      fromTypeName:
          side == EdgeEndpointSide.from ? rejectingTypeName : otherTypeName,
      toTypeName:
          side == EdgeEndpointSide.to ? rejectingTypeName : otherTypeName,
    );
    throw EdgeNotPermitted(
      from: from,
      type: type,
      to: to,
      side: side,
      rejectingTypeName: rejectingTypeName,
      message: message,
    );
  }

  void _emitRejected({
    required NodeId from,
    required EdgeType type,
    required NodeId to,
    required EdgeRejectionReason reason,
    required String message,
    String? fromTypeName,
    String? toTypeName,
  }) {
    final sink = _eventSink;
    if (sink == null) return;
    sink(
      EdgeRejected(
        from: from,
        type: type,
        to: to,
        reason: reason,
        message: message,
        fromTypeName: fromTypeName,
        toTypeName: toTypeName,
        occurredAt: _now().toUtc(),
      ),
    );
  }
}
