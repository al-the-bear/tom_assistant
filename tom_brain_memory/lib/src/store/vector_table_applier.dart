// VectorTableApplier — the production `VectorApplier` implementation
// that bridges the two-DB coordinator's WAL-side payload into the
// `vectors.db`-side per-model index (Plan step A.52).
//
// Plan step A.52:
//   "Wire the two-DB transaction coordinator into `persist` for
//    nodes with embedding fields."
//
// ─────────────────────────────────────────────────────────────────────
// Where this fits
// ─────────────────────────────────────────────────────────────────────
//
// The persister already routes through the coordinator (A.34 — see
// `node_persister.dart` line 191). The coordinator already enqueues
// `pending_vector_writes` rows and calls `applier.apply(write)` after
// commit (A.30 — see `two_db_coordinator.dart` line 397). The vector
// table already accepts `(nodeId, vector, modelId)` and writes into
// the per-model physical table (A.51 — see `vector_table.dart`
// line 667).
//
// What was missing was the **production** `VectorApplier`. Until A.52
// the only `VectorApplier` implementations were in-test fakes (the
// `_RecordingVectorApplier` in `node_persister_test.dart` and the
// `_FakeVectorApplier` in `two_db_coordinator_test.dart`). The wiring
// from `persist()` to a real `vectors.db` was open at the applier
// boundary.
//
// This file closes that boundary with a one-screen adapter:
//
//   Persister.persist(NodeDraft+Vec)
//     └─> TwoDbCoordinator.persistNodeWithVector(...,vector: payload)
//           └─> BEGIN memory.db
//           │   - INSERT INTO nodes
//           │   - INSERT INTO pending_vector_writes (payload_blob,
//           │                                        embedding_model_id)
//           │   - COMMIT memory.db
//           └─> applier.apply(write)             ← THIS FILE
//                 ├─ Vec.fromBlob(payload_blob)  (typed reconstruction)
//                 └─ VectorTable.insertVector(
//                       nodeId, vector, modelId)
//                       └─> Vec0VirtualTableBackend.insertRow(...)
//                           — or, in tests:
//                       └─> PlainBlobTableBackend.insertRow(...)
//           └─> DELETE FROM pending_vector_writes WHERE node_id = ?
//
// ─────────────────────────────────────────────────────────────────────
// Why an adapter, not a coordinator hook
// ─────────────────────────────────────────────────────────────────────
//
// The coordinator deliberately does not depend on `vectors.db`, on
// `VectorTable`, or on sqlite-vec (A.30 file header). That decoupling
// is what lets the same coordinator serve production (this adapter),
// tests (the recording / fake appliers), and the future read-replica
// topology (a mirror-only applier that ships the blob downstream
// without writing locally — spec § 10.2).
//
// The adapter pattern preserves that: every applier consumes a
// `PendingVectorWrite` (the storage-protocol value type) and is free
// to do whatever its concrete role calls for. The production role is
// "write the vector to the per-model index"; this class is exactly
// that.
//
// ─────────────────────────────────────────────────────────────────────
// Idempotency
// ─────────────────────────────────────────────────────────────────────
//
// The `VectorApplier` contract (`two_db_coordinator.dart`
// line 198-200) requires `apply` to be idempotent so the recovery
// path can replay. This adapter delegates idempotency to
// `VectorTable.insertVector`, which both ship backends implement via
// `INSERT … ON CONFLICT(node_id) DO UPDATE SET embedding = excluded
// .embedding` (`vector_table.dart` lines 315-319 for vec0, lines
// 398-404 for plain). A replayed `apply(write)` with the same
// `(nodeId, modelId)` overwrites; the final state converges
// regardless of how many times the recovery loop runs.
//
// ─────────────────────────────────────────────────────────────────────
// Failure surfacing
// ─────────────────────────────────────────────────────────────────────
//
// The adapter does **not** translate or swallow exceptions. The
// `VectorTable.insertVector` path raises three categorised failures
// (`EmbeddingModelMismatch`, `EmbeddingDimsMismatch`, plus
// `ArgumentError` for caller-supplied invariants) plus arbitrary
// `SqliteException`s for storage-level problems; the adapter lets
// them propagate.
//
// The coordinator's call sites handle the propagation:
//
//   * `persistNodeWithVector` (line 397): rethrows the applier
//     exception to the caller. The pending row stays committed so the
//     next `recoverPending` can converge. This is the spec § 2.4
//     contract — a missing vector with the node visible is the
//     conservative branch (re-apply on next boot) over the
//     alternative (delete the node, which would lose the row).
//
//   * `recoverPending` (line 434-446): aggregates the per-row failure
//     into `TwoDbReplayReport.failures`, leaves the pending row, and
//     continues with the next row. The next call to `recoverPending`
//     re-tries.
//
// Either way the pending row is the recovery trace; the adapter
// never short-circuits the protocol.
//
// ─────────────────────────────────────────────────────────────────────
// Why this is a class and not a free function
// ─────────────────────────────────────────────────────────────────────
//
// The adapter holds one collaborator (the `VectorTable`) that the
// coordinator never sees. The `VectorApplier` contract is an
// abstract interface (so the coordinator can take any applier),
// which forces an implementing type. A free function with a closure
// would technically work, but it would prevent the adapter from
// being constructed with named arguments (the workspace style — see
// `NodePersister`, `TwoDbCoordinator`, `VectorTable` all use
// `required` named ctor parameters) and would require a different
// shape from every other A.30+ collaborator. The class form keeps
// the construction site uniform.

