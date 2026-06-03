// NodeTypeRegistry — the in-process owner of `node_types`
// registrations (Plan step A.33).
//
// What this file owns:
//
//   - Validation of a candidate `NodeTypeDecl` (PascalCase name,
//     version monotonicity, schema/embedding/index consistency).
//   - Cross-type consistency vs the currently-cached registry (fresh
//     name collisions; `supersedes` reference correctness).
//   - The caller-supplied `CritiqueHook` round-trip — the seam that
//     keeps memory LLM-free.
//   - A single SQLite transaction against `memory.db.node_types` that
//     commits the new row when validation + critique succeed.
//   - In-memory cache invalidation + `NodeTypeRegistered` event
//     emission.
//
// What this file does NOT own (yet):
//
//   - The canonical `NodeType` node row in `memory.db.nodes`. Spec
//     § 4.1 says a node-type *is* a node; persisting the canonical
//     node row is the job of `persist()` which lands at A.34. At A.33
//     the registry stamps a freshly-minted `NodeId` into
//     `node_types.decl_node_id` and writes only the cache row. A.34
//     (or a dedicated wiring step before MCP exposure) will pair the
//     two writes inside the same transaction. The mismatch is
//     deliberate and tracked in `prototype_implementation_questions.md`
//     as Q-A.33.1.
//
//   - The `restructure_tree` push to `restructure_backlog` for type
//     evolutions (spec § 4.1 "Adding a new node type", step 4). The
//     `StackApi` lands at A.40+; once it is wired, the dispatcher's
//     `propose_node_type_v1` is responsible for that push, not the
//     registry. Keeping that out of A.33 prevents A.33 from depending
//     on the stack subsystem.
//
//   - Embedding-policy *enforcement* against the substrate at write
//     time. The registry checks shape (dimensions > 0, every
//     `source_field` exists, modelIdentity non-empty); it does not
//     verify that the embedding model is actually loadable. That
//     check belongs to the substrate boot path and the
//     embedding-model marker probe (`A.29`).
//
// Layering:
//
//   - The registry takes a raw `sqlite3` `Database` handle. It does
//     not own its lifecycle — the higher-level store opener (A.27+)
//     gives it a handle that is already open with WAL + the schema
//     migrated to v1.
//   - The registry holds an in-memory map `name → decl` so the hot
//     path (edge permission checks, persist validation) never has to
//     decode JSON. The cache is loaded lazily by `_warmFromDb` and
//     stays consistent because the registry is the *only* writer to
//     the `node_types` table.
//   - The event sink is an optional `void Function(MemoryEvent)`. The
//     concrete `SqliteTomBrainMemory` (A.34+) will wire this to the
//     same `StreamController` that backs `TomBrainMemory.events()`.

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show BrainVersion, NodeId;

import '../api/memory_event.dart';
import '../edges/edge_type.dart';
import '../retrieval/fts5_catalog.dart';
import '../store/transaction_support.dart';
import 'critique_hook.dart';
import 'node_type_decl.dart';
import 'node_type_events.dart';
import 'node_type_registration.dart';

/// In-process owner of the `node_types` registry table and the live
/// `name → NodeTypeDecl` cache.
///
/// One `NodeTypeRegistry` per open memory store; constructed by the
/// store opener (A.27+) and handed to the higher-level
/// `SqliteTomBrainMemory` (A.34+).
final class NodeTypeRegistry {
  /// PascalCase identifier regex. Anchored. The same regex is also
  /// used by the bootstrap-manifest loader at A.32 (indirectly, since
  /// the loader just round-trips the name into a `NodeTypeDecl`; the
  /// registry is the actual gate).
  static final RegExp _kPascalCaseName = RegExp(r'^[A-Z][A-Za-z0-9]*$');

  /// Live SQLite handle on `memory.db`. The registry does NOT close
  /// it.
  final Database _db;

  /// Caller-supplied judgement function. See `critique_hook.dart` for
  /// the contract.
  final CritiqueHook _critiqueHook;

  /// Fresh-id factory. Defaults to `NodeId.generate`; tests override
  /// it to make decl-node ids deterministic.
  final NodeId Function() _idMint;

  /// Wall-clock source for `registered_at_*`. Defaults to
  /// `DateTime.now`; tests override it for determinism.
  final DateTime Function() _now;

  /// Optional sink for `MemoryEvent`s. The concrete store opener
  /// wires this to the `events()` stream; tests pass a list-backed
  /// sink to inspect emissions.
  final void Function(MemoryEvent)? _eventSink;

