// CentroidStore — `memory.db` side of the centroid table, with the
// `updateCentroid` write path.
//
// Plan step A.63:
//   "Implement `classificationCentroid` storage and the
//    `updateCentroid` write path."
//
// Spec § 7 (Classification — LLM-independent centroid-based
// classification):
//
//   * § 7.1 — A centroid is stored per `NodeType` and per `Procedure`.
//     It is the mean of the embeddings of the accepted examples for
//     that key, recomputed on a cadence (the `dream_recentroid_v1`
//     sleep job).
//   * § 7.3 — `dream_recentroid_v1` is the *only* writer in normal
//     operation. Memory does not auto-recompute on persist; it
//     accepts the next centroid via `updateCentroid` and serves it
//     from then on.
//
// ─────────────────────────────────────────────────────────────────────
// Surface at A.63
// ─────────────────────────────────────────────────────────────────────
//
// A.63 lands the *write half* of the centroid surface:
//
//   * `CentroidStore.update(record)` — upsert one centroid row,
//     stamping `updated_at_ms` / `updated_at_iso` from the injected
//     clock.
//   * `CentroidStore.read(forKey)` — read one row back (used by
//     `classify` at A.64 and by tests today).
//   * `CentroidStore.listKeys({prefix})` — list the present keys,
//     optionally filtered by the `'NodeType:'` / `'Procedure:'`
//     namespace prefix. The classifier (A.64) walks this to find
//     centroids matching a [ClassificationTarget].
//   * `CentroidStore.count()` — diagnostic helper; tests rely on it
//     to assert "exactly one row" or "still N rows" outcomes.
//
// A.64 adds the `classify(Vec, target)` method that *reads* through
// this surface; A.65 adds `findUncertain(forKey, low, high, limit)`
// that walks the centroid table to discover borderline nodes. The
// concrete `TomBrainMemory.updateCentroid(forKey, centroid)`
// implementation lands later in Phase A (see Q-A.63.2 for why the
// abstract surface deliberately does not carry the
// `embeddingModelId` / `exampleCount` fields).
//
// ─────────────────────────────────────────────────────────────────────
// Key format — `'NodeType:Question'`, `'Procedure:research_v1'`
// ─────────────────────────────────────────────────────────────────────
//
// The `for_key` column is namespaced so a node-type called the same
// thing as a procedure does not collide. The namespace strings live as
// public constants on this class (`nodeTypeKeyPrefix`,
// `procedureKeyPrefix`) and helpers (`keyForNodeType`,
// `keyForProcedure`) are provided so call sites never assemble the
// string by hand. Spec § 7.1 names the same pattern; the constants
// here are the canonical source.
//
// ─────────────────────────────────────────────────────────────────────
// Upsert semantics
// ─────────────────────────────────────────────────────────────────────
//
// `update` uses `INSERT … ON CONFLICT(for_key) DO UPDATE` — every
// field except `for_key` is overwritten, including
// `embedding_model_id`. The previous row is gone after the call. This
// is the right contract for `dream_recentroid_v1`: a freshly-computed
// centroid replaces the prior one wholesale; partial updates would
// leak old example counts or stale model ids into a row whose vector
// belongs to a different model.
//
// ─────────────────────────────────────────────────────────────────────
// Concurrency
// ─────────────────────────────────────────────────────────────────────
//
// `update` is a single SQL statement, so SQLite's per-statement
// implicit transaction is enough; no `BEGIN`/`COMMIT` wrapper is
// needed. Under WAL (the production journal mode, A.26), a reader on
// another connection sees either the pre-update or the post-update
// row but never a torn read — the property A.66 names as "concurrent
// `updateCentroid` does not affect an in-flight recall". The store
// itself is not multi-threaded — it inherits the `Database` handle's
// single-owner rule, same as every other A-step store class.
//
// ─────────────────────────────────────────────────────────────────────
// What this file owns since A.69
// ─────────────────────────────────────────────────────────────────────
//
// `CentroidDriftDetected` shaking-event emission (spec § 9.4). After
// every successful `update`, the store compares the freshly-written
// centroid against the prior row (read before the upsert):
//
//   * No prior row (first-ever update for this key) — no emission.
//     There is nothing to compare against.
//   * Prior `embedding_model_id` differs from the new one — emits
//     unconditionally with `cosineSimilarity: null`. A different
//     embedding model produces incommensurable vectors; the only
//     correct downstream reaction is a re-embed migration. The cosine
//     cutoff is bypassed because the comparison would be meaningless.
//   * Same model, prior `example_count` >= `driftMinPreviousExamples`
//     (default `8`) AND `cosine(prior, new) < driftCosineThreshold`
//     (default `0.85`) — emits with the measured cosine. The
//     example-count floor avoids treating cold-start jitter
//     (centroid built from a handful of examples) as drift.
//   * All other cases — no emission. The centroid moved, but not
//     beyond the tolerance the store was configured for.
//
// Q-A.69.2 documents the threshold rationale. The detection runs
// regardless of whether an `eventSink` is wired — the prior read is
// cheap and unconditional makes the logic easier to reason about; the
// sink call short-circuits when null.

