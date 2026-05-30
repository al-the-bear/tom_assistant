// VectorTable — the `vectors.db` side of the storage stack
// (Plan step A.51).
//
// Plan step A.51:
//   "Implement vector table per `memory_specification.md` § 2;
//    embedding-model identity recorded per row."
//
// Spec § 2.1: `vectors.db` is a separate SQLite file whose lifecycle
// is independent of `memory.db`. It can be regenerated from
// `memory.db` after an embedding-model upgrade (which is exactly what
// `restructure_tree_v1` does).
//
// Spec § 10.4 (Embedding-model agreement):
//   "All replicas must use the same substrate embedding model. Memory
//    records the embedding-model-identity per vector and refuses to
//    mix incompatible vectors in a single index. A model change
//    triggers a `restructure_tree_v1` for re-embedding."
//
// Spec § 12.3 (Embeddings):
//   "Vectors are stored in `vectors.db` as `blob` with the
//    embedding-model identity in a sibling column."
//
// ─────────────────────────────────────────────────────────────────────
// Why a `vector_indexes` meta table plus one virtual table per model
// ─────────────────────────────────────────────────────────────────────
//
// The spec's "refuses to mix incompatible vectors in a single index"
// requirement is most naturally expressed as **one index per model**.
// A `vec0` virtual table fixes its dimensionality at CREATE time —
// `CREATE VIRTUAL TABLE x USING vec0(embedding float[768])` — so
// putting 768-d and 1024-d vectors in the same physical index is not
// even possible without parallel tables. We use that constraint
// directly: every installed embedding model gets its own virtual
// table, keyed by `modelId`, with the mapping recorded in a
// `vector_indexes` meta row.
//
// The meta row is the **source of truth** for the layer:
//
//   * `model_id`        — the substrate-supplied identity
//                         ("ollama/nomic-embed-text@1.5",
//                         "openai/text-embedding-3-small", …). The
//                         layer treats it as an opaque string; only
//                         the substrate knows what it semantically
//                         means.
//   * `table_name`      — the physical virtual-table name in
//                         `vectors.db`. Derived deterministically from
//                         `model_id` for diagnostic readability, but
//                         persisted so a future change to the
//                         derivation algorithm does not invalidate
//                         existing indexes.
//   * `dims`            — vector dimensionality. Used to reject
//                         dimension-mismatched writes and to compose
//                         the `vec0` `CREATE VIRTUAL TABLE` statement.
//   * `backend_name`    — the [VectorIndexBackend] that created the
//                         table. Recorded so tests cannot accidentally
//                         pair a "plain blob" install with a "vec0"
//                         query.
//   * `installed_at_*`  — dual-time form (spec § 12.2).
//
// Why **not** a single mega-table partitioned by model_id:
//
//   * vec0's `partition_key` syntax can express this, but it requires
//     every CREATE to know the full set of partitions up front. New
//     models would force a CREATE rewrite, which means every other
//     model's index is rebuilt. A separate table per model lets new
//     models go online without disturbing the others.
//   * Backup and `restructure_tree_v1` operate per-model anyway —
//     either to drop and re-embed under a new model, or to ship just
//     the active model to a mirror. Per-table is a cleaner unit.
//   * Plain-SQL diagnostic tools (the operator inspector at A.83) can
//     `SELECT name FROM sqlite_master WHERE type='table'` and discover
//     every model's index by name without parsing partition metadata.
//
// ─────────────────────────────────────────────────────────────────────
// Why the backend interface
// ─────────────────────────────────────────────────────────────────────
//
// The production backend is `Vec0VirtualTableBackend` — composes the
// `CREATE VIRTUAL TABLE … USING vec0(node_id TEXT PRIMARY KEY,
// embedding float[N])` DDL, plus `INSERT … VALUES(?, ?)`,
// `DELETE … WHERE node_id = ?`, and the
// `SELECT node_id, distance … WHERE embedding MATCH ? ORDER BY
// distance LIMIT ?` query that sqlite-vec ships.
//
// The production backend only works when the vec0 shared library is
// loaded into the host `Sqlite3` instance (Plan step A.50 + the
// `loadVecExtensionWithFailOpen` wiring). On a developer machine
// without the binary — which is every machine today (Q-A.50.2) — the
// `vec0` module is absent and `CREATE VIRTUAL TABLE … USING vec0` is
// rejected by SQLite with "no such module: vec0".
//
// The test backend `PlainBlobTableBackend` provides the same
// observable surface using only plain SQL: `CREATE TABLE … (node_id
// TEXT PRIMARY KEY, embedding BLOB)`, the equivalent INSERT/DELETE,
// and a brute-force L2 nearest-neighbour computed in Dart. It is not
// production-suitable (no indexing, O(N) per query), but it lets
// every contract the `VectorTable` layer owns be tested
// deterministically without a vec0 binary.
//
// The exception is the production backend itself: its concrete
// vec0-syntax tests are deferred to A.53 ("extension load + vec query
// roundtrip"), where a real binary is expected to land. A.51's tests
// cover the production backend at the SQL-string composition level
// (the DDL / INSERT / DELETE / SELECT shapes are stable) and leave the
// full integration roundtrip to A.53.
//
// ─────────────────────────────────────────────────────────────────────
// Why a separate file per concern is *not* warranted at A.51
// ─────────────────────────────────────────────────────────────────────
//
// The five public surfaces — `VectorTable`, `VectorIndexInfo`,
// `VectorMatch`, `VectorIndexBackend`, and the two backend impls —
// share so much vocabulary (table name, dims, blob layout) that
// splitting them into five files would create five file-level
// indirections for what is one mental unit. They live in one file
// alongside their shared header. Exceptions live in their own file
// (`vector_table_exception.dart`) because they are referenced from
// other layers (Q-A.51.4 — wiring at A.52+) without needing the
// backend types.

