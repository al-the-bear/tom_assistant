// TomBrainMemoryIsolateClient — the thin consumer-facing client
// that implements `TomBrainMemoryClient` by translating every
// method call into an `IsolateRequest` envelope sent through a
// `TomBrainMemoryIsolateHost` (plan step A.80).
//
// Position in the slice (A.78 – A.82):
//
//   * A.78 ✅ — `TomBrainMemoryClient` consumer-facing interface.
//   * A.79 ✅ — `TomBrainMemoryIsolateHost` + minimal envelope
//     skeleton (lifecycle envelopes + `MemoryStats` as the one
//     dispatch-proof pair).
//   * A.80 (this file) — the client. Implements the full
//     `TomBrainMemoryClient` surface. Methods whose envelope is
//     already in the A.79 skeleton (`open`, `close`, `stats`) round-
//     trip end-to-end. Every other method throws an
//     [EnvelopeNotWiredError] that names the method and points at
//     A.81. This makes the not-yet-wired contract a typed,
//     test-assertable surface rather than a runtime surprise.
//   * A.81 — expands the envelope catalogue; replaces every
//     `EnvelopeNotWiredError` with a real `host.send(...)` call.
//   * A.82 — round-trips every method through a real isolate.
//
// Ownership model:
//
//   * The client *wraps* a host — it does not own its lifecycle.
//     Callers construct the host, `await host.spawn()`, hand it to
//     the client, and `await host.shutdown()` when finished. This
//     mirrors the production wiring planned for Phase D, where the
//     dispatcher owns the host and the client is just one of
//     potentially several consumers of that host.
//   * The client does *not* implement `TomBrainMemory`. Per spec
//     and A.78's class doc, the in-process marker is reserved for
//     code that needs the in-process-only seam (synchronous
//     introspection, direct DB-handle exposure). Implementing only
//     `TomBrainMemoryClient` keeps that boundary honest.

import 'dart:async';

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, TrailId, Vec, WriteBudget;

import '../api/memory_event.dart';
import '../api/memory_stats.dart';
import '../api/scope.dart';
import '../api/tom_brain_memory_client.dart';
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
import '../stacks/stack_types.dart';
import '../trails/trail.dart';
import 'isolate_messages.dart';
import 'tom_brain_memory_isolate_host.dart';

/// Thrown by [TomBrainMemoryIsolateClient] methods whose
/// corresponding envelope has not been added to the protocol yet.
///
/// A.79 deliberately ships only the lifecycle envelopes plus one
/// dispatch-proof pair (`MemoryStats`). The full catalogue lands at
/// A.81. Until then, calling any unwired method on the client
/// raises this typed error so callers — and the test suite — get a
/// loud, identifiable signal rather than an `UnimplementedError`
/// with no provenance.
///
/// The error is a subclass of [UnimplementedError] so any caller
/// that already handles `UnimplementedError` continues to behave
/// reasonably (logging, surfacing to the user). The additional
/// fields ([method], [step]) let test assertions pin the contract
/// to the exact step that will lift the restriction.
final class EnvelopeNotWiredError extends UnimplementedError {
  /// The `TomBrainMemoryClient` method name, e.g. `'persist'`.
  final String method;

  /// The plan step that will land the envelope (currently always
  /// `'A.81'`). Carried explicitly so a future change to the
  /// wiring plan only has to touch one place.
  final String step;

  EnvelopeNotWiredError(this.method, {this.step = 'A.81'})
      : super(
          'TomBrainMemoryIsolateClient.$method: envelope not wired yet '
          '(lands at $step).',
        );
}

/// Cross-isolate implementation of [TomBrainMemoryClient].
///
/// Constructed around a [TomBrainMemoryIsolateHost] that has
/// already been `spawn()`-ed. Translates every method call to a
/// `host.send(...)` of the corresponding envelope.
///
/// Methods whose envelope is already wired in A.79's skeleton:
///
///   * [open]    → `host.openMemory(config)`.
///   * [close]   → `host.closeMemory()`.
///   * [stats]   → `host.send<MemoryStatsResponse>(...)`.
///
/// Every other method throws [EnvelopeNotWiredError]. The stack/
/// migration getters return proxy objects whose every method
/// raises the same error.
class TomBrainMemoryIsolateClient implements TomBrainMemoryClient {
  /// The host this client dispatches through. Lifetime is owned by
  /// the caller — the client does not call `host.spawn()` or
  /// `host.shutdown()` and does not register cleanup hooks.
  final TomBrainMemoryIsolateHost host;

  /// Built lazily so the stack/migration proxies are only allocated
  /// when something asks for them.
  StackApi? _stacks;
  MigrationApi? _migrations;

  TomBrainMemoryIsolateClient(this.host);

  // ─── Lifecycle ───────────────────────────────────────────────────

