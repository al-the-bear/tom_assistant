// NodePersister — the in-process owner of the node-write path
// (Plan step A.34).
//
// What this file owns:
//
//   - Idempotency lookup against `nodes.idempotency_key` (the
//     spec § 9.1 contract: a second write with the same key returns
//     the original `NodeId` and emits nothing).
//   - Validation of a `NodeDraft` against the registered
//     `NodeTypeDecl` from `NodeTypeRegistry`: unknown field guard,
//     missing-required-field guard, per-field type check, enum
//     range, nodeRef syntax.
//   - Validation of `NodeDraft.embedding` against
//     `NodeTypeDecl.embeddingPolicy`: missing / unexpected / dim
//     mismatch.
//   - The single SQLite-side `INSERT INTO nodes` paired with the
//     vector write through `TwoDbCoordinator.persistNodeWithVector`
//     so the two databases stay consistent.
//   - `NodePersisted` event emission on successful commit (NOT on
//     idempotency hit — the event stream is the audit log of *new*
//     nodes).
//
// What this file owns since A.68:
//
//   - `WriteBudget.maxNodes` enforcement via the optional
//     `WriteBudgetTracker` (spec § 9.3, § 9.5). The check runs
//     **after** the idempotency lookup and **before** any validation
//     work — an idempotent re-persist does not charge the budget
//     (no new node materialises), and a rejected draft does not
//     charge either (the throw fires before `chargeNode` is
//     reached). A successful new-row commit charges exactly one
//     unit. When no tracker is wired, or `scope.runId` is null, or
//     the run was never `beginRun`-registered, persist passes
//     through unchecked — see `WriteBudgetTracker` header for the
//     opt-in rationale.
//
// What this file does NOT own (yet):
//
//   - The full `SqliteTomBrainMemory` concrete class. The plan
//     introduces the concrete implementation behind the abstract
//     `TomBrainMemory` surface by *composing* per-operation owners
//     (this file for `persist`, future files for `get`, `edge`,
//     `recall`, …). Each Phase-A step adds one or two owners; the
//     concrete `SqliteTomBrainMemory` stitches them together at the
//     last per-method step.
//
//   - The canonical `NodeType` node row in `memory.db.nodes`.
//     `NodeTypeRegistry.registerNodeType` (A.33) stamps a freshly-
//     minted `decl_node_id` into `node_types.decl_node_id` without
//     writing the matching row in `nodes` — that pairing is tracked
//     as **Q-A.33.1** and **Q-A.34.1** for the cross-cutting
//     concern. A.34 is the persist *runtime*; the registry-rewrite
//     to dual-write the canonical node row lands as its own step
//     (planned alongside the `propose_node_type_v1` procedure wire
//     so the dispatcher is the single caller making both writes
//     atomic).
//
//   - Edge writes (`TomBrainMemory.edge`) — land at A.41+.
//
//   - Re-embedding migrations. `NodeDraft.embedding` is taken at
//     face value; A.34 does not call out to a substrate to embed.
//     The substrate-driven embedding pipeline lands at A.50+.
//
// Layering:
//
//   - The persister takes a raw `sqlite3` `Database` handle, a
//     `TwoDbCoordinator` (already bound to that handle and a
//     `VectorApplier`), and a `NodeTypeRegistry`. It does not own
//     any of these — the higher-level store opener (A.27+) gives
//     them and shares them across the per-operation owners.
//   - The event sink is an optional `void Function(MemoryEvent)`.
//     The concrete `SqliteTomBrainMemory` will wire this to the
//     same `StreamController` that backs `TomBrainMemory.events()`.

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show NodeId, Vec;

import '../api/memory_event.dart';
import '../api/scope.dart';
import '../budget/write_budget_tracker.dart';
import '../retrieval/fts5_writer.dart';
import '../store/two_db_coordinator.dart';
import 'node.dart';
import 'node_events.dart';
import 'node_persist_exception.dart';
import 'node_type_decl.dart';
import 'node_type_registry.dart';

/// In-process owner of the node-write path.
///
/// One `NodePersister` per open memory store; constructed by the
/// store opener and handed to the higher-level `SqliteTomBrainMemory`
/// once that class lands (later in Phase A).
final class NodePersister {
  /// Live SQLite handle on `memory.db`. Owned by the store; the
  /// persister does NOT close it.
  final Database _db;

  /// Two-DB write coordinator. Owned by the store; the persister
  /// uses it to atomically write the node row + vector.
  final TwoDbCoordinator _coordinator;

  /// Live registry of node types. The persister reads it to validate
  /// each draft.
  final NodeTypeRegistry _registry;

  /// Fresh-id factory. Defaults to `NodeId.generate`; tests override
  /// it to make node ids deterministic.
  final NodeId Function() _idMint;