import 'package:tom_brain_shared/tom_brain_shared.dart' show Vec;

import 'two_db_coordinator.dart';
import 'vector_table.dart';

/// Production [VectorApplier] backed by a [VectorTable].
///
/// Construct one per process per `vectors.db` handle. The adapter is
/// stateless across calls — the state lives in the [VectorTable] and
/// in `pending_vector_writes`.
///
/// Wiring (assembled by the future `SqliteTomBrainMemory.open()`):
///
/// ```dart
/// final vectorsDb = sqlite3.open('<root>/vectors.db');
/// final vectorTable = VectorTable(
///   vectorsDb: vectorsDb,
///   backend: const Vec0VirtualTableBackend(), // or PlainBlobTableBackend()
///   clock: const SystemClock(),
/// );
/// for (final model in configuredEmbeddingModels) {
///   vectorTable.installIndex(modelId: model.id, dims: model.dims);
/// }
/// final applier = VectorTableApplier(vectorTable: vectorTable);
/// final coordinator = TwoDbCoordinator(
///   memoryDb: memoryDb,
///   applier: applier,
///   clock: const SystemClock(),
/// );
/// // → coordinator can now back `NodePersister.persist`.
/// ```
///
/// Today the adapter is consumed by the A.52 integration tests
/// directly; the production assembly arrives with the concrete
/// `SqliteTomBrainMemory.open()` at A.28+ (which will pick the
/// backend per spec § 2.1 — `Vec0VirtualTableBackend` when
/// `loadVecExtensionWithFailOpen` returns `loaded`, `PlainBlobTableBackend`
/// otherwise — and install indexes for every model in the substrate
/// configuration).
final class VectorTableApplier implements VectorApplier {
  /// The per-model vector table that owns `vectors.db`.
  final VectorTable _vectorTable;

  /// Constructs an applier over [vectorTable].
  ///
  /// The adapter does not take ownership of [vectorTable] — closing
  /// the underlying database is the caller's responsibility (and per
  /// `VectorTable`'s own header comment, `vectors.db` is owned by the
  /// store opener).
  VectorTableApplier({required VectorTable vectorTable})
      : _vectorTable = vectorTable;

  /// Applies one pending vector write to the per-model index.
  ///
  /// Decodes [write].`payloadBlob` (little-endian float32 — the wire
  /// format `Vec.toBlob` writes and `Vec.fromBlob` reads) and calls
  /// `VectorTable.insertVector(nodeId, vector, modelId)`. The
  /// `insertVector` call is idempotent; a replayed write under the
  /// same `(modelId, nodeId)` overwrites.
  ///
  /// Throws on any of:
  ///
  ///   * `ArgumentError` — `payloadBlob` is empty or its length is
  ///     not a multiple of 4 (i.e. the WAL row is corrupt or was
  ///     written under a non-float32 wire format).
  ///   * `EmbeddingModelMismatch` — no index is installed for
  ///     `write.embeddingModelId`. The conservative branch: do not
  ///     auto-install (the install policy is an operator decision per
  ///     `VectorTable.installIndex` doc).
  ///   * `EmbeddingDimsMismatch` — the decoded vector's dimensionality
  ///     does not match the installed index's dimensionality. This
  ///     can only happen when the substrate config diverged from the
  ///     installed index (e.g. an operator changed the configured
  ///     model dim without re-running the install).
  ///   * `SqliteException` — propagated from the underlying backend
  ///     (disk full, lock contention, etc.).
  ///
  /// Every failure leaves the pending row in `memory.db` so the
  /// `recoverPending` path can re-try after the operator addresses
  /// the cause.
  @override
  void apply(PendingVectorWrite write) {
    final vector = Vec.fromBlob(write.payloadBlob);
    _vectorTable.insertVector(
      nodeId: write.nodeId,
      vector: vector,
      modelId: write.embeddingModelId,
    );
  }
}