  @override
  Future<void> open(MemoryConfig config) => host.openMemory(config);

  @override
  Future<void> close() => host.closeMemory();

  @override
  Future<void> checkpoint() {
    // No envelope yet (A.81 will add `CheckpointRequest`). Returning
    // a failed future rather than throwing synchronously matches the
    // shape of every other `Future`-returning method on the client.
    return Future<void>.error(EnvelopeNotWiredError('checkpoint'));
  }

  // ─── WriteBudget enforcement ─────────────────────────────────────

  @override
  Future<void> beginRun({
    required String runId,
    required WriteBudget budget,
  }) {
    return Future<void>.error(EnvelopeNotWiredError('beginRun'));
  }

  @override
  Future<void> endRun(String runId) {
    return Future<void>.error(EnvelopeNotWiredError('endRun'));
  }

  @override
  Future<WriteBudget?> remainingBudget(String runId) {
    return Future<WriteBudget?>.error(EnvelopeNotWiredError('remainingBudget'));
  }

  // ─── Node CRUD ───────────────────────────────────────────────────

  @override
  Future<NodeId> persist(NodeDraft draft, {required Scope scope}) {
    return Future<NodeId>.error(EnvelopeNotWiredError('persist'));
  }

  @override
  Future<Node?> get(NodeId id) {
    return Future<Node?>.error(EnvelopeNotWiredError('get'));
  }

  @override
  Future<List<Node>> getMany(List<NodeId> ids) {
    return Future<List<Node>>.error(EnvelopeNotWiredError('getMany'));
  }

  @override
  Future<void> demote(NodeId id, DemotionReason reason) {
    return Future<void>.error(EnvelopeNotWiredError('demote'));
  }

  @override
  Future<void> forget(NodeId id, ForgetReason reason) {
    return Future<void>.error(EnvelopeNotWiredError('forget'));
  }

  // ─── Edges ───────────────────────────────────────────────────────

  @override
  Future<EdgeId> edge(
    NodeId from,
    EdgeType type,
    NodeId to, {
    required Scope scope,
    double weight = 1.0,
    Map<String, Object?>? attrs,
  }) {
    return Future<EdgeId>.error(EnvelopeNotWiredError('edge'));
  }

  @override
  Future<List<Edge>> edgesOf(
    NodeId id, {
    EdgeDirection direction = EdgeDirection.both,
    Set<EdgeType>? types,
  }) {
    return Future<List<Edge>>.error(EnvelopeNotWiredError('edgesOf'));
  }

  // ─── Node-type registry ──────────────────────────────────────────

  @override
  Future<void> registerNodeType(NodeTypeDecl decl) {
    return Future<void>.error(EnvelopeNotWiredError('registerNodeType'));
  }

  @override
  Future<List<NodeTypeDecl>> listNodeTypes() {
    return Future<List<NodeTypeDecl>>.error(
      EnvelopeNotWiredError('listNodeTypes'),
    );
  }

  @override
  Future<NodeTypeDecl?> getNodeType(String typeName) {
    return Future<NodeTypeDecl?>.error(EnvelopeNotWiredError('getNodeType'));
  }

  // ─── Retrieval ───────────────────────────────────────────────────

  @override
  Future<RecallResult> recall(RecallQuery query) {
    return Future<RecallResult>.error(EnvelopeNotWiredError('recall'));
  }

  @override
  Stream<Node> stream(StreamQuery query) {
    // Stream-returning methods report failure on the stream itself
    // so callers using `await for` see a typed error rather than a
    // silent empty stream.
    return Stream<Node>.error(EnvelopeNotWiredError('stream'));
  }

  // ─── Classification ──────────────────────────────────────────────

  @override
  Future<ClassificationResult> classify(
    Vec embedding, {
    ClassificationTarget target = ClassificationTarget.nodeType,
  }) {
    return Future<ClassificationResult>.error(
      EnvelopeNotWiredError('classify'),
    );
  }

  @override
  Future<void> updateCentroid(String forKey, Vec centroid) {
    return Future<void>.error(EnvelopeNotWiredError('updateCentroid'));
  }

  @override
  Future<List<NodeId>> findUncertain({
    required String forKey,
    required double low,
    required double high,
    int limit = 200,
  }) {
    return Future<List<NodeId>>.error(EnvelopeNotWiredError('findUncertain'));
  }

  // ─── Stacks ──────────────────────────────────────────────────────

  @override
  StackApi get stacks => _stacks ??= _UnwiredStackApi();

  // ─── Trails ──────────────────────────────────────────────────────

  @override
  Future<TrailId> openTrail(ProcedureRunRef run) {
    return Future<TrailId>.error(EnvelopeNotWiredError('openTrail'));
  }