  /// Wall-clock source for `created_at_*` / `updated_at_*` stamps.
  /// Defaults to `DateTime.now`; tests override it for determinism.
  final DateTime Function() _now;

  /// Optional sink for `MemoryEvent`s. The concrete store opener
  /// wires this to the `events()` stream; tests pass a list-backed
  /// sink to inspect emissions.
  final void Function(MemoryEvent)? _eventSink;

  /// Optional FTS5 writer. When non-null, every successful
  /// `INSERT INTO nodes` is paired with an `INSERT INTO fts_<Type>`
  /// inside the same `writeNode` transaction. When null, FTS5 rows
  /// are not maintained (the historic A.34 behaviour, kept for tests
  /// that pre-date A.54).
  final Fts5Writer? _ftsWriter;

  /// Optional `WriteBudget` enforcement (A.68; spec § 9.3). When
  /// non-null, every successful new-row commit consumes one unit of
  /// the registered run's `maxNodes`. When null, persist does not
  /// enforce a budget — see `WriteBudgetTracker` header for the
  /// opt-in rationale.
  final WriteBudgetTracker? _budgetTracker;

  /// Constructs the persister around an already-opened, already-
  /// migrated `memory.db` handle and a coordinator/registry bound to
  /// the same store.
  ///
  /// `idMint` and `now` are only overridden in tests.
  NodePersister({
    required Database memoryDb,
    required TwoDbCoordinator coordinator,
    required NodeTypeRegistry registry,
    NodeId Function()? idMint,
    DateTime Function()? now,
    void Function(MemoryEvent)? eventSink,
    Fts5Writer? ftsWriter,
    WriteBudgetTracker? budgetTracker,
  })  : _db = memoryDb,
        _coordinator = coordinator,
        _registry = registry,
        _idMint = idMint ?? NodeId.generate,
        _now = now ?? DateTime.now,
        _eventSink = eventSink,
        _ftsWriter = ftsWriter,
        _budgetTracker = budgetTracker;

  // ─── Public surface ────────────────────────────────────────────

  /// Persists [draft] under [scope] and returns the stable node id.
  ///
  /// Contract (spec § 3.1, § 4.1, § 9.1):
  ///
  ///   * If `scope.idempotencyKey` is non-null AND a node already
  ///     exists with that key, returns the existing `NodeId` — no
  ///     INSERT, no vector write, no event. The original draft's
  ///     values are *not* compared against the in-flight draft; the
  ///     key alone is the deduplication contract.
  ///
  ///   * Otherwise validates the draft against the registered type,
  ///     mints a fresh `NodeId`, INSERTs the row into `nodes`,
  ///     writes the vector to `vectors.db` (when one was supplied,
  ///     via the two-DB coordinator's WAL protocol), emits
  ///     `NodePersisted` on the event sink, and returns the new id.
  ///
  /// Throws a [NodePersistException] subclass on any validation
  /// failure; see `node_persist_exception.dart` for the
  /// classification table. The SQL transaction is rolled back on
  /// failure (the two-DB coordinator handles this); no event is
  /// emitted on a rejected draft.
  Future<NodeId> persist(NodeDraft draft, {required Scope scope}) async {
    // 1. Idempotency hit? Cheapest check first — a single primary-
    //    keyed lookup. On hit we return immediately without touching
    //    the registry or the type validators.
    if (scope.idempotencyKey != null) {
      final existing = _lookupByIdempotencyKey(scope.idempotencyKey!);
      if (existing != null) {
        return existing;
      }
    }

    // 2. Resolve the type. Unknown types are a hard refusal — the
    //    bootstrap loader (A.32) and any future `propose_node_type_v1`
    //    procedure must register the type before consumers persist
    //    nodes of that type.
    final decl = _registry.get(draft.typeName);
    if (decl == null) {
      throw UnknownNodeType(
        typeName: draft.typeName,
        message:
            'no NodeTypeDecl is registered for "${draft.typeName}". '
            'Register the type (via propose_node_type_v1 or bootstrap) '
            'before persisting nodes of this type.',
      );
    }

    // 3. Structural validation against the schema.
    _validateValuesAgainstSchema(decl, draft);

    // 4. Embedding-policy validation. Memory does not call out to a
    //    substrate to embed; the caller produced the embedding (or
    //    chose not to).
    _validateEmbeddingAgainstPolicy(decl, draft);

    // 4b. WriteBudget enforcement (A.68; spec § 9.3). After the
    //     idempotency short-circuit and after every validation
    //     guard — a rejected draft does NOT consume budget, and an
    //     idempotent no-op does NOT consume budget either. Before
    //     the commit so a budget rejection leaves no row behind.
    //     Pass-through when no tracker is wired or the run is
    //     unregistered (see WriteBudgetTracker header).
    _budgetTracker?.chargeNode(
      runId: scope.runId,
      producer: scope.producer,
    );

    // 5. Commit. Single transaction across memory.db + (optionally)
    //    vectors.db via the coordinator's WAL protocol.
    final id = _idMint();
    final at = _now().toUtc();
    final atMs = at.millisecondsSinceEpoch;
    final atIso = at.toIso8601String();

    final vectorPayload = _buildVectorPayload(decl, draft);

    _coordinator.persistNodeWithVector(
      nodeId: id.toString(),
      writeNode: (db) {
        db.execute(
          'INSERT INTO nodes ('
          'id, type_name, scope_json, produced_by, attrs_json, status, '
          'created_at_ms, created_at_iso, updated_at_ms, updated_at_iso, '
          'idempotency_key, embedding_model_id) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          <Object?>[
            id.toString(),
            draft.typeName,
            jsonEncode(_scopeToJson(scope)),
            scope.producer,
            jsonEncode(_valuesToJson(draft.values)),
            NodeStatus.active.name,
            atMs,
            atIso,
            atMs,
            atIso,
            scope.idempotencyKey,
            vectorPayload?.embeddingModelId,
          ],
        );
        // FTS5 row insert. Wired only when the opener provided an
        // `Fts5Writer` (A.54+). The writer is a no-op when the type
        // has no FTS-indexed fields, so types without text columns
        // pass through cleanly. Inside the coordinator's transaction
        // so a failure here rolls back the node row too.
        _ftsWriter?.insertRow(
          db: db,
          decl: decl,
          nodeId: id.toString(),
          values: draft.values,
        );
      },
      vector: vectorPayload,
    );

