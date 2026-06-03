// TwoDbCoordinator — coordinates writes across `memory.db` and
// `vectors.db` so that a crash between the two stores is detectable
// and replayable.
//
// Plan step A.30:
//   "Implement two-database transaction coordinator
//    (`pending_vector_writes` table). Cover crash-between-writes
//    scenario in a test."
//
// Spec § 2.4 (Transactions):
//   "Every node write is a single SQL transaction across `memory.db`
//    (the row) and `vectors.db` (its vectors, when applicable). The
//    two-database commit is coordinated by a small WAL-like log in
//    `memory.db` (`pending_vector_writes` table) so that a crash
//    between the two writes is detectable and replayable."
//
// ─────────────────────────────────────────────────────────────────────
// Protocol
// ─────────────────────────────────────────────────────────────────────
//
// SQLite has no native cross-database transactions and no two-phase
// commit. The only crash-safe pattern across two independent SQLite
// files is a write-ahead log in one of them. Memory's WAL is the
// `pending_vector_writes` table: the row carries enough payload that
// the vector write can be redone after a crash without consulting any
// other source.
//
// Write protocol for `persistNodeWithVector`:
//
//   1. `BEGIN` on `memory.db`.
//   2. The caller-supplied `writeNode(db)` callback runs inside the
//      transaction (INSERT into `nodes`, edges, etc.).
//   3. If a vector payload was supplied, INSERT a row into
//      `pending_vector_writes` keyed by `node_id`.
//   4. `COMMIT` on `memory.db`. From this point the node exists; the
//      vector is "promised but not yet visible".
//   5. If a vector payload was supplied, call `applier.apply(write)`
//      to write it to `vectors.db`. The applier *must* be idempotent —
//      see [VectorApplier].
//   6. After the applier returns, DELETE the pending row in its own
//      tiny transaction. The pending row is the trace; absence means
//      "fully durable in both stores".
//
// Crash analysis (the only thing this class exists for):
//
//   * Crash before step 4 (memory.db not yet committed):
//       Both stores untouched. The node never existed. Recovery is
//       trivial — there is nothing to recover.
//
//   * Crash between step 4 and step 6 (memory.db committed, vectors.db
//     not yet visible or pending row not yet deleted):
//       The node row exists in `memory.db`. The
//       `pending_vector_writes` row exists in `memory.db`. The vector
//       may or may not be in `vectors.db`. Recovery: `recoverPending`
//       re-applies via the (idempotent) applier and deletes the
//       pending row. Whether the vector was already partially written
//       does not matter — the applier converges either way.
//
//   * Crash after step 6 (pending row already deleted):
//       Both stores consistent. Nothing to recover.
//
// What the coordinator deliberately does *not* do:
//
//   * Open / own `vectors.db`. The vector store is owned by A.50+
//     (sqlite-vec integration). The coordinator interacts with it
//     solely through the injected [VectorApplier]. This keeps A.30
//     free of any sqlite-vec dependency and lets the same coordinator
//     drive a fake applier in tests, a real one in production, and a
//     mirror-only applier on read-replica nodes (spec § 10).
//
//   * Stack mutations or trail writes. Per spec § 2.4 those are
//     single-database concerns (memory.db alone for stacks; JSONL +
//     index row for trails). The coordinator's surface is the
//     specifically-two-database node-with-vector path.
//
//   * Async I/O. Both `sqlite3` and the contemplated sqlite-vec
//     binding are synchronous; making the coordinator async would
//     introduce a `Future` boundary purely for cosmetic symmetry with
//     the eventual isolate adapter (A.85+). The adapter is the right
//     place to add async; the coordinator stays synchronous so the
//     transaction lifecycle is unmistakably local.
//
// Why the coordinator is its own class and not a free function:
//
//   The clock, the applier, and the connection are all per-instance
//   collaborators. Tests build a coordinator with a fake applier and
//   a `FixedClock`; production builds one with the real applier and a
//   `SystemClock`. A free function would have to take all three
//   parameters at every call site, and crash-recovery (`recoverPending`)
//   would still need a "context object" — the class is that object.

import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:tom_core_agentic/tom_core_agentic.dart' show blobFromColumn;
import 'package:tom_brain_shared/tom_brain_shared.dart';

import 'transaction_support.dart';