  /// Optional FTS5 catalog. When non-null, the registry provisions
  /// per-type FTS5 virtual tables on warm-up and on every fresh
  /// `registerNodeType`. When null, the registry leaves FTS5 tables
  /// to a separate provisioning path (the historic A.33 behaviour).
  ///
  /// `Fts5Catalog.ensureTable` is idempotent, so multiple warm-ups
  /// of the registry are safe.
  final Fts5Catalog? _ftsCatalog;

  /// In-memory cache: type name → live tip of the registered decl.
  /// Populated lazily by `_warmFromDb`.
  final Map<String, NodeTypeDecl> _cache = <String, NodeTypeDecl>{};

  /// Per-type decl-node id of the cached tip. Required for
  /// `supersedes` cross-checks without an extra DB hit.
  final Map<String, NodeId> _cacheDeclNodeIds = <String, NodeId>{};

  bool _warmed = false;

  /// Constructs the registry around an already-opened, already-migrated
  /// `memory.db` handle.
  ///
  /// `critiqueHook` is the seam that keeps memory LLM-free. `idMint`
  /// and `now` are only overridden in tests.
  NodeTypeRegistry({
    required Database memoryDb,
    required CritiqueHook critiqueHook,
    NodeId Function()? idMint,
    DateTime Function()? now,
    void Function(MemoryEvent)? eventSink,
    Fts5Catalog? ftsCatalog,
  })  : _db = memoryDb,
        _critiqueHook = critiqueHook,
        _idMint = idMint ?? NodeId.generate,
        _now = now ?? DateTime.now,
        _eventSink = eventSink,
        _ftsCatalog = ftsCatalog;

  // ─── Public surface ────────────────────────────────────────────

  /// Registers [decl] and returns the assigned decl-node id.
  ///
  /// Throws one of the `NodeTypeRegistrationException` subclasses on
  /// any refusal; see `node_type_registration.dart` for the
  /// classification table. On success, the in-memory cache is
  /// updated atomically with the SQL write and (if a sink was
  /// configured) a `NodeTypeRegistered` event is emitted.
  Future<NodeId> registerNodeType(NodeTypeDecl decl) async {
    _ensureWarmed();

    // 1. Structural validation. Pure; no I/O. The critique hook is
    //    not consulted for malformed decls.
    _validateStructure(decl);

    // 2. Cross-type consistency vs the warm cache.
    _validateAgainstRegistry(decl);

    // 3. Critique-hook round trip. Crashes are normalised into
    //    `NodeTypeRejected` — see hook contract.
    final CritiqueOutcome outcome;
    try {
      outcome = await _critiqueHook(decl, listAll());
    } catch (e, st) {
      throw NodeTypeRejected(
        typeName: decl.typeName,
        message: 'critique hook crashed before returning an outcome.',
        reason: 'critique hook crashed: $e\n$st',
      );
    }
    final String? approvalNote;
    switch (outcome) {
      case CritiqueRefused(:final reason, :final conflictingTypeNames):
        throw NodeTypeRejected(
          typeName: decl.typeName,
          message: 'critique hook rejected the proposal: $reason',
          reason: reason,
          conflictingTypeNames: List<String>.unmodifiable(conflictingTypeNames),
        );
      case CritiqueApproved(:final note):
        approvalNote = note;
    }

    // 4. Commit. Single transaction over `memory.db`.
    final declNodeId = _idMint();
    final at = _now().toUtc();
    _writeCacheRow(decl, declNodeId, at);

    // 4a. Provision the FTS5 virtual table for this type, when the
    //     opener wired a catalog. Idempotent via
    //     `CREATE VIRTUAL TABLE IF NOT EXISTS`. Done outside the
    //     cache-row transaction because DDL on a virtual table is
    //     not transactional in SQLite's strict sense (the table
    //     either exists or it does not — there is no in-flight
    //     intermediate state).
    _ftsCatalog?.ensureTable(decl, _db);

    // 5. In-memory cache update + event emission.
    _cache[decl.typeName] = decl;
    _cacheDeclNodeIds[decl.typeName] = declNodeId;

    final sink = _eventSink;
    if (sink != null) {
      sink(
        NodeTypeRegistered(
          typeName: decl.typeName,
          declNodeId: declNodeId,
          version: decl.version.value,
          supersedes: decl.supersedes,
          critiqueNote: approvalNote,
          occurredAt: at,
        ),
      );
    }

    return declNodeId;
  }