import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';

import 'vector_table_exception.dart';

/// Lookup record for one installed embedding-model index.
///
/// Returned by [VectorTable.installIndex], [VectorTable.lookupIndex]
/// and [VectorTable.listInstalledIndexes]. Immutable; reflects the
/// state of the `vector_indexes` meta row at the moment of the call.
final class VectorIndexInfo {
  /// The substrate-supplied model identity (opaque to memory).
  final String modelId;

  /// The physical virtual-table name in `vectors.db`. Derived from
  /// [modelId] by [VectorTable.deriveTableName] but persisted in the
  /// meta row so a future change to the derivation never invalidates
  /// an existing index.
  final String tableName;

  /// Vector dimensionality this index was created with.
  final int dims;

  /// Backend that created the index (e.g. `'vec0'`, `'plain'`).
  /// Recorded so diagnostics can tell which backend an existing index
  /// was authored under.
  final String backendName;

  /// When the index was installed (wall-clock UTC).
  final BrainTime installedAt;

  const VectorIndexInfo({
    required this.modelId,
    required this.tableName,
    required this.dims,
    required this.backendName,
    required this.installedAt,
  });

  @override
  String toString() => 'VectorIndexInfo('
      'model: $modelId, table: $tableName, dims: $dims, '
      'backend: $backendName, installed: ${installedAt.toIso8601String()})';
}

/// One row of a `queryNearest` result.
///
/// Distance interpretation depends on the backend — `vec0` returns
/// the L2 distance by default (`MATCH` operator), and the test
/// backend computes the same metric. Smaller is closer; identical
/// vectors yield distance 0.
final class VectorMatch {
  /// Node id of the match.
  final String nodeId;

  /// L2 distance from the query vector. `>= 0.0`.
  final double distance;

  const VectorMatch({required this.nodeId, required this.distance});

  @override
  String toString() => 'VectorMatch($nodeId, d=$distance)';
}

/// Storage backend for the per-model vector index.
///
/// One implementation per family of SQL surface — `vec0` for
/// production, `plain` for tests. The backend is responsible for:
///
///   * Composing the DDL that creates the per-model table.
///   * Composing INSERT / DELETE statements against that table.
///   * Composing the nearest-neighbour SELECT against that table.
///
/// The backend does *not* own the meta table — that is the
/// [VectorTable] layer's concern. The backend never reads or writes
/// `vector_indexes`; it only touches the per-model physical table.
///
/// All methods take the `Database` rather than holding a reference,
/// so the same backend instance can serve multiple databases (the
/// production case is per-process; the test case opens and discards
/// in-memory databases per test).
abstract interface class VectorIndexBackend {
  /// Stable identifier — recorded in the `vector_indexes.backend_name`
  /// column. Diagnostic-only; the backend's behaviour is defined by
  /// its implementing class, not by this string.
  String get backendName;