/// The vector half of a pending two-DB write.
///
/// Owned exclusively by [TwoDbCoordinator]. Carries every byte needed
/// to re-apply the write after a crash — the coordinator never reaches
/// back to recompute or re-fetch the payload.
///
/// `payloadBlob` is the on-the-wire form of the vector: little-endian
/// `Float32` values, length `payloadDims * 4` bytes. The choice mirrors
/// `Vec.toFloat32Bytes()` from `tom_brain_shared` (A.11) and matches
/// the row layout `schema_v1.dart` declared for
/// `pending_vector_writes`. The coordinator does *not* validate that
/// the blob is well-formed — that is the embedding subsystem's
/// contract, and the coordinator is just a transport.
final class PendingVectorWritePayload {
  /// The embedding model id this vector was produced under. Stored
  /// alongside the blob so a mid-flight re-embed migration can detect
  /// stale pending writes (spec § 15 "Embedding-model mismatch").
  final String embeddingModelId;

  /// Raw vector bytes; see class header for layout.
  final Uint8List payloadBlob;

  /// Vector dimensionality. `payloadBlob.length == payloadDims * 4`
  /// for the canonical float32 form; the coordinator does not assert
  /// this so it can carry future widths (float16 / int8) without
  /// rewiring.
  final int payloadDims;

  const PendingVectorWritePayload({
    required this.embeddingModelId,
    required this.payloadBlob,
    required this.payloadDims,
  });

  @override
  String toString() => 'PendingVectorWritePayload('
      'model: $embeddingModelId, dims: $payloadDims, '
      'bytes: ${payloadBlob.length})';
}

/// A row read back from `pending_vector_writes` during recovery.
///
/// Adds the `nodeId` and `enqueuedAt` fields that the coordinator
/// stamps on insert. Tests and operator dumps read instances; the
/// coordinator itself only constructs them.
final class PendingVectorWrite {
  /// Node id this write belongs to. Primary key in the table.
  final String nodeId;

  /// Embedding model that produced [payloadBlob].
  final String embeddingModelId;

  /// Raw vector bytes; same layout as [PendingVectorWritePayload].
  final Uint8List payloadBlob;

  /// Vector dimensionality.
  final int payloadDims;

  /// When the coordinator enqueued this row (memory.db `BEGIN` time on
  /// the originating write).
  final BrainTime enqueuedAt;

  const PendingVectorWrite({
    required this.nodeId,
    required this.embeddingModelId,
    required this.payloadBlob,
    required this.payloadDims,
    required this.enqueuedAt,
  });

  @override
  String toString() => 'PendingVectorWrite('
      'node: $nodeId, model: $embeddingModelId, dims: $payloadDims, '
      'enqueued: ${enqueuedAt.toIso8601String()})';
}

/// The vectors-store side of the two-DB protocol.
///
/// Implementations write a vector into `vectors.db`. The contract has
/// two non-negotiable obligations:
///
///   1. **Idempotent.** Replay calls [apply] with the same
///      [PendingVectorWrite] payload again. The applier *must*
///      converge — either by upsert (REPLACE INTO …) or by an explicit
///      "does this row already exist?" probe. A non-idempotent applier
///      is a correctness bug at the recovery layer.
///   2. **Durable on return.** When [apply] returns normally, the
///      vector is committed to `vectors.db` and survives a crash.
///      Asynchronous "I scheduled this" semantics break the
///      [TwoDbCoordinator] crash analysis (the coordinator deletes the
///      pending row immediately on return).
///
/// Failure model: [apply] throws when the write cannot be completed.
/// The coordinator translates this differently on the two paths:
///
///   * `persistNodeWithVector`: leaves the pending row in place,
///     surfaces the exception to the caller. The next call to
///     [TwoDbCoordinator.recoverPending] will retry.
///   * `recoverPending`: aggregates the failure into the returned
///     [TwoDbReplayReport] and continues with the remaining rows. The
///     pending row stays so a subsequent run can replay it.
///
/// A.50+ provides the production implementation (sqlite-vec). Until
/// then this is a pure abstraction and tests inject in-memory fakes.
abstract interface class VectorApplier {
  /// Writes [write] to `vectors.db`. Must be idempotent and durable
  /// on return. Throws on unrecoverable failure.
  void apply(PendingVectorWrite write);
}

/// A single per-row failure observed during [TwoDbCoordinator.recoverPending].
///
/// Captures the node id so operators can target a fix at the
/// originating write, and the original error / stack trace so the
/// applier's failure mode is auditable.
final class TwoDbReplayFailure {
  /// Node whose pending vector write could not be replayed.
  final String nodeId;

  /// The exception the applier raised.
  final Object error;

  /// Stack trace captured at the failure site. Always present so the
  /// failure record is self-contained for after-the-fact analysis.
  final StackTrace stackTrace;

  const TwoDbReplayFailure({
    required this.nodeId,
    required this.error,
    required this.stackTrace,
  });

  @override
  String toString() => 'TwoDbReplayFailure(node: $nodeId, error: $error)';
}

