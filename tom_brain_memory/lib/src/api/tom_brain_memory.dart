// TomBrainMemory — the in-process Dart API for the brain's
// property-graph memory (memory_specification.md § 3.1).
//
// This is the primary surface. Everything else is built on top of
// it:
//
//   * The MCP server (§ 3.2) wraps a strict read-only slice of
//     these methods for cross-process callers.
//   * The procedure-engine bridge (§ 3.3) re-exports the methods
//     as the primitive set d4rt scripts call.
//   * The isolate adapter wraps a `TomBrainMemoryClient`
//     interface around it (A.78) so dispatcher and memory can run
//     in separate isolates without consumer code changes.
//
// A.24 lands the *abstract* class only — no concrete
// implementation. The concrete `SqliteTomBrainMemory` arrives at
// A.28+ once the SQLite schema is in place.

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, TrailId, Vec;

import '../classification/classification_result.dart';
import '../config/memory_config.dart';
import '../edges/edge.dart';
import '../edges/edge_type.dart';
import '../migrations/migration_api.dart';
import '../nodes/node.dart';
import '../nodes/node_type_decl.dart';
import '../retrieval/recall_query.dart';
import '../retrieval/recall_result.dart';
import '../retrieval/stream_query.dart';
import '../stacks/stack_api.dart';
import '../trails/trail.dart';
import 'memory_event.dart';
import 'memory_stats.dart';
import 'scope.dart';

/// The in-process Dart API for the brain's property-graph memory.
///
/// Sections in this class correspond 1:1 to
/// `memory_specification.md` § 3.1. Method-level docs cite the
/// spec section the method serves.
///
/// **Implementation rule:** the only concrete implementation that
/// exists for v1 is `SqliteTomBrainMemory` (lands at A.28). Tests
/// instantiate fakes that implement this interface directly —
/// there is no second production implementation.
abstract class TomBrainMemory {
  // ─── Lifecycle ───────────────────────────────────────────────

  /// Opens the memory store with [config].
  ///
  /// On first call against a fresh root, creates the directory
  /// layout (`memory.db`, `vectors.db`, `trails/`,
  /// `tombstones/`, `checkpoints/`) and applies all pending
  /// schema migrations. On subsequent calls against an existing
  /// root, verifies schema version + FTS5 availability +
  /// `loadExtension` capability + embedding-model marker file.
  ///
  /// Idempotent — calling `open` on an already-open store
  /// succeeds and returns immediately.
  Future<void> open(MemoryConfig config);

  /// Closes the store: flushes pending writes, fsyncs trail
  /// JSONLs, checkpoints the WAL, and releases native handles.
  ///
  /// Calling `close` on an already-closed store is a no-op.
  Future<void> close();

  /// Forces a WAL checkpoint and a JSONL fsync sweep.
  ///
  /// Used by the cadence-driver in the dispatcher. Memory does
  /// not schedule its own checkpoint cadence — the caller does.
  Future<void> checkpoint();

  // ─── Node CRUD ───────────────────────────────────────────────

  /// Persists a candidate node, returning the stable id.
  ///
  /// A re-call with the same `scope.idempotencyKey` is a no-op
  /// that returns the original id (§ 9.1). Type-shape, embedding
  /// dimension, and the per-type retention policy are all
  /// validated at write time.
  Future<NodeId> persist(NodeDraft draft, {required Scope scope});

  /// Fetches a node by id, or `null` when no live node exists.
  ///
  /// Demoted and archived nodes are still returned — `status`
  /// reflects the lifecycle. Tombstoned ids return `null` (the
  /// Tombstone is reachable via its own NodeId).
  Future<Node?> get(NodeId id);

  /// Bulk fetch. Returns nodes in input order, with missing ids
  /// elided (no `null` placeholders). Saves a round-trip when
  /// the caller already has a batch of ids.
  Future<List<Node>> getMany(List<NodeId> ids);

  /// Demotes a node — hides it from retrieval, keeps it
  /// addressable by id. Reversible by `dream_reconsolidate_v1`.
  Future<void> demote(NodeId id, DemotionReason reason);

  /// User-explicit deletion — writes a `Tombstone` (§ 4.1) and
  /// removes the live row.
  ///
  /// The Tombstone is the only record that survives. This is the
  /// **only** path that ever removes a row from the live table;
  /// every other lifecycle transition is reversible.
  Future<void> forget(NodeId id, ForgetReason reason);

  // ─── Edges ───────────────────────────────────────────────────