  /// Creates the physical table for the index. The
  /// [VectorTable] layer guarantees [tableName] is a valid SQL
  /// identifier and that [dims] is `> 0`. The backend should be
  /// idempotent — calling [createIndex] against an already-installed
  /// table should be a no-op (the production vec0 backend uses
  /// `CREATE VIRTUAL TABLE IF NOT EXISTS`; the test backend uses
  /// `CREATE TABLE IF NOT EXISTS`).
  void createIndex(Database db, String tableName, int dims);

  /// Inserts (or replaces) one vector row.
  ///
  /// [vectorBlob] is the little-endian float32 form produced by
  /// `Vec.toBlob()`. The backend is responsible for matching its
  /// per-row width to [dims] (the layer above guarantees
  /// `vectorBlob.lengthInBytes == dims * 4`).
  ///
  /// "Insert or replace" semantics — a re-insert under the same
  /// `nodeId` overwrites. This matches the two-DB coordinator's
  /// idempotency requirement (`TwoDbCoordinator` recovery may replay
  /// the same payload).
  void insertRow(
    Database db,
    String tableName,
    String nodeId,
    Uint8List vectorBlob,
    int dims,
  );

  /// Deletes one vector row. No-op if the row does not exist.
  void deleteRow(Database db, String tableName, String nodeId);

  /// k-nearest-neighbour query against the index.
  ///
  /// Returns up to [k] matches ordered by ascending distance.
  /// [queryBlob] uses the same wire form as [insertRow].
  List<VectorMatch> queryNearest(
    Database db,
    String tableName,
    Uint8List queryBlob,
    int dims,
    int k,
  );
}

/// Production backend — composes sqlite-vec (`vec0`) DDL and SQL.
///
/// Requires the vec0 shared library to be loaded into the host
/// `Sqlite3` instance (Plan step A.50). Without the extension, the
/// CREATE statement fails with `SqliteException: no such module:
/// vec0`. That failure is *expected* on a developer machine without
/// the binary (Q-A.50.2); the caller above (`SqliteTomBrainMemory.open`,
/// landing at A.28+) gates on `loadVecExtensionWithFailOpen` returning
/// `loaded` before constructing this backend.
///
/// SQL shapes:
///
/// ```sql
/// -- createIndex
/// CREATE VIRTUAL TABLE IF NOT EXISTS <table> USING vec0(
///   node_id TEXT PRIMARY KEY,
///   embedding float[<dims>]
/// )
///
/// -- insertRow (REPLACE semantics)
/// INSERT INTO <table>(node_id, embedding) VALUES (?, ?)
///   ON CONFLICT(node_id) DO UPDATE SET embedding = excluded.embedding
///
/// -- deleteRow
/// DELETE FROM <table> WHERE node_id = ?
///
/// -- queryNearest
/// SELECT node_id, distance FROM <table>
///   WHERE embedding MATCH ?
///   ORDER BY distance
///   LIMIT ?
/// ```
final class Vec0VirtualTableBackend implements VectorIndexBackend {
  /// Recorded backend identity — `'vec0'`.
  @override
  String get backendName => 'vec0';

  const Vec0VirtualTableBackend();

  @override
  void createIndex(Database db, String tableName, int dims) {
    db.execute(
      'CREATE VIRTUAL TABLE IF NOT EXISTS "$tableName" USING vec0('
      'node_id TEXT PRIMARY KEY, '
      'embedding float[$dims]'
      ')',
    );
  }

  @override
  void insertRow(
    Database db,
    String tableName,
    String nodeId,
    Uint8List vectorBlob,
    int dims,
  ) {
    // sqlite-vec's INSERT … ON CONFLICT DO UPDATE pattern is supported
    // from vec0 0.1.x onwards (the version we pin in
    // `tom_binaries/sqlite_vec/`). The "replace" semantics match the
    // two-DB coordinator's recovery contract.
    db.execute(
      'INSERT INTO "$tableName"(node_id, embedding) VALUES (?, ?) '
      'ON CONFLICT(node_id) DO UPDATE SET embedding = excluded.embedding',
      <Object?>[nodeId, vectorBlob],
    );
  }

  @override
  void deleteRow(Database db, String tableName, String nodeId) {
    db.execute(
      'DELETE FROM "$tableName" WHERE node_id = ?',
      <Object?>[nodeId],
    );
  }