import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show BrainTime, ClassificationDecision, ClassificationTarget, Clock, cosine, MemoryEvent, Scope, Vec;

import '../cognitive_agents/shaking_events.dart';
import 'classification_events.dart';

/// One row of the `centroids` table.
///
/// Carries the full record the storage layer needs:
///
///   * [forKey] — namespaced key, e.g. `'NodeType:Question'`.
///   * [embeddingModelId] — the model that produced [centroid].
///     Stored alongside so a future re-embed migration can detect
///     stale rows (spec § 15 — "Embedding-model mismatch").
///   * [centroid] — the centroid vector itself.
///   * [exampleCount] — how many accepted examples contributed to
///     this centroid. The `classify` cold-start gate (spec § 7.1,
///     `n=8` default) reads this to decide whether to serve the
///     centroid at all.
///   * [updatedAt] — wall-clock UTC at which the row was last
///     written. Stamped by the store from the injected clock; the
///     value here is the one read back, not a caller-provided field.
final class CentroidRecord {
  /// Namespaced key — see [CentroidStore.keyForNodeType] /
  /// [CentroidStore.keyForProcedure].
  final String forKey;

  /// Embedding-model identity (matches `EmbeddingPolicy.modelId`).
  final String embeddingModelId;

  /// The centroid vector. Dimension equals [centroid].dimension.
  final Vec centroid;

  /// Number of accepted examples that produced [centroid].
  final int exampleCount;

  /// Wall-clock UTC stamp from the store's clock.
  final BrainTime updatedAt;

  const CentroidRecord({
    required this.forKey,
    required this.embeddingModelId,
    required this.centroid,
    required this.exampleCount,
    required this.updatedAt,
  });

  @override
  String toString() => 'CentroidRecord('
      'forKey: $forKey, model: $embeddingModelId, '
      'dims: ${centroid.dimension}, examples: $exampleCount, '
      'updatedAt: ${updatedAt.toIso8601String()})';
}

/// `memory.db`-side storage for classification centroids.
///
/// Construct once per [Database] handle on `memory.db`; reuse for
/// every centroid read or write that connection performs. The store
/// is stateless across calls — every read goes to SQLite, every write
/// is a single upsert statement — so it is safe to share between
/// callers on a single connection.
///
/// Thread / isolate safety: inherits the `Database` handle's
/// single-threaded-owner rule, same as the rest of Phase A's
/// `memory.db` store classes.
final class CentroidStore {
  /// Namespace prefix for `NodeType` centroid keys
  /// (`'NodeType:Question'`, `'NodeType:Claim'`, …). Public so
  /// callers can build prefix filters against [listKeys] without
  /// repeating the string.
  static const String nodeTypeKeyPrefix = 'NodeType:';

  /// Namespace prefix for `Procedure` centroid keys
  /// (`'Procedure:research_v1'`, …).
  static const String procedureKeyPrefix = 'Procedure:';

  /// Builds the canonical centroid key for a node type. Use this at
  /// every call site rather than concatenating by hand — a typo in
  /// the prefix would silently put the row in the wrong namespace.
  static String keyForNodeType(String typeName) {
    if (typeName.isEmpty) {
      throw ArgumentError.value(
        typeName,
        'typeName',
        'CentroidStore.keyForNodeType: typeName must be non-empty',
      );
    }
    return '$nodeTypeKeyPrefix$typeName';
  }