/// Outcome of one call to [TwoDbCoordinator.recoverPending].
///
/// Always returned even when no rows were pending (the empty report
/// is `scanned == 0`). Callers — chiefly the eventual store-opener
/// boot path — read [failures] to decide whether to emit a degraded-
/// mode event or to retry later.
final class TwoDbReplayReport {
  /// Number of rows the coordinator read from `pending_vector_writes`
  /// at the start of this recovery pass. Equals
  /// `succeeded + failures.length`.
  final int scanned;

  /// Number of rows the applier accepted and the coordinator deleted.
  final int succeeded;

  /// Per-row failures, in the order they were observed.
  final List<TwoDbReplayFailure> failures;

  /// Wall-clock UTC at which recovery started. Captured before the
  /// first row is read.
  final BrainTime startedAt;

  /// Wall-clock UTC at which recovery finished. Captured after the
  /// final row was processed (or immediately, for empty reports).
  final BrainTime finishedAt;

  TwoDbReplayReport({
    required this.scanned,
    required this.succeeded,
    required List<TwoDbReplayFailure> failures,
    required this.startedAt,
    required this.finishedAt,
  }) : failures = List.unmodifiable(failures);

  /// `true` iff at least one pending row failed to replay.
  bool get hasFailures => failures.isNotEmpty;

  /// `true` iff no pending rows were observed.
  bool get isEmpty => scanned == 0;

  /// `true` iff at least one row was processed (success or failure).
  bool get didProcessAny => scanned > 0;

  /// The wall-clock duration of the recovery pass.
  Duration get duration => finishedAt.toDateTime().difference(
        startedAt.toDateTime(),
      );

  @override
  String toString() => 'TwoDbReplayReport('
      'scanned: $scanned, succeeded: $succeeded, '
      'failed: ${failures.length})';
}

/// Two-database (memory.db + vectors.db) write coordinator.
///
/// Construct once per [Database] handle on `memory.db`; reuse for
/// every node-with-vector write that connection performs. The
/// coordinator is stateless across calls (the state lives in the
/// `pending_vector_writes` table) so it is safe to share between
/// callers on a single connection.
///
/// Thread / isolate safety: the coordinator inherits the host
/// `Database` handle's threading model. The `sqlite3` Dart package
/// requires a single-threaded owner per handle; same goes here. The
/// isolate-adapter step (A.85+) will introduce the cross-isolate
/// boundary if needed.
final class TwoDbCoordinator {
  final Database _memoryDb;
  final VectorApplier _applier;
  final Clock _clock;

  /// Constructs a coordinator over [memoryDb] using [applier] for the
  /// vectors-store side.
  ///
  /// [clock] is the time source for `enqueuedAt` stamps and recovery
  /// report timestamps. Production passes `const SystemClock()`;
  /// tests pin time via [FixedClock] or [MutableTestClock].
  TwoDbCoordinator({
    required Database memoryDb,
    required VectorApplier applier,
    required Clock clock,
  })  : _memoryDb = memoryDb,
        _applier = applier,
        _clock = clock;

  /// Persists a node and, when [vector] is non-null, the associated
  /// vector across both databases.
  ///
  /// Protocol (full discussion in the file header):
  ///
  ///   1. `BEGIN` on `memory.db`.
  ///   2. Run [writeNode] (inserts the node row, edges, etc.).
  ///   3. If [vector] is non-null, INSERT into `pending_vector_writes`.
  ///   4. `COMMIT` on `memory.db`.
  ///   5. If [vector] is non-null, call `applier.apply(...)`.
  ///   6. DELETE the pending row.
  ///
  /// On failure during steps 1–3: `memory.db` is rolled back; nothing
  /// is committed; the applier is not called. The exception
  /// propagates.
  ///
  /// On failure during step 5: the node and the pending row remain
  /// committed; the applier exception propagates. The next call to
  /// [recoverPending] will replay.
  ///
  /// On failure during step 6 (DELETE): the vector is durable but the
  /// pending row remains. The next call to [recoverPending] will
  /// re-apply (idempotently) and re-delete. This is the conservative
  /// branch: a leftover pending row is harmless, a missing vector is
  /// not.
  ///
  /// [nodeId] must be unique across pending rows. Per spec § 9.1 the
  /// idempotency key on `nodes` guarantees one in-flight write per
  /// logical node; the `PRIMARY KEY (node_id)` on
  /// `pending_vector_writes` is the storage-layer expression of the
  /// same invariant. A double-write for the same node-id raises
  /// [SqliteException].
  void persistNodeWithVector({
    required String nodeId,
    required void Function(Database db) writeNode,
    PendingVectorWritePayload? vector,
  }) {
    final enqueuedAt = BrainTime.now(_clock);

    _memoryDb.execute('BEGIN');
    try {
      writeNode(_memoryDb);
      if (vector != null) {
        _memoryDb.execute(
          'INSERT INTO pending_vector_writes '
          '(node_id, embedding_model_id, payload_blob, '
          'payload_dims, enqueued_at_ms, enqueued_at_iso) '
          'VALUES (?, ?, ?, ?, ?, ?)',
          <Object?>[
            nodeId,
            vector.embeddingModelId,
            vector.payloadBlob,
            vector.payloadDims,
            enqueuedAt.toMs(),
            enqueuedAt.toIso8601String(),
          ],
        );
      }
      _memoryDb.execute('COMMIT');
    } catch (error, stack) {
      rollbackQuietly(_memoryDb);
      Error.throwWithStackTrace(error, stack);
    }

    if (vector == null) {
      return;
    }

    final write = PendingVectorWrite(
      nodeId: nodeId,
      embeddingModelId: vector.embeddingModelId,
      payloadBlob: vector.payloadBlob,
      payloadDims: vector.payloadDims,
      enqueuedAt: enqueuedAt,
    );

    // Step 5: apply to vectors.db. If this throws, the pending row is
    // intentionally left in place so recovery can retry.
    _applier.apply(write);

    // Step 6: delete the pending row. A failure here is rare (DELETE
    // by primary key in an already-open SQLite connection), but the
    // contract holds: leaving the row triggers idempotent replay,
    // which converges. We do not swallow — the caller sees the
    // exception and the operator sees the visible drift.
    _memoryDb.execute(
      'DELETE FROM pending_vector_writes WHERE node_id = ?',
      <Object?>[nodeId],
    );
  }