  /// Live tip of every registered type.
  ///
  /// Returns a fresh list — callers may mutate without affecting the
  /// cache. Order is the cache iteration order (insertion order,
  /// stable for tests).
  List<NodeTypeDecl> listAll() {
    _ensureWarmed();
    return List<NodeTypeDecl>.unmodifiable(_cache.values);
  }

  /// Live tip for a single type name, or `null` when no row exists.
  NodeTypeDecl? get(String typeName) {
    _ensureWarmed();
    return _cache[typeName];
  }

  /// Decl-node id of the live tip for [typeName], or `null` when no
  /// row exists. Exposed for callers that need to construct a
  /// `supersedes` reference without going through the full decl.
  NodeId? declNodeIdOf(String typeName) {
    _ensureWarmed();
    return _cacheDeclNodeIds[typeName];
  }

  // ─── Internal: validation ──────────────────────────────────────

  void _validateStructure(NodeTypeDecl decl) {
    // typeName: required, PascalCase.
    if (decl.typeName.isEmpty) {
      throw InvalidNodeTypeDecl(
        typeName: decl.typeName,
        fieldPath: 'typeName',
        message: 'typeName must be a non-empty PascalCase identifier.',
      );
    }
    if (!_kPascalCaseName.hasMatch(decl.typeName)) {
      throw InvalidNodeTypeDecl(
        typeName: decl.typeName,
        fieldPath: 'typeName',
        message:
            'typeName "${decl.typeName}" is not PascalCase '
            '(must match ^[A-Z][A-Za-z0-9]*\$).',
      );
    }

    // version: positive int.
    final versionInt = decl.version.value;
    if (versionInt < 1) {
      throw InvalidNodeTypeDecl(
        typeName: decl.typeName,
        fieldPath: 'version',
        message:
            'version must be >= 1 (got $versionInt). '
            'Spec § 4.1: every NodeTypeDecl starts at v1.',
      );
    }

    // schema: non-empty.
    if (decl.schema.isEmpty) {
      throw InvalidNodeTypeDecl(
        typeName: decl.typeName,
        fieldPath: 'schema',
        message:
            'schema must declare at least one field — '
            'a node-type with no fields cannot carry data.',
      );
    }

    // schema fields: name on FieldSpec must match map key (tripwire
    // against drift between the YAML loader and a hand-built decl).
    for (final entry in decl.schema.entries) {
      if (entry.value.name != entry.key) {
        throw InvalidNodeTypeDecl(
          typeName: decl.typeName,
          fieldPath: 'schema.${entry.key}.name',
          message:
              'FieldSpec.name "${entry.value.name}" does not match '
              'schema map key "${entry.key}".',
        );
      }
    }

    // validatorScriptId: non-empty when present.
    if (decl.validatorScriptId != null && decl.validatorScriptId!.isEmpty) {
      throw InvalidNodeTypeDecl(
        typeName: decl.typeName,
        fieldPath: 'validatorScriptId',
        message:
            'validatorScriptId must be null or a non-empty string '
            '(an empty string here is almost certainly a missing-id bug).',
      );
    }

    _validateEmbeddingPolicy(decl);
    _validateIndexPolicy(decl);
  }

  void _validateEmbeddingPolicy(NodeTypeDecl decl) {
    final policy = decl.embeddingPolicy;
    if (policy.isNone) {
      // EmbeddingPolicy.none is a valid sentinel. Nothing more to
      // check.
      return;
    }
    if (policy.modelIdentity.isEmpty) {
      throw InvalidNodeTypeDecl(
        typeName: decl.typeName,
        fieldPath: 'embeddingPolicy.modelIdentity',
        message:
            'embeddingPolicy.modelIdentity must be non-empty when the '
            'type carries an embedding (use EmbeddingPolicy.none to '
            'declare no embedding).',
      );
    }
    if (policy.dimensions <= 0) {
      throw InvalidNodeTypeDecl(
        typeName: decl.typeName,
        fieldPath: 'embeddingPolicy.dimensions',
        message:
            'embeddingPolicy.dimensions must be > 0 (got '
            '${policy.dimensions}).',
      );
    }
    if (policy.sourceFields.isEmpty) {
      throw InvalidNodeTypeDecl(
        typeName: decl.typeName,
        fieldPath: 'embeddingPolicy.sourceFields',
        message:
            'embeddingPolicy.sourceFields must name at least one '
            'field whose text feeds the embedding.',
      );
    }
    for (final field in policy.sourceFields) {
      final spec = decl.schema[field];
      if (spec == null) {
        throw InvalidNodeTypeDecl(
          typeName: decl.typeName,
          fieldPath: 'embeddingPolicy.sourceFields',
          message:
              'embeddingPolicy.sourceFields names "$field", which is not '
              'in the schema.',
        );
      }
      if (spec.type != FieldType.string) {
        throw InvalidNodeTypeDecl(
          typeName: decl.typeName,
          fieldPath: 'embeddingPolicy.sourceFields',
          message:
              'embeddingPolicy.sourceFields entry "$field" must be a '
              'string field (got ${spec.type.name}).',
        );
      }
    }
  }