  /// Creates an edge.
  ///
  /// Validates against the `NodeTypeDecl.allowedOutgoing` /
  /// `allowedIncoming` permission table; rejects with
  /// `EdgeNotPermitted` on violation. `weight` defaults to 1.0;
  /// `attrs` carries optional per-edge metadata
  /// (e.g. `{'kind': 'depends_on'}` for plan-step dependencies).
  ///
  /// [scope] carries producer attribution and idempotency. Per
  /// spec § 9.1 (and A.67): when `scope.idempotencyKey` is non-null
  /// and an edge already exists under that key, the same `EdgeId`
  /// is returned and no event is emitted — the second `edge` call
  /// is a no-op. `scope.producer` lands in the `produced_by`
  /// column so the trace stitcher can attribute every edge to the
  /// agent run that wrote it.
  Future<EdgeId> edge(
    NodeId from,
    EdgeType type,
    NodeId to, {
    required Scope scope,
    double weight = 1.0,
    Map<String, Object?>? attrs,
  });

  /// Returns edges touching [id], optionally filtered by
  /// [direction] and edge [types].
  Future<List<Edge>> edgesOf(
    NodeId id, {
    EdgeDirection direction = EdgeDirection.both,
    Set<EdgeType>? types,
  });

  // ─── Node-type registry ──────────────────────────────────────

  /// Registers a new node type. Only `propose_node_type_v1` should
  /// call this in normal operation (§ 4.1 "Adding a new node
  /// type"). The procedure routes the declaration through the
  /// critique path before commit.
  Future<void> registerNodeType(NodeTypeDecl decl);

  /// Returns every registered type (live tip of each chain).
  Future<List<NodeTypeDecl>> listNodeTypes();

  /// Looks up a single type by canonical name. Returns `null`
  /// when no type of that name exists.
  Future<NodeTypeDecl?> getNodeType(String typeName);

  // ─── Retrieval ───────────────────────────────────────────────

  /// Runs the four-mode retrieval pipeline (§ 6) and returns the
  /// fused-and-diversified result.
  ///
  /// Memory never instantiates an LLM. The optional
  /// `query.reRank` hook is the only LLM touchpoint and is
  /// supplied by the caller.
  Future<RecallResult> recall(RecallQuery query);

  /// Cursor-backed bulk iteration (§ 9.2).
  ///
  /// Used by cognitive agents to walk over potentially huge node
  /// sets. The returned stream is resumable via
  /// `query.resumeFrom`; cursors persist in `checkpoints/`.
  Stream<Node> stream(StreamQuery query);

  // ─── Classification (LLM-independent) ────────────────────────

  /// Centroid-based classification (§ 7.2).
  ///
  /// Returns `decision = unknown` (cold start) when no centroid
  /// for [target] exists yet, `confident` when both
  /// `minConfidence` and `minMargin` are satisfied,
  /// `uncertain` otherwise.
  Future<ClassificationResult> classify(
    Vec embedding, {
    ClassificationTarget target = ClassificationTarget.nodeType,
  });

  /// Updates a centroid. Only `dream_recentroid_v1` calls this in
  /// normal operation (§ 7.3); memory does not auto-recompute.
  ///
  /// [forKey] is the node-type name or procedure id whose
  /// centroid is being replaced.
  Future<void> updateCentroid(String forKey, Vec centroid);

  /// Returns ids of nodes whose best similarity against the
  /// centroid for [forKey] falls in `[low, high]` (§ 7.4).
  /// Used by `dream_recentroid_v1` to batch-LLM-classify
  /// borderline cases.
  Future<List<NodeId>> findUncertain({
    required String forKey,
    required double low,
    required double high,
    int limit = 200,
  });

  // ─── Stacks ──────────────────────────────────────────────────

  /// The first-class stack subsystem (§ 5).
  ///
  /// Returns a live API surface — calling it on an unopened
  /// memory throws.
  StackApi get stacks;

  // ─── Trails ──────────────────────────────────────────────────

  /// Opens a per-run trail for [run] and returns its id. The
  /// `Trail` index row in `memory.db` is written only after the
  /// first JSONL line is durable (§ 8.1).
  Future<TrailId> openTrail(ProcedureRunRef run);

  /// Appends one entry. Each call fsyncs the JSONL line before
  /// returning (§ 2.4 / § 8.1).
  Future<void> appendTrail(TrailId id, TrailEntry entry);

  /// Writes the outcome record, fsyncs, and emits a
  /// `TrailClosed` event.
  Future<void> closeTrail(TrailId id, TrailOutcome outcome);

  /// Reads a trail back as a corruption-tolerant stream of
  /// entries (§ 8.3). Bad lines surface as `TrailEntryCorrupted`
  /// events on `events()`; the stream itself skips them.
  Stream<TrailEntry> readTrail(TrailId id);

  // ─── Migration checkpoints ───────────────────────────────────

  /// The long-running migration API (§ 11.3).
  MigrationApi get migrations;

  // ─── Observability ───────────────────────────────────────────

  /// The typed memory event stream (§ 16). The dispatcher routes
  /// `ShakingEvent`s into `dream_reconsolidate_v1`; the Tom Forge
  /// brain inspector subscribes for the operator UI.
  Stream<MemoryEvent> events();

  /// Point-in-time snapshot of memory observables.
  Future<MemoryStats> stats();
}