  @override
  List<VectorMatch> queryNearest(
    Database db,
    String tableName,
    Uint8List queryBlob,
    int dims,
    int k,
  ) {
    final rows = db.select(
      'SELECT node_id, distance FROM "$tableName" '
      'WHERE embedding MATCH ? '
      'ORDER BY distance '
      'LIMIT ?',
      <Object?>[queryBlob, k],
    );
    return rows
        .map((r) => VectorMatch(
              nodeId: r['node_id'] as String,
              distance: (r['distance'] as num).toDouble(),
            ))
        .toList(growable: false);
  }
}

/// Test backend — composes plain-SQL DDL with a Dart-side
/// brute-force k-NN scan.
///
/// Used by every A.51 test that exercises the full insert / query /
/// remove roundtrip without a vec0 binary. The on-disk shape is:
///
/// ```sql
/// CREATE TABLE IF NOT EXISTS <table>(
///   node_id TEXT PRIMARY KEY,
///   embedding BLOB NOT NULL,
///   dims INTEGER NOT NULL
/// )
/// ```
///
/// Not production-suitable: every `queryNearest` reads every row and
/// computes L2 distance in Dart. Fine for the dozens-of-vectors test
/// scale; would be unacceptable at the millions-of-nodes target the
/// spec sets for the real engine.
final class PlainBlobTableBackend implements VectorIndexBackend {
  /// Recorded backend identity — `'plain'`.
  @override
  String get backendName => 'plain';

  const PlainBlobTableBackend();

  @override
  void createIndex(Database db, String tableName, int dims) {
    db.execute(
      'CREATE TABLE IF NOT EXISTS "$tableName" ('
      'node_id TEXT PRIMARY KEY, '
      'embedding BLOB NOT NULL, '
      'dims INTEGER NOT NULL'
      ')',
    );
  }

  @override
  void insertRow(
    Database db,
    String tableName,
    String nodeId,
    Uint8List vectorBlob,
    int dims,
  ) {
    db.execute(
      'INSERT INTO "$tableName"(node_id, embedding, dims) '
      'VALUES (?, ?, ?) '
      'ON CONFLICT(node_id) DO UPDATE SET '
      'embedding = excluded.embedding, dims = excluded.dims',
      <Object?>[nodeId, vectorBlob, dims],
    );
  }

  @override
  void deleteRow(Database db, String tableName, String nodeId) {
    db.execute(
      'DELETE FROM "$tableName" WHERE node_id = ?',
      <Object?>[nodeId],
    );
  }

  @override
  List<VectorMatch> queryNearest(
    Database db,
    String tableName,
    Uint8List queryBlob,
    int dims,
    int k,
  ) {
    final query = Vec.fromBlob(queryBlob);
    final rows = db.select(
      'SELECT node_id, embedding FROM "$tableName"',
    );
    final matches = <VectorMatch>[];
    for (final row in rows) {
      final blob = _readBlob(row['embedding']);
      // Defensive: rows that have somehow ended up with the wrong
      // width are skipped (they cannot participate in a k-NN query
      // anyway). This branch is unreachable through the layer's own
      // call paths because `VectorTable.insertVector` checks dims at
      // the boundary, but the test backend defends against direct
      // SQL access from tests that intentionally seed bad rows.
      if (blob.lengthInBytes != dims * 4) {
        continue;
      }
      final candidate = Vec.fromBlob(blob);
      final distance = l2(query, candidate);
      matches.add(VectorMatch(
        nodeId: row['node_id'] as String,
        distance: distance,
      ));
    }
    matches.sort((a, b) => a.distance.compareTo(b.distance));
    if (matches.length <= k) {
      return List.unmodifiable(matches);
    }
    return List.unmodifiable(matches.sublist(0, k));
  }

  static Uint8List _readBlob(Object? raw) {
    if (raw is Uint8List) return raw;
    if (raw is List<int>) return Uint8List.fromList(raw);
    throw StateError(
      'PlainBlobTableBackend: expected BLOB, got ${raw.runtimeType}',
    );
  }
}

/// The `vectors.db` side of the storage stack.
///
/// One instance per process per `vectors.db` handle. Holds no
/// per-call state — the state lives in the `vector_indexes` meta
/// table and in each per-model physical table.
///
/// Thread / isolate safety: inherits the host `Database` handle's
/// threading model. The `sqlite3` Dart package requires a
/// single-threaded owner per handle; the isolate-adapter step
/// (A.85+) will introduce the cross-isolate boundary if needed.
final class VectorTable {
  final Database _vectorsDb;
  final VectorIndexBackend _backend;
  final Clock _clock;