  /// Builds the canonical centroid key for a procedure id.
  static String keyForProcedure(String procedureId) {
    if (procedureId.isEmpty) {
      throw ArgumentError.value(
        procedureId,
        'procedureId',
        'CentroidStore.keyForProcedure: procedureId must be non-empty',
      );
    }
    return '$procedureKeyPrefix$procedureId';
  }

  /// Returns the [ClassificationTarget] a [forKey] belongs to, or
  /// `null` when the key carries no recognised namespace.
  ///
  /// Used by the classifier (A.64) and by `findUncertain` (A.65) to
  /// partition the centroid table by target without re-walking the
  /// strings.
  static ClassificationTarget? targetOfKey(String forKey) {
    if (forKey.startsWith(nodeTypeKeyPrefix)) {
      return ClassificationTarget.nodeType;
    }
    if (forKey.startsWith(procedureKeyPrefix)) {
      return ClassificationTarget.procedure;
    }
    return null;
  }

  /// Default cosine-similarity cutoff for `CentroidDriftDetected`
  /// emission. A new centroid with `cosine(prior, new) < this` and a
  /// prior `example_count >= defaultDriftMinPreviousExamples` is
  /// considered drifted. See Q-A.69.2 for the value rationale.
  static const double defaultDriftCosineThreshold = 0.85;

  /// Default floor for prior-row `example_count` before drift is
  /// considered. Avoids treating cold-start jitter (a centroid built
  /// from a handful of examples) as drift.
  static const int defaultDriftMinPreviousExamples = 8;

  final Database _db;
  final Clock _clock;
  final void Function(MemoryEvent)? _eventSink;
  final double _driftCosineThreshold;
  final int _driftMinPreviousExamples;

  /// Constructs a store over [memoryDb] using [clock] for
  /// `updated_at` stamps.
  ///
  /// Production passes `const SystemClock()`; tests inject
  /// [FixedClock] or [MutableTestClock] so the row's `updated_at`
  /// can be asserted exactly.
  ///
  /// `eventSink` is optional — when non-null, every [update] that
  /// crosses the drift threshold (or changes embedding model id)
  /// emits a [CentroidDriftDetected] shaking event onto it. The
  /// concrete `SqliteTomBrainMemory` wires this to the same
  /// `StreamController` that backs `TomBrainMemory.events()`; tests
  /// pass a list-backed sink to inspect emissions.
  ///
  /// `driftCosineThreshold` defaults to [defaultDriftCosineThreshold]
  /// (`0.85`); `driftMinPreviousExamples` defaults to
  /// [defaultDriftMinPreviousExamples] (`8`). Both are carried in
  /// every emitted [CentroidDriftDetected] so subscribers can
  /// correlate threshold tuning with shaking-event volume.
  CentroidStore({
    required Database memoryDb,
    required Clock clock,
    void Function(MemoryEvent)? eventSink,
    double driftCosineThreshold = defaultDriftCosineThreshold,
    int driftMinPreviousExamples = defaultDriftMinPreviousExamples,
  })  : _db = memoryDb,
        _clock = clock,
        _eventSink = eventSink,
        _driftCosineThreshold = driftCosineThreshold,
        _driftMinPreviousExamples = driftMinPreviousExamples {
    if (driftCosineThreshold < -1.0 || driftCosineThreshold > 1.0) {
      throw ArgumentError.value(
        driftCosineThreshold,
        'driftCosineThreshold',
        'CentroidStore: driftCosineThreshold must be in [-1.0, 1.0]',
      );
    }
    if (driftMinPreviousExamples < 0) {
      throw ArgumentError.value(
        driftMinPreviousExamples,
        'driftMinPreviousExamples',
        'CentroidStore: driftMinPreviousExamples must be >= 0',
      );
    }
  }

