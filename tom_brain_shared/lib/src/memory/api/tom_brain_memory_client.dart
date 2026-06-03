// TomBrainMemoryClient — the *consumer-facing* shape of the
// brain's property-graph memory.
//
// This is the substitutable contract every brain component talks
// to. Two implementations live downstream of it:
//
//   * `TomBrainMemory` (this package, `api/tom_brain_memory.dart`)
//     — the in-process abstract base. The concrete v1
//     implementation is `SqliteTomBrainMemory` (lands A.28+).
//   * `TomBrainMemoryIsolateClient` (A.80) — the cross-isolate
//     thin client that marshals every call through a SendPort to
//     a `TomBrainMemoryIsolateHost` (A.79) wrapping a real
//     `SqliteTomBrainMemory` on the host side.
//
// Consumers (the dispatcher in Phase D, the procedure engine in
// Phase E, the MCP server, the cognitive agents) hold a
// `TomBrainMemoryClient` reference and remain ignorant of which
// implementation they are bound to. The deployment topology
// (single-isolate vs. multi-isolate vs. multi-machine) is the
// composition root's choice.
//
// The method-level docs on this interface describe the
// *consumer-observable* contract — what every implementation must
// honour. `TomBrainMemory` extends this interface with no extra
// abstract members for v1; it exists as the seam where in-process-
// only fast paths (synchronous introspection, direct DB handles
// for tests) can land later without crossing the isolate boundary.
//
// A.89 ships a black-box conformance suite that drives
// `TomBrainMemoryClient` only and must pass against both
// implementations.

import '../../budget/budget.dart' show WriteBudget;
import '../../embedding/embedding.dart' show Vec;
import '../../ids/ids.dart' show EdgeId, NodeId, TrailId;

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

/// Consumer-facing contract for the brain's property-graph memory.
///
/// Mirrors `memory_specification.md` § 3.1. Both the in-process
/// implementation base class and the cross-isolate client
/// implement this interface; brain components target this
/// interface, not the implementations.
abstract class TomBrainMemoryClient {
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

  // ─── WriteBudget enforcement (§ 9.3) ─────────────────────────

  /// Registers [budget] as the `WriteBudget` cap for the
  /// agent-run identified by [runId] (`memory_specification.md`
  /// § 9.3, § 9.5).
  ///
  /// Subsequent `persist` / `edge` / stack `push` calls whose
  /// `Scope.runId` matches [runId] consume one unit per write of
  /// the corresponding dimension; a charge that would push any
  /// component below zero raises `WriteBudgetExceeded` (the
  /// memory-internal exception, distinct from
  /// `tom_brain_shared.BudgetExceededError`). The rejected write
  /// inserts no row, emits no event, and does not consume budget.
  ///
  /// Budget enforcement is **opt-in**: writes whose runs were
  /// never registered pass through unchecked. Bootstrap installs
  /// (node-type registry seeding, bootstrap stack creation) and
  /// operator-driven ad-hoc writes belong to that branch.
  ///
  /// Calling [beginRun] twice with the same [runId] replaces the
  /// prior registration — runs are unique by contract, so this is
  /// most likely a programmer error, but the obvious "reset to the
  /// new cap" semantics is the least-surprising response.
  Future<void> beginRun({
    required String runId,
    required WriteBudget budget,
  });

  /// Removes the budget registration for [runId]. Subsequent
  /// writes that name the same id pass through unchecked.
  ///
  /// Called by the dispatcher when an agent run terminates
  /// (success, failure, or cancellation). Calling [endRun] for an
  /// unregistered run id is a no-op — same shape as `close()` on
  /// an already-closed resource.
  Future<void> endRun(String runId);

  /// Returns the remaining `WriteBudget` for [runId], or `null`
  /// when the run is not registered. Exposed for the operator UI
  /// and trace-stitcher observers; production write paths consult
  /// the tracker via the typed charge methods, not via this
  /// getter.
  Future<WriteBudget?> remainingBudget(String runId);

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
  /// `query.resumeFrom`; cursors persist in `checkpoints/`. The
  /// isolate-client implementation honours back-pressure across
  /// the SendPort (A.81).
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
  /// memory throws. The isolate-client implementation returns a
  /// thin proxy that marshals each stack call through the
  /// SendPort; consumers cannot tell the difference.
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
  /// events on [events]; the stream itself skips them.
  Stream<TrailEntry> readTrail(TrailId id);

  // ─── Migration checkpoints ───────────────────────────────────

  /// The long-running migration API (§ 11.3). The isolate-client
  /// implementation returns a thin proxy that marshals each
  /// migration call through the SendPort.
  MigrationApi get migrations;

  // ─── Observability ───────────────────────────────────────────

  /// The typed memory event stream (§ 16). The dispatcher routes
  /// `ShakingEvent`s into `dream_reconsolidate_v1`; the Tom Forge
  /// brain inspector subscribes for the operator UI. The
  /// isolate-client implementation forwards events from the host
  /// as serialised envelopes; typed event subclasses are
  /// reconstructed on the consumer side.
  Stream<MemoryEvent> events();

  /// Point-in-time snapshot of memory observables.
  Future<MemoryStats> stats();
}