  /// Constructs a vector table over [vectorsDb] using [backend] for
  /// the per-model physical-table operations.
  ///
  /// [clock] is the time source for the `installed_at` columns on
  /// the `vector_indexes` meta row. Production passes
  /// `const SystemClock()`; tests pin time via `FixedClock` or
  /// `MutableTestClock`.
  ///
  /// Construction does *not* touch the database — call
  /// [ensureMetaTable] explicitly before first use, or simply call
  /// any of the install / lookup paths, which all guarantee meta-
  /// table existence before reading from it.
  VectorTable({
    required Database vectorsDb,
    required VectorIndexBackend backend,
    required Clock clock,
  })  : _vectorsDb = vectorsDb,
        _backend = backend,
        _clock = clock;

  /// Creates the `vector_indexes` meta table if absent. Idempotent.
  ///
  /// Called automatically by every public method that touches meta;
  /// exposed publicly for explicit boot-time installation when the
  /// caller wants the table to exist before the first install.
  void ensureMetaTable() {
    _vectorsDb.execute(
      'CREATE TABLE IF NOT EXISTS vector_indexes ('
      'model_id          TEXT PRIMARY KEY, '
      'table_name        TEXT NOT NULL UNIQUE, '
      'dims              INTEGER NOT NULL, '
      'backend_name      TEXT NOT NULL, '
      'installed_at_ms   INTEGER NOT NULL, '
      'installed_at_iso  TEXT NOT NULL'
      ')',
    );
  }

  /// Installs a vector index for the given [modelId] at the given
  /// [dims].
  ///
  /// Semantics:
  ///
  ///   * Idempotent on (modelId, dims): a re-install of the same
  ///     model at the same dimensionality returns the existing
  ///     [VectorIndexInfo] unchanged. The physical table's
  ///     `CREATE … IF NOT EXISTS` is also re-run, harmlessly.
  ///   * Strict on dims mismatch: re-installing the same model with
  ///     a different dimensionality raises
  ///     [IndexInstallationConflict]. Operators who want to change
  ///     dims must drop the existing index explicitly (the
  ///     `restructure_tree_v1` migration is the supported path).
  ///
  /// On first install, the meta row is written **before** the
  /// physical table is created — so a crash between the two would
  /// leave a meta row pointing at a non-existent table. The next
  /// install attempt re-runs `createIndex` (which is idempotent) and
  /// closes the gap. Spec § 2.4 does not require a two-DB-style
  /// pending log here because `vectors.db` alone is the unit of
  /// failure (no cross-DB invariant to preserve).
  ///
  /// Throws [IndexInstallationConflict] when the same model id is
  /// already installed at a different dimensionality.
  VectorIndexInfo installIndex({
    required String modelId,
    required int dims,
  }) {
    if (modelId.isEmpty) {
      throw ArgumentError.value(
        modelId,
        'modelId',
        'modelId must be non-empty',
      );
    }
    if (dims <= 0) {
      throw ArgumentError.value(dims, 'dims', 'dims must be > 0');
    }
    ensureMetaTable();

    final existing = lookupIndex(modelId);
    if (existing != null) {
      if (existing.dims != dims) {
        throw IndexInstallationConflict(
          modelId: modelId,
          message: 'model already installed with dims=${existing.dims}, '
              'caller requested dims=$dims; drop the existing index '
              'before re-installing',
          existingDims: existing.dims,
          proposedDims: dims,
        );
      }
      // Same dims — re-run createIndex to close the
      // "meta-row-without-table" gap if a previous attempt crashed
      // between the two writes.
      _backend.createIndex(_vectorsDb, existing.tableName, dims);
      return existing;
    }

    final tableName = deriveTableName(modelId);
    final installedAt = BrainTime.now(_clock);

    _vectorsDb.execute(
      'INSERT INTO vector_indexes('
      'model_id, table_name, dims, backend_name, '
      'installed_at_ms, installed_at_iso'
      ') VALUES (?, ?, ?, ?, ?, ?)',
      <Object?>[
        modelId,
        tableName,
        dims,
        _backend.backendName,
        installedAt.toMs(),
        installedAt.toIso8601String(),
      ],
    );

    _backend.createIndex(_vectorsDb, tableName, dims);

    return VectorIndexInfo(
      modelId: modelId,
      tableName: tableName,
      dims: dims,
      backendName: _backend.backendName,
      installedAt: installedAt,
    );
  }