  @override
  Future<void> appendTrail(TrailId id, TrailEntry entry) {
    return Future<void>.error(EnvelopeNotWiredError('appendTrail'));
  }

  @override
  Future<void> closeTrail(TrailId id, TrailOutcome outcome) {
    return Future<void>.error(EnvelopeNotWiredError('closeTrail'));
  }

  @override
  Stream<TrailEntry> readTrail(TrailId id) {
    return Stream<TrailEntry>.error(EnvelopeNotWiredError('readTrail'));
  }

  // ─── Migrations ──────────────────────────────────────────────────

  @override
  MigrationApi get migrations => _migrations ??= _UnwiredMigrationApi();

  // ─── Observability ───────────────────────────────────────────────

  @override
  Stream<MemoryEvent> events() {
    return Stream<MemoryEvent>.error(EnvelopeNotWiredError('events'));
  }

  @override
  Future<MemoryStats> stats() async {
    final reply = await host.send<MemoryStatsResponse>(
      const MemoryStatsRequest(),
    );
    return reply.stats;
  }
}

// ─── Proxy stubs for the getter-returned sub-APIs ─────────────────
//
// Both `stacks` and `migrations` are exposed as getters that must
// return a usable object. A.81 will replace these proxies with
// versions that marshal each call through new envelopes. Until
// then, every method on the proxy raises [EnvelopeNotWiredError]
// the same way the top-level methods do. The proxies live in this
// file (not in `stacks/` or `migrations/`) because they are an
// implementation detail of the isolate-client surface; the
// canonical in-process stack/migration implementations belong in
// their own modules.

class _UnwiredStackApi implements StackApi {
  @override
  Future<List<StackSummary>> list() {
    return Future<List<StackSummary>>.error(
      EnvelopeNotWiredError('stacks.list'),
    );
  }

  @override
  Future<StackInfo?> info(String name) {
    return Future<StackInfo?>.error(EnvelopeNotWiredError('stacks.info'));
  }

  @override
  Future<void> create(StackDecl decl) {
    return Future<void>.error(EnvelopeNotWiredError('stacks.create'));
  }

  @override
  Future<void> updatePolicy(String name, StackPolicy policy) {
    return Future<void>.error(EnvelopeNotWiredError('stacks.updatePolicy'));
  }

  @override
  Future<void> delete(String name) {
    return Future<void>.error(EnvelopeNotWiredError('stacks.delete'));
  }

  @override
  Future<StackEntryId> push(
    String name,
    NodeId entry, {
    double priority = 0.0,
    Map<String, Object?>? attrs,
    Scope? scope,
  }) {
    return Future<StackEntryId>.error(EnvelopeNotWiredError('stacks.push'));
  }

  @override
  Future<List<StackEntry>> peek(String name, {int k = 16}) {
    return Future<List<StackEntry>>.error(EnvelopeNotWiredError('stacks.peek'));
  }

  @override
  Future<StackEntry?> pop(String name) {
    return Future<StackEntry?>.error(EnvelopeNotWiredError('stacks.pop'));
  }

  @override
  Future<void> update(
    String name,
    NodeId entry, {
    double? priority,
    StackEntryStatus? status,
    Map<String, Object?>? attrs,
  }) {
    return Future<void>.error(EnvelopeNotWiredError('stacks.update'));
  }

  @override
  Future<void> remove(String name, NodeId entry) {
    return Future<void>.error(EnvelopeNotWiredError('stacks.remove'));
  }

  @override
  Stream<StackEntry> streamArchived(String name, {int? limit}) {
    return Stream<StackEntry>.error(
      EnvelopeNotWiredError('stacks.streamArchived'),
    );
  }

  @override
  Stream<StackEvent> events(String name) {
    return Stream<StackEvent>.error(EnvelopeNotWiredError('stacks.events'));
  }
}

class _UnwiredMigrationApi implements MigrationApi {
  @override
  Future<void> start(MigrationDecl decl) {
    return Future<void>.error(EnvelopeNotWiredError('migrations.start'));
  }

  @override
  Future<MigrationCursor?> cursor(String migrationId) {
    return Future<MigrationCursor?>.error(
      EnvelopeNotWiredError('migrations.cursor'),
    );
  }

  @override
  Future<void> saveCursor(
    String migrationId,
    Map<String, Object?> position,
  ) {
    return Future<void>.error(EnvelopeNotWiredError('migrations.saveCursor'));
  }

  @override
  Future<MigrationStatus?> status(String migrationId) {
    return Future<MigrationStatus?>.error(
      EnvelopeNotWiredError('migrations.status'),
    );
  }

  @override
  Future<List<MigrationStatus>> listInProgress() {
    return Future<List<MigrationStatus>>.error(
      EnvelopeNotWiredError('migrations.listInProgress'),
    );
  }
}