  void _validateIndexPolicy(NodeTypeDecl decl) {
    final policy = decl.indexPolicy;
    for (final field in policy.ftsFields) {
      final spec = decl.schema[field];
      if (spec == null) {
        throw InvalidNodeTypeDecl(
          typeName: decl.typeName,
          fieldPath: 'indexPolicy.ftsFields',
          message:
              'indexPolicy.ftsFields names "$field" which is not in the '
              'schema.',
        );
      }
      if (!spec.ftsEligible) {
        throw InvalidNodeTypeDecl(
          typeName: decl.typeName,
          fieldPath: 'indexPolicy.ftsFields',
          message:
              'indexPolicy.ftsFields entry "$field" is not marked '
              'ftsEligible on its FieldSpec — refusing to silently index '
              'a non-text field.',
        );
      }
    }
    for (final field in policy.vectorFields) {
      final spec = decl.schema[field];
      if (spec == null) {
        throw InvalidNodeTypeDecl(
          typeName: decl.typeName,
          fieldPath: 'indexPolicy.vectorFields',
          message:
              'indexPolicy.vectorFields names "$field" which is not in '
              'the schema.',
        );
      }
      if (spec.type != FieldType.vec) {
        throw InvalidNodeTypeDecl(
          typeName: decl.typeName,
          fieldPath: 'indexPolicy.vectorFields',
          message:
              'indexPolicy.vectorFields entry "$field" must be a vec '
              'field (got ${spec.type.name}).',
        );
      }
      if (!spec.vectorEligible) {
        throw InvalidNodeTypeDecl(
          typeName: decl.typeName,
          fieldPath: 'indexPolicy.vectorFields',
          message:
              'indexPolicy.vectorFields entry "$field" is not marked '
              'vectorEligible on its FieldSpec.',
        );
      }
    }
  }

  void _validateAgainstRegistry(NodeTypeDecl decl) {
    final existing = _cache[decl.typeName];
    if (decl.supersedes == null) {
      // Fresh proposal — name must be free.
      if (existing != null) {
        throw NodeTypeAlreadyExists(
          typeName: decl.typeName,
          message:
              'type "${decl.typeName}" is already registered '
              '(set `supersedes` to evolve it instead of re-registering).',
        );
      }
      return;
    }

    // Supersedes-set proposal — predecessor must exist with matching id.
    final supersedesId = decl.supersedes!;
    final registeredId = _cacheDeclNodeIds[decl.typeName];
    if (existing == null || registeredId == null) {
      throw NodeTypeNotFound(
        typeName: decl.typeName,
        supersedesDeclNodeId: supersedesId.toString(),
        registeredDeclNodeId: null,
        message:
            'proposal supersedes ${supersedesId.toString()} but no '
            'registered type "${decl.typeName}" exists.',
      );
    }
    if (registeredId != supersedesId) {
      throw NodeTypeNotFound(
        typeName: decl.typeName,
        supersedesDeclNodeId: supersedesId.toString(),
        registeredDeclNodeId: registeredId.toString(),
        message:
            'proposal supersedes ${supersedesId.toString()} but the '
            'live decl for "${decl.typeName}" is at '
            '${registeredId.toString()} — re-author the proposal '
            'against the current tip.',
      );
    }
    final existingVersion = existing.version.value;
    final proposedVersion = decl.version.value;
    if (proposedVersion <= existingVersion) {
      throw NodeTypeVersionNotMonotonic(
        typeName: decl.typeName,
        existingVersion: existingVersion,
        proposedVersion: proposedVersion,
        message:
            'proposed version $proposedVersion must be strictly greater '
            'than the existing version $existingVersion.',
      );
    }
  }

  // ─── Internal: persistence ─────────────────────────────────────