  /// Upserts the centroid row for [forKey].
  ///
  /// Contract (spec § 7.3):
  ///
  ///   * Wholesale replacement — every field except `for_key` is
  ///     overwritten. Use [CentroidRecord] for the input; the row's
  ///     [CentroidRecord.updatedAt] is **ignored** because the store
  ///     stamps `updated_at` from its own clock so the on-disk value
  ///     is monotonic with the writing clock, not with whatever the
  ///     caller computed.
  ///   * [exampleCount] must be non-negative. Negative counts have
  ///     no meaning and are most likely a producer bug.
  ///   * [forKey] must be non-empty.
  ///   * `embedding_model_id` must be non-empty. A blank model id
  ///     would break the future re-embed migration check.
  ///
  /// Returns the stamped [CentroidRecord] that now lives in the
  /// table — same as a subsequent [read] would return — so callers
  /// (chiefly `dream_recentroid_v1`) can echo the stamped form into
  /// their trail without an extra round-trip.
  ///
  /// `scope` is optional and only used to propagate `runId` /
  /// `causedBy` onto any emitted [CentroidDriftDetected] event so the
  /// dispatcher's trace stitcher can correlate the drift signal back
  /// to the run (typically a `dream_recentroid_v1` run) that produced
  /// it. Passing `null` is legal — the event is still emitted, just
  /// without run-correlation metadata.
  CentroidRecord update({
    required String forKey,
    required String embeddingModelId,
    required Vec centroid,
    required int exampleCount,
    Scope? scope,
  }) {
    if (forKey.isEmpty) {
      throw ArgumentError.value(
        forKey,
        'forKey',
        'CentroidStore.update: forKey must be non-empty',
      );
    }
    if (embeddingModelId.isEmpty) {
      throw ArgumentError.value(
        embeddingModelId,
        'embeddingModelId',
        'CentroidStore.update: embeddingModelId must be non-empty',
      );
    }
    if (exampleCount < 0) {
      throw ArgumentError.value(
        exampleCount,
        'exampleCount',
        'CentroidStore.update: exampleCount must be >= 0',
      );
    }

    // A.69 — read the prior row BEFORE the upsert so we can compute
    // the drift signal against the pre-update centroid. The `ON
    // CONFLICT DO UPDATE` in the next statement rewrites the row
    // wholesale, so any prior state has to be captured up front.
    final prior = read(forKey);

    final updatedAt = BrainTime.now(_clock);
    final blob = centroid.toBlob();
    final dims = centroid.dimension;

    // `INSERT … ON CONFLICT(for_key) DO UPDATE` is the right idiom
    // here: one statement, no read-then-write race, transparently
    // upserts whether or not a prior row exists. The whole row is
    // rewritten because a stale `embedding_model_id` or
    // `example_count` paired with a fresh blob would be a
    // correctness bug — see the file header on wholesale-replacement.
    _db.execute(
      'INSERT INTO centroids '
      '(for_key, embedding_model_id, centroid_blob, '
      'centroid_dims, example_count, updated_at_ms, updated_at_iso) '
      'VALUES (?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(for_key) DO UPDATE SET '
      'embedding_model_id = excluded.embedding_model_id, '
      'centroid_blob = excluded.centroid_blob, '
      'centroid_dims = excluded.centroid_dims, '
      'example_count = excluded.example_count, '
      'updated_at_ms = excluded.updated_at_ms, '
      'updated_at_iso = excluded.updated_at_iso',
      <Object?>[
        forKey,
        embeddingModelId,
        blob,
        dims,
        exampleCount,
        updatedAt.toMs(),
        updatedAt.toIso8601String(),
      ],
    );

    // A.69 — drift detection. Three cases:
    //
    //   1. No prior row (first-ever update for this key) — emit nothing.
    //      There is nothing to compare; emitting on every cold-start
    //      would drown the shaking-event stream in noise.
    //   2. Model-id change between prior and new — emit unconditionally
    //      with `cosineSimilarity: null`. A different embedding model
    //      produces incommensurable vectors, so the cosine cutoff is
    //      bypassed; the only correct downstream reaction is a
    //      re-embed migration.
    //   3. Same model AND prior.exampleCount >= _driftMinPreviousExamples
    //      AND cosine(prior, new) < _driftCosineThreshold — emit with
    //      the measured cosine. The example-count floor avoids treating
    //      cold-start jitter as drift.
    //
    // Anything else: the centroid moved, but not beyond the configured
    // tolerance — no emission.
    _maybeEmitDrift(
      forKey: forKey,
      embeddingModelId: embeddingModelId,
      newCentroid: centroid,
      newExampleCount: exampleCount,
      prior: prior,
      occurredAt: updatedAt.toDateTime(),
      scope: scope,
    );

    // Spec § 16 — `CentroidUpdated` is the unconditional audit of
    // every successful upsert (distinct from the conditional
    // `CentroidDriftDetected` above). `created` is derived from the
    // prior read: no prior row ⇒ this upsert inserted a fresh one.
    final sink = _eventSink;
    if (sink != null) {
      sink(
        CentroidUpdated(
          forKey: forKey,
          embeddingModelId: embeddingModelId,
          exampleCount: exampleCount,
          dimensions: dims,
          created: prior == null,
          occurredAt: updatedAt.toDateTime(),
          runId: scope?.runId,
          causedBy: scope?.causedBy,
        ),
      );
    }

    return CentroidRecord(
      forKey: forKey,
      embeddingModelId: embeddingModelId,
      centroid: centroid,
      exampleCount: exampleCount,
      updatedAt: updatedAt,
    );
  }