    // 6. Event emission. Idempotent re-calls deliberately emit
    //    nothing — see header comment on NodePersisted.
    _eventSink?.call(
      NodePersisted(
        nodeId: id,
        typeName: draft.typeName,
        producer: scope.producer,
        idempotencyKey: scope.idempotencyKey,
        embeddingModelId: vectorPayload?.embeddingModelId,
        embeddingDimensions: vectorPayload?.payloadDims,
        occurredAt: at,
        runId: scope.runId,
        causedBy: scope.causedBy,
      ),
    );

    return id;
  }

  // ─── Internal: idempotency ─────────────────────────────────────

  NodeId? _lookupByIdempotencyKey(String key) {
    final rows = _db.select(
      'SELECT id FROM nodes WHERE idempotency_key = ? LIMIT 1',
      <Object?>[key],
    );
    if (rows.isEmpty) return null;
    return NodeId.fromString(rows.first['id'] as String);
  }

  // ─── Internal: schema validation ───────────────────────────────

  void _validateValuesAgainstSchema(NodeTypeDecl decl, NodeDraft draft) {
    // Reject unknown fields first — silent acceptance would let typos
    // become persistent garbage.
    for (final key in draft.values.keys) {
      if (!decl.schema.containsKey(key)) {
        throw InvalidNodeDraft(
          typeName: draft.typeName,
          fieldName: key,
          reason: InvalidNodeDraftReason.unknownField,
          message:
              'field "$key" is not declared on type '
              '"${draft.typeName}" (registered fields: '
              '${decl.schema.keys.toList()..sort()}).',
        );
      }
    }

    // Required-field guard and per-field type / range checks.
    for (final entry in decl.schema.entries) {
      final fieldName = entry.key;
      final spec = entry.value;
      final present = draft.values.containsKey(fieldName);
      final value = draft.values[fieldName];

      if (!present || value == null) {
        if (!spec.nullable) {
          throw InvalidNodeDraft(
            typeName: draft.typeName,
            fieldName: fieldName,
            reason: InvalidNodeDraftReason.missingRequiredField,
            message:
                'required field "$fieldName" '
                '(${spec.type.name}) is missing from the draft.',
          );
        }
        continue;
      }

      _validateFieldValue(draft.typeName, fieldName, spec, value);
    }
  }

  void _validateFieldValue(
    String typeName,
    String fieldName,
    FieldSpec spec,
    Object value,
  ) {
    switch (spec.type) {
      case FieldType.string:
        if (value is! String) {
          throw _fieldTypeMismatch(typeName, fieldName, spec, value);
        }
      case FieldType.integer:
        if (value is! int) {
          throw _fieldTypeMismatch(typeName, fieldName, spec, value);
        }
      case FieldType.boolean:
        if (value is! bool) {
          throw _fieldTypeMismatch(typeName, fieldName, spec, value);
        }
      case FieldType.enumeration:
        if (value is! String) {
          throw _fieldTypeMismatch(typeName, fieldName, spec, value);
        }
        if (spec.enumValues.isNotEmpty &&
            !spec.enumValues.contains(value)) {
          throw InvalidNodeDraft(
            typeName: typeName,
            fieldName: fieldName,
            reason: InvalidNodeDraftReason.enumValueOutOfRange,
            message:
                'enumeration field "$fieldName" got value "$value" '
                'which is not in the allowed set ${spec.enumValues}.',
          );
        }
      case FieldType.nodeRef:
        if (value is! String) {
          throw _fieldTypeMismatch(typeName, fieldName, spec, value);
        }
        try {
          NodeId.fromString(value);
        } on FormatException catch (e) {
          throw InvalidNodeDraft(
            typeName: typeName,
            fieldName: fieldName,
            reason: InvalidNodeDraftReason.invalidNodeRef,
            message:
                'nodeRef field "$fieldName" value "$value" is not a '
                'valid NodeId: ${e.message}',
          );
        }
      case FieldType.json:
        // `json` accepts any non-null value the Dart `jsonEncode`
        // pipeline can serialise. We don't pre-validate the shape —
        // doing so would require schemas-within-schemas, and the
        // primary failure (a Map with non-string keys, a non-encodable
        // object) will surface at the `jsonEncode` call below.
        break;
      case FieldType.vec:
        // vec fields in attrs_json are an unusual case — they exist
        // for future use (per-field secondary vectors), and the
        // bootstrap manifest does not use them. Accept `Vec` and
        // serialise as a JSON list of doubles; refuse other shapes.
        if (value is! Vec) {
          throw _fieldTypeMismatch(typeName, fieldName, spec, value);
        }
    }
  }

  InvalidNodeDraft _fieldTypeMismatch(
    String typeName,
    String fieldName,
    FieldSpec spec,
    Object value,
  ) {
    return InvalidNodeDraft(
      typeName: typeName,
      fieldName: fieldName,
      reason: InvalidNodeDraftReason.fieldTypeMismatch,
      message:
          'field "$fieldName" declared as ${spec.type.name} but value '
          'is ${value.runtimeType}.',
    );
  }

  // ─── Internal: embedding validation + payload assembly ─────────

  void _validateEmbeddingAgainstPolicy(NodeTypeDecl decl, NodeDraft draft) {
    final policy = decl.embeddingPolicy;
    if (policy.isNone) {
      if (draft.embedding != null) {
        throw EmbeddingPolicyViolation(
          typeName: draft.typeName,
          reason: EmbeddingPolicyViolationReason.unexpectedEmbedding,
          message:
              'type "${draft.typeName}" declares EmbeddingPolicy.none '
              'but draft.embedding was supplied (dim '
              '${draft.embedding!.dimension}).',
        );
      }
      return;
    }
    // Policy declares an embedding.
    if (draft.embedding == null) {
      throw EmbeddingPolicyViolation(
        typeName: draft.typeName,
        reason: EmbeddingPolicyViolationReason.missingEmbedding,
        message:
            'type "${draft.typeName}" declares an embedding policy '
            '(${policy.modelIdentity}, dim ${policy.dimensions}) but '
            'draft.embedding is null. Memory does not embed lazily — '
            'the caller must produce the embedding via the substrate '
            'before persisting.',
      );
    }
    if (draft.embedding!.dimension != policy.dimensions) {
      throw EmbeddingPolicyViolation(
        typeName: draft.typeName,
        reason: EmbeddingPolicyViolationReason.dimensionMismatch,
        expectedDimensions: policy.dimensions,
        actualDimensions: draft.embedding!.dimension,
        message:
            'embedding dimension mismatch for type "${draft.typeName}": '
            'policy declares ${policy.dimensions}, draft supplied '
            '${draft.embedding!.dimension}.',
      );
    }
  }

  PendingVectorWritePayload? _buildVectorPayload(
    NodeTypeDecl decl,
    NodeDraft draft,
  ) {
    if (decl.embeddingPolicy.isNone || draft.embedding == null) {
      return null;
    }
    return PendingVectorWritePayload(
      embeddingModelId: decl.embeddingPolicy.modelIdentity,
      payloadBlob: draft.embedding!.toBlob(),
      payloadDims: draft.embedding!.dimension,
    );
  }

  // ─── Internal: JSON marshalling ────────────────────────────────

  static Map<String, Object?> _scopeToJson(Scope scope) => <String, Object?>{
        'producer': scope.producer,
        if (scope.idempotencyKey != null)
          'idempotency_key': scope.idempotencyKey,
        if (scope.causedBy != null) 'caused_by': scope.causedBy,
        if (scope.runId != null) 'run_id': scope.runId,
      };

  static Map<String, Object?> _valuesToJson(Map<String, Object?> values) {
    final out = <String, Object?>{};
    for (final entry in values.entries) {
      final value = entry.value;
      if (value is Vec) {
        // vec field → JSON list of doubles. Symmetric encoding to the
        // future read side which will reconstruct Vec.fromList.
        out[entry.key] = value.values.toList();
      } else {
        out[entry.key] = value;
      }
    }
    return out;
  }
}