  /// Replays every row currently in `pending_vector_writes`.
  ///
  /// For each row, calls `applier.apply(...)` and on success deletes
  /// the row. Per-row failures are aggregated into the returned
  /// [TwoDbReplayReport]; the recovery pass continues past them so a
  /// single bad row does not block the rest.
  ///
  /// Idempotent: calling on an already-converged DB returns an empty
  /// report (`scanned == 0`). Safe to call at boot and again on
  /// demand (e.g. after the vector store comes back online).
  ///
  /// Ordering: rows are replayed in `enqueued_at_ms` ascending. This
  /// preserves the FIFO of the originating writes, which matters when
  /// an applier is sensitive to write order (the production
  /// sqlite-vec applier is not, but a future replica applier might
  /// be).
  TwoDbReplayReport recoverPending() {
    final startedAt = BrainTime.now(_clock);
    final pending = listPending();
    final failures = <TwoDbReplayFailure>[];
    var succeeded = 0;

    for (final write in pending) {
      try {
        _applier.apply(write);
        _memoryDb.execute(
          'DELETE FROM pending_vector_writes WHERE node_id = ?',
          <Object?>[write.nodeId],
        );
        succeeded++;
      } catch (error, stackTrace) {
        failures.add(TwoDbReplayFailure(
          nodeId: write.nodeId,
          error: error,
          stackTrace: stackTrace,
        ));
      }
    }

    return TwoDbReplayReport(
      scanned: pending.length,
      succeeded: succeeded,
      failures: failures,
      startedAt: startedAt,
      finishedAt: BrainTime.now(_clock),
    );
  }

  /// Lists every row currently in `pending_vector_writes`, ordered
  /// oldest-first.
  ///
  /// Read-only — does not modify the table. Exposed for tests, the
  /// boot integrity check, and operator dumps. The list always
  /// reflects the *current* table contents; the coordinator does not
  /// cache.
  List<PendingVectorWrite> listPending() {
    final rows = _memoryDb.select(
      'SELECT node_id, embedding_model_id, payload_blob, '
      'payload_dims, enqueued_at_ms '
      'FROM pending_vector_writes '
      'ORDER BY enqueued_at_ms ASC, node_id ASC',
    );
    return rows
        .map((row) => PendingVectorWrite(
              nodeId: row['node_id'] as String,
              embeddingModelId: row['embedding_model_id'] as String,
              payloadBlob: blobFromColumn(
                row['payload_blob'],
                context: 'pending_vector_writes.payload_blob',
              ),
              payloadDims: row['payload_dims'] as int,
              enqueuedAt: BrainTime.fromMs(row['enqueued_at_ms'] as int),
            ))
        .toList(growable: false);
  }

  /// Number of pending vector writes currently in the table.
  ///
  /// Convenience around `listPending().length` that avoids
  /// materialising the rows when only the count is needed (the
  /// dispatcher-side preemption checks read this at every yield
  /// point per spec § 16).
  int pendingCount() {
    final rows = _memoryDb.select(
      'SELECT COUNT(*) AS n FROM pending_vector_writes',
    );
    return rows.first['n'] as int;
  }

}