  /// Internal: detect drift between [prior] and the freshly-written
  /// centroid, and emit [CentroidDriftDetected] when warranted.
  ///
  /// See the file header (`What this file owns since A.69`) for the
  /// decision table. Short-circuits when no `_eventSink` is wired so
  /// the cosine computation only runs when a subscriber is listening.
  void _maybeEmitDrift({
    required String forKey,
    required String embeddingModelId,
    required Vec newCentroid,
    required int newExampleCount,
    required CentroidRecord? prior,
    required DateTime occurredAt,
    required Scope? scope,
  }) {
    final sink = _eventSink;
    if (sink == null) return;
    if (prior == null) return;

    final modelChanged = prior.embeddingModelId != embeddingModelId;
    if (modelChanged) {
      sink(
        CentroidDriftDetected(
          forKey: forKey,
          embeddingModelId: embeddingModelId,
          previousEmbeddingModelId: prior.embeddingModelId,
          exampleCount: newExampleCount,
          previousExampleCount: prior.exampleCount,
          cosineSimilarity: null,
          driftCosineThreshold: _driftCosineThreshold,
          occurredAt: occurredAt,
          runId: scope?.runId,
          causedBy: scope?.causedBy,
        ),
      );
      return;
    }

    if (prior.exampleCount < _driftMinPreviousExamples) return;
    if (prior.centroid.dimension != newCentroid.dimension) {
      // Same model but different dimension — defensive: cosine would
      // throw. Treat as drift; carry cosine=null so subscribers can
      // tell this from a normal cosine-cutoff drift.
      sink(
        CentroidDriftDetected(
          forKey: forKey,
          embeddingModelId: embeddingModelId,
          previousEmbeddingModelId: prior.embeddingModelId,
          exampleCount: newExampleCount,
          previousExampleCount: prior.exampleCount,
          cosineSimilarity: null,
          driftCosineThreshold: _driftCosineThreshold,
          occurredAt: occurredAt,
          runId: scope?.runId,
          causedBy: scope?.causedBy,
        ),
      );
      return;
    }

    final c = cosine(prior.centroid, newCentroid);
    if (c < _driftCosineThreshold) {
      sink(
        CentroidDriftDetected(
          forKey: forKey,
          embeddingModelId: embeddingModelId,
          previousEmbeddingModelId: prior.embeddingModelId,
          exampleCount: newExampleCount,
          previousExampleCount: prior.exampleCount,
          cosineSimilarity: c,
          driftCosineThreshold: _driftCosineThreshold,
          occurredAt: occurredAt,
          runId: scope?.runId,
          causedBy: scope?.causedBy,
        ),
      );
    }
  }