  /// Looks up the meta row for [modelId]. Returns `null` when no
  /// index is installed for that model.
  ///
  /// Always ensures the meta table exists before reading, so a
  /// caller can `lookupIndex(...)` against a freshly-opened
  /// `vectors.db` without an explicit `ensureMetaTable()` first.
  VectorIndexInfo? lookupIndex(String modelId) {
    ensureMetaTable();
    final rows = _vectorsDb.select(
      'SELECT model_id, table_name, dims, backend_name, '
      'installed_at_ms '
      'FROM vector_indexes '
      'WHERE model_id = ?',
      <Object?>[modelId],
    );
    if (rows.isEmpty) {
      return null;
    }
    return _decodeInfo(rows.first);
  }

  /// Lists every installed index, ordered by install time ascending.
  ///
  /// Used by the operator inspector (A.83) and by
  /// `restructure_tree_v1` to enumerate models pending re-embed.
  List<VectorIndexInfo> listInstalledIndexes() {
    ensureMetaTable();
    final rows = _vectorsDb.select(
      'SELECT model_id, table_name, dims, backend_name, '
      'installed_at_ms '
      'FROM vector_indexes '
      'ORDER BY installed_at_ms ASC, model_id ASC',
    );
    return rows.map(_decodeInfo).toList(growable: false);
  }

  /// `true` iff an index exists for [modelId]. Cheaper than
  /// [lookupIndex] when the caller only needs the boolean.
  bool hasIndex(String modelId) {
    ensureMetaTable();
    final rows = _vectorsDb.select(
      'SELECT 1 FROM vector_indexes WHERE model_id = ? LIMIT 1',
      <Object?>[modelId],
    );
    return rows.isNotEmpty;
  }

  /// Inserts (or replaces) a vector row for [nodeId] under
  /// [modelId].
  ///
  /// Refusals:
  ///
  ///   * [EmbeddingModelMismatch] — no index installed for
  ///     [modelId]. The layer never auto-installs (see file header);
  ///     the caller must call [installIndex] explicitly or arrange
  ///     for the migration to do so.
  ///   * [EmbeddingDimsMismatch] — `vector.dimension` does not match
  ///     the installed `dims`.
  ///
  /// "Insert or replace" semantics — calling twice with the same
  /// `(modelId, nodeId)` overwrites. This is the contract the
  /// two-DB coordinator's recovery path depends on (a replayed
  /// write must converge to the same final state).
  void insertVector({
    required String nodeId,
    required Vec vector,
    required String modelId,
  }) {
    final info = lookupIndex(modelId);
    if (info == null) {
      throw EmbeddingModelMismatch(
        modelId: modelId,
        message: 'no vector index installed for model $modelId; '
            'call installIndex(modelId: $modelId, dims: ${vector.dimension}) '
            'first',
      );
    }
    if (vector.dimension != info.dims) {
      throw EmbeddingDimsMismatch(
        modelId: modelId,
        message: 'vector dimensionality ${vector.dimension} does not '
            'match installed index dims ${info.dims} for model $modelId',
        expectedDims: info.dims,
        actualDims: vector.dimension,
      );
    }
    _backend.insertRow(
      _vectorsDb,
      info.tableName,
      nodeId,
      vector.toBlob(),
      info.dims,
    );
  }

  /// Deletes the vector row for [nodeId] under [modelId].
  ///
  /// Refusals:
  ///
  ///   * [EmbeddingModelMismatch] — no index installed for
  ///     [modelId]. We do **not** silently swallow: a remove for a
  ///     non-existent index is almost always a caller bug (the
  ///     caller forgot which model owns the vector).
  ///
  /// No error is raised when the row does not exist — that case is
  /// idempotent by design (a node that never had a vector still
  /// gets a successful remove). The backend's DELETE is a no-op on
  /// the missing-row path.
  void removeVector({
    required String nodeId,
    required String modelId,
  }) {
    final info = lookupIndex(modelId);
    if (info == null) {
      throw EmbeddingModelMismatch(
        modelId: modelId,
        message: 'no vector index installed for model $modelId; '
            'cannot remove vectors for an absent model',
      );
    }
    _backend.deleteRow(_vectorsDb, info.tableName, nodeId);
  }