  void _ensureWarmed() {
    if (_warmed) return;
    final results = _db.select(
      'SELECT type_name, version, decl_node_id, supersedes, schema_json, '
      'embedding_policy_json, index_policy_json, retention_policy_json, '
      'allowed_outgoing_json, allowed_incoming_json, validator_script_id '
      'FROM node_types',
    );
    for (final row in results) {
      final decl = _declFromRow(row);
      _cache[decl.typeName] = decl;
      _cacheDeclNodeIds[decl.typeName] =
          NodeId.fromString(row['decl_node_id'] as String);
    }
    // Re-assert FTS5 tables for every type already on disk. This is
    // the recovery path for a store opened against a DB whose
    // node_types rows survived a process restart: their per-type FTS
    // virtual tables may have been created by a previous run (in
    // which case `CREATE … IF NOT EXISTS` is a no-op) or may need to
    // be created now (first boot after a registry-only restore).
    final ftsCatalog = _ftsCatalog;
    if (ftsCatalog != null) {
      ftsCatalog.ensureAllTables(_cache.values, _db);
    }
    _warmed = true;
  }

  void _writeCacheRow(NodeTypeDecl decl, NodeId declNodeId, DateTime atUtc) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      _db.execute(
        'INSERT OR REPLACE INTO node_types ('
        'type_name, version, decl_node_id, supersedes, schema_json, '
        'embedding_policy_json, index_policy_json, retention_policy_json, '
        'allowed_outgoing_json, allowed_incoming_json, validator_script_id, '
        'registered_at_ms, registered_at_iso'
        ') VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          decl.typeName,
          decl.version.value,
          declNodeId.toString(),
          decl.supersedes?.toString(),
          jsonEncode(_schemaToJson(decl.schema)),
          jsonEncode(_embeddingPolicyToJson(decl.embeddingPolicy)),
          jsonEncode(_indexPolicyToJson(decl.indexPolicy)),
          jsonEncode(_retentionPolicyToJson(decl.retentionPolicy)),
          jsonEncode(_edgeSetToJson(decl.allowedOutgoing)),
          jsonEncode(_edgeSetToJson(decl.allowedIncoming)),
          decl.validatorScriptId,
          atUtc.millisecondsSinceEpoch,
          atUtc.toIso8601String(),
        ],
      );
      _db.execute('COMMIT');
    } catch (error, stack) {
      rollbackQuietly(_db);
      Error.throwWithStackTrace(error, stack);
    }
  }

  // ─── Internal: JSON marshalling ────────────────────────────────

  static Map<String, Object?> _schemaToJson(Map<String, FieldSpec> schema) {
    final out = <String, Object?>{};
    for (final entry in schema.entries) {
      final s = entry.value;
      out[entry.key] = <String, Object?>{
        'type': s.type.name,
        'nullable': s.nullable,
        'fts': s.ftsEligible,
        'vector': s.vectorEligible,
        if (s.enumValues.isNotEmpty) 'values': s.enumValues,
        if (s.nodeRefTypes.isNotEmpty) 'refs': s.nodeRefTypes.toList(),
      };
    }
    return out;
  }

  static Map<String, Object?> _embeddingPolicyToJson(EmbeddingPolicy p) {
    if (p.isNone) {
      return <String, Object?>{'mode': 'none'};
    }
    return <String, Object?>{
      'mode': 'embed',
      'model_identity': p.modelIdentity,
      'dimensions': p.dimensions,
      'source_fields': p.sourceFields,
    };
  }

  static Map<String, Object?> _indexPolicyToJson(IndexPolicy p) =>
      <String, Object?>{
        'fts_fields': p.ftsFields.toList()..sort(),
        'vector_fields': p.vectorFields.toList()..sort(),
        if (p.ftsTokeniser != null) 'fts_tokeniser': p.ftsTokeniser,
      };

  static Map<String, Object?> _retentionPolicyToJson(RetentionPolicy p) =>
      <String, Object?>{
        'default_horizon_ms': p.defaultHorizonMs,
        'reinforcement_resets_horizon': p.reinforcementResetsHorizon,
        'demote_from_indexes': p.demoteFromIndexes,
      };

  static List<String> _edgeSetToJson(Set<EdgeType> set) {
    final result = set.map((e) => e.wireName).toList()..sort();
    return result;
  }

  // ─── Internal: row → decl (for cache warm) ─────────────────────

  static NodeTypeDecl _declFromRow(Row row) {
    final supersedes = row['supersedes'] as String?;
    return NodeTypeDecl(
      typeName: row['type_name'] as String,
      version: BrainVersion.fromInt(row['version'] as int),
      supersedes: supersedes == null ? null : NodeId.fromString(supersedes),
      schema: _schemaFromJson(jsonDecode(row['schema_json'] as String)),
      embeddingPolicy:
          _embeddingPolicyFromJson(jsonDecode(row['embedding_policy_json'] as String)),
      indexPolicy:
          _indexPolicyFromJson(jsonDecode(row['index_policy_json'] as String)),
      retentionPolicy: _retentionPolicyFromJson(
        jsonDecode(row['retention_policy_json'] as String),
      ),
      allowedOutgoing: _edgeSetFromJson(
        jsonDecode(row['allowed_outgoing_json'] as String),
      ),
      allowedIncoming: _edgeSetFromJson(
        jsonDecode(row['allowed_incoming_json'] as String),
      ),
      validatorScriptId: row['validator_script_id'] as String?,
    );
  }

  static Map<String, FieldSpec> _schemaFromJson(Object? raw) {
    final result = <String, FieldSpec>{};
    if (raw is! Map) return result;
    for (final entry in raw.entries) {
      final key = entry.key as String;
      final spec = entry.value;
      if (spec is! Map) {
        throw StateError(
          'node_type.schema["$key"] is not a JSON object: '
          '${spec.runtimeType}',
        );
      }
      final fieldType = spec['type'];
      if (fieldType is! String) {
        throw StateError(
          'node_type.schema["$key"].type is not a string: '
          '${fieldType.runtimeType}',
        );
      }
      result[key] = FieldSpec(
        name: key,
        type: FieldType.values.byName(fieldType),
        nullable: (spec['nullable'] as bool?) ?? false,
        ftsEligible: (spec['fts'] as bool?) ?? false,
        vectorEligible: (spec['vector'] as bool?) ?? false,
        enumValues: List<String>.unmodifiable(
          (spec['values'] as List?)?.cast<String>() ?? const <String>[],
        ),
        nodeRefTypes: Set<String>.unmodifiable(
          (spec['refs'] as List?)?.cast<String>() ?? const <String>[],
        ),
      );
    }
    return result;
  }

  static EmbeddingPolicy _embeddingPolicyFromJson(Object? raw) {
    if (raw is! Map) return EmbeddingPolicy.none;
    if (raw['mode'] == 'none') return EmbeddingPolicy.none;
    final modelIdentity = raw['model_identity'];
    if (modelIdentity is! String) {
      throw StateError(
        'node_type.embedding.model_identity is not a string: '
        '${modelIdentity.runtimeType}',
      );
    }
    final dimensions = raw['dimensions'];
    if (dimensions is! int) {
      throw StateError(
        'node_type.embedding.dimensions is not an int: '
        '${dimensions.runtimeType}',
      );
    }
    final sourceFields = raw['source_fields'];
    if (sourceFields is! List) {
      throw StateError(
        'node_type.embedding.source_fields is not a list: '
        '${sourceFields.runtimeType}',
      );
    }
    return EmbeddingPolicy(
      modelIdentity: modelIdentity,
      dimensions: dimensions,
      sourceFields: List<String>.unmodifiable(sourceFields.cast<String>()),
    );
  }

  static IndexPolicy _indexPolicyFromJson(Object? raw) {
    if (raw is! Map) {
      return const IndexPolicy(ftsFields: <String>{}, vectorFields: <String>{});
    }
    return IndexPolicy(
      ftsFields: Set<String>.unmodifiable(
        (raw['fts_fields'] as List?)?.cast<String>() ?? const <String>[],
      ),
      vectorFields: Set<String>.unmodifiable(
        (raw['vector_fields'] as List?)?.cast<String>() ?? const <String>[],
      ),
      ftsTokeniser: raw['fts_tokeniser'] as String?,
    );
  }

  static RetentionPolicy _retentionPolicyFromJson(Object? raw) {
    if (raw is! Map) return RetentionPolicy.indefinite;
    return RetentionPolicy(
      defaultHorizonMs: raw['default_horizon_ms'] as int?,
      reinforcementResetsHorizon:
          (raw['reinforcement_resets_horizon'] as bool?) ?? true,
      demoteFromIndexes: (raw['demote_from_indexes'] as bool?) ?? true,
    );
  }

  static Set<EdgeType> _edgeSetFromJson(Object? raw) {
    if (raw is! List) return const <EdgeType>{};
    return Set<EdgeType>.unmodifiable(
      raw.cast<String>().map(EdgeType.fromWireName),
    );
  }
}