  /// Returns the centroid row for [forKey], or `null` when no row
  /// exists for that key.
  ///
  /// "No row" is the cold-start case the classifier (A.64) returns
  /// as [ClassificationDecision.unknown]; the storage layer
  /// represents it as `null` rather than throwing because absence is
  /// a perfectly legitimate state for a freshly-booted memory.
  CentroidRecord? read(String forKey) {
    final rows = _db.select(
      'SELECT embedding_model_id, centroid_blob, centroid_dims, '
      'example_count, updated_at_ms '
      'FROM centroids WHERE for_key = ? LIMIT 1',
      <Object?>[forKey],
    );
    if (rows.isEmpty) {
      return null;
    }
    return _rowToRecord(forKey, rows.first);
  }

  /// Lists every centroid key currently in the table, optionally
  /// filtered by [prefix] (e.g. [nodeTypeKeyPrefix] /
  /// [procedureKeyPrefix]).
  ///
  /// Order is `for_key` ascending so callers that iterate get a
  /// stable sequence across calls. The classifier (A.64) only ever
  /// needs the prefix-filtered shape; passing the full prefix
  /// (rather than building two separate queries) keeps the SQL
  /// surface flat.
  List<String> listKeys({String? prefix}) {
    final ResultSet rows;
    if (prefix == null) {
      rows = _db.select(
        'SELECT for_key FROM centroids ORDER BY for_key ASC',
      );
    } else {
      // `LIKE ? ESCAPE '\\'` plus a manual escape on `%` / `_`
      // would over-engineer this — the only prefixes used in
      // practice are the public constants `'NodeType:'` and
      // `'Procedure:'`, neither of which contains LIKE wildcards.
      // A simple `LIKE` is therefore both safe and the clearest
      // statement of intent.
      rows = _db.select(
        'SELECT for_key FROM centroids '
        "WHERE for_key LIKE ? || '%' "
        'ORDER BY for_key ASC',
        <Object?>[prefix],
      );
    }
    return rows.map((row) => row['for_key'] as String).toList(growable: false);
  }

  /// Total number of centroid rows. Diagnostic helper for tests and
  /// operators; not on a hot path.
  int count() {
    final row = _db.select('SELECT COUNT(*) AS c FROM centroids').first;
    return row['c'] as int;
  }

  /// Reads every centroid row in [prefix]'s namespace and returns
  /// the full records. Used by the A.64 classifier to compare the
  /// query vector against every candidate centroid for the chosen
  /// [ClassificationTarget].
  ///
  /// Order: `for_key` ascending, same as [listKeys]. The classifier
  /// does not care about order — it picks best and second by score
  /// — but a stable order keeps test assertions deterministic.
  List<CentroidRecord> readAll({String? prefix}) {
    final ResultSet rows;
    if (prefix == null) {
      rows = _db.select(
        'SELECT for_key, embedding_model_id, centroid_blob, '
        'centroid_dims, example_count, updated_at_ms '
        'FROM centroids ORDER BY for_key ASC',
      );
    } else {
      rows = _db.select(
        'SELECT for_key, embedding_model_id, centroid_blob, '
        'centroid_dims, example_count, updated_at_ms '
        'FROM centroids '
        "WHERE for_key LIKE ? || '%' "
        'ORDER BY for_key ASC',
        <Object?>[prefix],
      );
    }
    return rows
        .map((row) => _rowToRecord(row['for_key'] as String, row))
        .toList(growable: false);
  }

  CentroidRecord _rowToRecord(String forKey, Row row) {
    final blob = row['centroid_blob'] as Uint8List;
    final dims = row['centroid_dims'] as int;
    final centroid = Vec.fromBlob(blob);
    if (centroid.dimension != dims) {
      // Defensive — the dims column and the blob length should
      // always agree because [update] derives both from the same
      // `Vec`. A divergence here would mean someone wrote to the
      // table outside this store (e.g. an ad-hoc migration script).
      // We surface it instead of silently trusting the blob, so the
      // operator sees the drift rather than a downstream classifier
      // producing nonsense scores.
      throw StateError(
        'CentroidStore: centroid_dims ($dims) does not match '
        'blob-decoded dimension (${centroid.dimension}) for $forKey',
      );
    }
    return CentroidRecord(
      forKey: forKey,
      embeddingModelId: row['embedding_model_id'] as String,
      centroid: centroid,
      exampleCount: row['example_count'] as int,
      updatedAt: BrainTime.fromMs(row['updated_at_ms'] as int),
    );
  }
}