  /// k-nearest-neighbour query for [query] under [modelId], limited
  /// to [k] results.
  ///
  /// Refusals:
  ///
  ///   * [EmbeddingModelMismatch] — no index installed for [modelId].
  ///   * [EmbeddingDimsMismatch] — query dim does not match installed
  ///     dims.
  ///   * [ArgumentError] — [k] <= 0.
  ///
  /// Returns up to [k] matches ordered by ascending distance. May
  /// return fewer than [k] when the index has fewer rows than [k].
  /// Returns an empty list when the index has no rows.
  List<VectorMatch> queryNearest({
    required Vec query,
    required int k,
    required String modelId,
  }) {
    if (k <= 0) {
      throw ArgumentError.value(k, 'k', 'k must be > 0');
    }
    final info = lookupIndex(modelId);
    if (info == null) {
      throw EmbeddingModelMismatch(
        modelId: modelId,
        message: 'no vector index installed for model $modelId; '
            'cannot query nearest neighbours',
      );
    }
    if (query.dimension != info.dims) {
      throw EmbeddingDimsMismatch(
        modelId: modelId,
        message: 'query dimensionality ${query.dimension} does not '
            'match installed index dims ${info.dims} for model $modelId',
        expectedDims: info.dims,
        actualDims: query.dimension,
      );
    }
    return _backend.queryNearest(
      _vectorsDb,
      info.tableName,
      query.toBlob(),
      info.dims,
      k,
    );
  }

  /// Derives a SQL-safe physical table name from [modelId].
  ///
  /// The algorithm:
  ///
  ///   1. Take the lowercased model id; replace every character
  ///      that is not `[a-z0-9_]` with `_`. Cap the readable prefix
  ///      at 32 chars.
  ///   2. Append `_` and a stable 8-hex-digit FNV-1a 32-bit hash of
  ///      the original `modelId` (full string, not the truncated
  ///      readable form). The hash is the collision-resistant suffix;
  ///      the readable prefix is purely for diagnostic value when an
  ///      operator looks at `sqlite_master`.
  ///   3. Prepend the `vec_idx_` family prefix so every index this
  ///      layer creates can be located with a single LIKE pattern.
  ///
  /// Exposed publicly so tests can assert on the derivation and so
  /// the operator inspector can compute a name without round-tripping
  /// through `installIndex`. Stability across versions is not a
  /// load-bearing guarantee — the meta row stores the table name, so
  /// a later change to this function does not invalidate any
  /// existing index.
  static String deriveTableName(String modelId) {
    final lower = modelId.toLowerCase();
    final sanitised = StringBuffer();
    for (var i = 0; i < lower.length && sanitised.length < 32; i++) {
      final ch = lower.codeUnitAt(i);
      final isAlnum = (ch >= 0x30 && ch <= 0x39) || // 0-9
          (ch >= 0x61 && ch <= 0x7a); // a-z
      final isUnderscore = ch == 0x5f;
      sanitised.write(isAlnum || isUnderscore
          ? String.fromCharCode(ch)
          : '_');
    }
    final hash = _fnv1a32(modelId).toRadixString(16).padLeft(8, '0');
    return 'vec_idx_${sanitised.toString()}_$hash';
  }

  /// FNV-1a 32-bit hash of [s], computed over the UTF-16 code units.
  ///
  /// FNV-1a is not cryptographic — collision-resistance here is only
  /// what we need to disambiguate the readable-prefix portion of the
  /// table name. The meta row's `UNIQUE` constraint on `table_name`
  /// is the actual collision detector: a collision (in the
  /// astronomically-unlikely worst case) would surface as a
  /// SqliteException on `installIndex` and the operator would pick a
  /// new model id.
  static int _fnv1a32(String s) {
    const int offset = 0x811c9dc5;
    const int prime = 0x01000193;
    var hash = offset;
    for (var i = 0; i < s.length; i++) {
      hash ^= s.codeUnitAt(i) & 0xff;
      hash = (hash * prime) & 0xffffffff;
    }
    return hash;
  }

  VectorIndexInfo _decodeInfo(Row row) => VectorIndexInfo(
        modelId: row['model_id'] as String,
        tableName: row['table_name'] as String,
        dims: row['dims'] as int,
        backendName: row['backend_name'] as String,
        installedAt: BrainTime.fromMs(row['installed_at_ms'] as int),
      );
}
