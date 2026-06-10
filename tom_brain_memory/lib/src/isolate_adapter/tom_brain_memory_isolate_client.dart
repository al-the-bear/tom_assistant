// TomBrainMemoryIsolateClient — the thin consumer-facing client
// that implements `TomBrainMemoryClient` by translating every
// method call into an `IsolateRequest` envelope sent through a
// `TomBrainMemoryIsolateHost` (plan steps A.80–A.82).
//
// Position in the slice (A.78 – A.82):
//
//   * A.78 ✅ — `TomBrainMemoryClient` consumer-facing interface.
//   * A.79 ✅ — `TomBrainMemoryIsolateHost` + minimal envelope
//     skeleton (lifecycle envelopes + `MemoryStats` as the one
//     dispatch-proof pair).
//   * A.80 ✅ — the client. Implements the full
//     `TomBrainMemoryClient` surface against the host. Methods
//     wired end-to-end at A.80: `open`, `close`, `stats`.
//   * A.81 ✅ — streaming + cancellation protocol. `readTrail`
//     (backpressure) and `events` (cancellation) round-trip
//     through a real isolate via the host's new stream-router
//     surface.
//   * A.82 (this file, current step) — every remaining method on
//     `TomBrainMemoryClient` round-trips through the boundary,
//     including the `stacks` and `migrations` sub-APIs and the
//     remaining three stream-returning methods (`stream`,
//     `stacks.streamArchived`, `stacks.events`). The
//     `EnvelopeNotWiredError` transitional surface is gone.
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
//
// Un-sendable corners:
//
//   * `RecallQuery.reRank` is a closure — not sendable across the
//     SendPort. `recall()` rejects a non-null `reRank` with
//     `ArgumentError.value` before constructing any envelope. The
//     caller must run the recall without the hook and re-rank the
//     returned candidates locally.

import 'dart:async';

import 'package:tom_brain_shared/tom_brain_shared.dart' show ClassificationResult, ClassificationTarget, DemotionReason, Edge, EdgeDirection, EdgeId, EdgeType, ForgetReason, MemoryConfig, MemoryEvent, MemoryStats, MigrationApi, MigrationCursor, MigrationDecl, MigrationStatus, MultiRecallQuery, Node, NodeDraft, NodeId, NodeTypeDecl, ProcedureRunRef, ProcedureStatus, RecallQuery, RecallResult, Scope, StackApi, StackDecl, StackEntry, StackEntryId, StackEntryStatus, StackEvent, StackInfo, StackPolicy, StackSummary, StreamQuery, TomBrainMemoryClient, TrailEntry, TrailId, TrailOutcome, Vec, WriteBudget;
import 'package:tom_core_agentic/tom_core_agentic.dart'
    show IsolateCancellationToken;

import 'isolate_envelopes_full.dart';
import 'isolate_messages.dart';
import 'isolate_stream_protocol.dart';
import 'tom_brain_memory_isolate_host.dart';

/// Cross-isolate implementation of [TomBrainMemoryClient].
///
/// Constructed around a [TomBrainMemoryIsolateHost] that has
/// already been `spawn()`-ed. Translates every method call to a
/// `host.send(...)` of the corresponding envelope.
///
/// Every public method on `TomBrainMemoryClient` round-trips
/// through the isolate boundary. The five stream-returning methods
/// (`readTrail`, `events`, `stream`, `stacks.streamArchived`,
/// `stacks.events`) ride the host's side-channel: backpressured
/// streams use a sliding window (one credit auto-pulled per
/// delivered chunk); unbounded streams use cancellation tokens for
/// termination.
class TomBrainMemoryIsolateClient implements TomBrainMemoryClient {
  /// The host this client dispatches through. Lifetime is owned by
  /// the caller — the client does not call `host.spawn()` or
  /// `host.shutdown()` and does not register cleanup hooks.
  final TomBrainMemoryIsolateHost host;

  /// Initial credit allowance for `readTrail` streams. The client
  /// auto-replenishes one credit per chunk delivered so the
  /// in-isolate producer keeps a rolling window of this size.
  /// Tests can lower this to force the executor to pause and
  /// resume on explicit pulls.
  final int readTrailInitialCredits;

  /// Initial credit allowance for `stream(StreamQuery)` cursor scans.
  /// Same sliding-window contract as [readTrailInitialCredits].
  final int streamQueryInitialCredits;

  /// Initial credit allowance for `stacks.streamArchived`. Same
  /// contract as [readTrailInitialCredits].
  final int stacksArchivedInitialCredits;

  /// Built lazily so the stack/migration proxies are only allocated
  /// when something asks for them.
  StackApi? _stacks;
  MigrationApi? _migrations;

  /// Default sliding-window size for every streaming surface. Chosen
  /// to keep the in-isolate producer a few chunks ahead of the
  /// consumer without unbounded buffering; tests override per-stream.
  static const int defaultStreamCredits = 16;

  TomBrainMemoryIsolateClient(
    this.host, {
    this.readTrailInitialCredits = defaultStreamCredits,
    this.streamQueryInitialCredits = defaultStreamCredits,
    this.stacksArchivedInitialCredits = defaultStreamCredits,
  });

  // ─── Lifecycle ───────────────────────────────────────────────────

  @override
  Future<void> open(MemoryConfig config) => host.openMemory(config);

  @override
  Future<void> close() => host.closeMemory();

  @override
  Future<void> checkpoint() async {
    await host.send<CheckpointResponse>(const CheckpointRequest());
  }

  // ─── WriteBudget enforcement ─────────────────────────────────────

  @override
  Future<void> beginRun({
    required String runId,
    required WriteBudget budget,
  }) async {
    await host.send<BeginRunResponse>(
      BeginRunRequest(runId: runId, budget: budget),
    );
  }

  @override
  Future<void> endRun(String runId) async {
    await host.send<EndRunResponse>(EndRunRequest(runId));
  }

  @override
  Future<WriteBudget?> remainingBudget(String runId) async {
    final r = await host.send<RemainingBudgetResponse>(
      RemainingBudgetRequest(runId),
    );
    return r.budget;
  }

  // ─── Node CRUD ───────────────────────────────────────────────────

  @override
  Future<NodeId> persist(NodeDraft draft, {required Scope scope}) async {
    final r = await host.send<PersistResponse>(
      PersistRequest(draft: draft, scope: scope),
    );
    return r.id;
  }

  @override
  Future<Node?> get(NodeId id) async {
    final r = await host.send<GetNodeResponse>(GetNodeRequest(id));
    return r.node;
  }

  @override
  Future<List<Node>> getMany(List<NodeId> ids) async {
    final r = await host.send<GetManyResponse>(GetManyRequest(ids));
    return r.nodes;
  }

  @override
  Future<void> demote(NodeId id, DemotionReason reason) async {
    await host.send<DemoteResponse>(
      DemoteRequest(id: id, reason: reason),
    );
  }

  @override
  Future<void> forget(NodeId id, ForgetReason reason) async {
    await host.send<ForgetResponse>(
      ForgetRequest(id: id, reason: reason),
    );
  }

  @override
  Future<void> updateProcedureMetrics(
    NodeId id, {
    ProcedureStatus? status,
    double? successRate,
    int? runCount,
    DateTime? lastRunAt,
  }) async {
    await host.send<UpdateProcedureMetricsResponse>(
      UpdateProcedureMetricsRequest(
        id: id,
        status: status,
        successRate: successRate,
        runCount: runCount,
        lastRunAt: lastRunAt,
      ),
    );
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
  }) async {
    final r = await host.send<CreateEdgeResponse>(
      CreateEdgeRequest(
        from: from,
        type: type,
        to: to,
        scope: scope,
        weight: weight,
        attrs: attrs,
      ),
    );
    return r.id;
  }

  @override
  Future<List<Edge>> edgesOf(
    NodeId id, {
    EdgeDirection direction = EdgeDirection.both,
    Set<EdgeType>? types,
  }) async {
    final r = await host.send<EdgesOfResponse>(
      EdgesOfRequest(id: id, direction: direction, types: types),
    );
    return r.edges;
  }

  // ─── Node-type registry ──────────────────────────────────────────

  @override
  Future<void> registerNodeType(NodeTypeDecl decl) async {
    await host.send<RegisterNodeTypeResponse>(
      RegisterNodeTypeRequest(decl),
    );
  }

  @override
  Future<List<NodeTypeDecl>> listNodeTypes() async {
    final r = await host.send<ListNodeTypesResponse>(
      const ListNodeTypesRequest(),
    );
    return r.types;
  }

  @override
  Future<NodeTypeDecl?> getNodeType(String typeName) async {
    final r = await host.send<GetNodeTypeResponse>(
      GetNodeTypeRequest(typeName),
    );
    return r.decl;
  }

  // ─── Retrieval ───────────────────────────────────────────────────

  @override
  Future<RecallResult> recall(RecallQuery query) async {
    if (query.reRank != null) {
      // Closures cannot cross the SendPort boundary. The contract
      // explicitly forbids LLM re-ranking through this adapter — the
      // caller must instead run the recall and re-rank locally on the
      // returned candidates.
      throw ArgumentError.value(
        query.reRank,
        'query.reRank',
        'RecallQuery.reRank is not supported across the isolate boundary '
            '— closures are not sendable. Run recall without reRank, '
            'then re-rank the returned candidates on the caller side.',
      );
    }
    final r = await host.send<RecallResponse>(RecallRequest(query));
    return r.result;
  }

  @override
  Future<RecallResult> recallMulti(MultiRecallQuery query) async {
    // Fully wire-sendable: MultiRecallQuery carries no closures, so the
    // whole query crosses the boundary intact (unlike RecallQuery.reRank).
    final r = await host.send<RecallMultiResponse>(RecallMultiRequest(query));
    return r.result;
  }

  @override
  Stream<Node> stream(StreamQuery query) {
    final streamId = host.streamIdAllocator.next();
    final rawStream = host.openStream<Node>(
      OpenStreamQueryRequest(
        streamId: streamId,
        query: query,
        initialCredits: streamQueryInitialCredits,
      ),
      streamId: streamId,
      payloadAdapter: (p) => p as Node,
    );
    return _wrapWithAutoCredits(rawStream, streamId);
  }

  // ─── Classification ──────────────────────────────────────────────

  @override
  Future<ClassificationResult> classify(
    Vec embedding, {
    ClassificationTarget target = ClassificationTarget.nodeType,
  }) async {
    final r = await host.send<ClassifyResponse>(
      ClassifyRequest(embedding: embedding, target: target),
    );
    return r.result;
  }

  @override
  Future<void> updateCentroid(String forKey, Vec centroid) async {
    await host.send<UpdateCentroidResponse>(
      UpdateCentroidRequest(forKey: forKey, centroid: centroid),
    );
  }

  @override
  Future<List<NodeId>> findUncertain({
    required String forKey,
    required double low,
    required double high,
    int limit = 200,
  }) async {
    final r = await host.send<FindUncertainResponse>(
      FindUncertainRequest(
        forKey: forKey,
        low: low,
        high: high,
        limit: limit,
      ),
    );
    return r.ids;
  }

  // ─── Stacks ──────────────────────────────────────────────────────

  @override
  StackApi get stacks => _stacks ??= _IsolateStackApi(this);

  // ─── Trails ──────────────────────────────────────────────────────

  @override
  Future<TrailId> openTrail(ProcedureRunRef run) async {
    final r = await host.send<OpenTrailResponse>(OpenTrailRequest(run));
    return r.id;
  }

  @override
  Future<void> appendTrail(TrailId id, TrailEntry entry) async {
    await host.send<AppendTrailResponse>(
      AppendTrailRequest(id: id, entry: entry),
    );
  }

  @override
  Future<void> closeTrail(TrailId id, TrailOutcome outcome) async {
    await host.send<TrailCloseResponse>(
      TrailCloseRequest(id: id, outcome: outcome),
    );
  }

  /// A.81 — Backpressure proof.
  ///
  /// Allocates a fresh stream id, opens an
  /// `OpenReadTrailStreamRequest`, and returns the host's stream
  /// transformed so that one credit is auto-pulled per delivered
  /// chunk (sliding-window backpressure at
  /// [readTrailInitialCredits]).
  @override
  Stream<TrailEntry> readTrail(TrailId id) {
    final streamId = host.streamIdAllocator.next();
    final rawStream = host.openStream<TrailEntry>(
      OpenReadTrailStreamRequest(
        streamId: streamId,
        trailId: id,
        initialCredits: readTrailInitialCredits,
      ),
      streamId: streamId,
      payloadAdapter: (p) => p as TrailEntry,
    );
    return _wrapWithAutoCredits(rawStream, streamId);
  }

  /// Returns a stream that mirrors [raw] and auto-pulls one credit
  /// per delivered chunk. The producer keeps a sliding window equal
  /// to the open envelope's `initialCredits`.
  ///
  /// On consumer cancel, closes the upstream stream via
  /// `host.closeStream(streamId)`. Errors from a stale stream id on
  /// the auto-pull are silently swallowed — the producer may have
  /// completed between the chunk's send and our pull.
  Stream<T> _wrapWithAutoCredits<T>(Stream<T> raw, StreamId streamId) {
    final out = StreamController<T>();
    StreamSubscription<T>? sub;
    out.onListen = () {
      sub = raw.listen(
        (item) {
          out.add(item);
          () async {
            try {
              await host.pullCredits(streamId, 1);
            } on IsolateBoundaryException {
              // Producer already terminated; nothing to pull.
            } on StateError {
              // Host is mid-shutdown.
            }
          }();
        },
        onError: out.addError,
        onDone: out.close,
      );
    };
    out.onCancel = () async {
      await sub?.cancel();
      await host.closeStream(streamId);
    };
    return out.stream;
  }

  /// Returns a stream that mirrors [raw] without credit replenishment —
  /// for unbounded streams whose only termination signal is cancellation
  /// (`events`, `stacks.events`).
  ///
  /// On consumer cancel, fires `host.cancel(token)` then
  /// `host.closeStream(streamId)`.
  Stream<T> _wrapWithCancellation<T>(
    Stream<T> raw,
    StreamId streamId,
    IsolateCancellationToken token,
  ) {
    final out = StreamController<T>();
    StreamSubscription<T>? sub;
    out.onListen = () {
      sub = raw.listen(
        out.add,
        onError: out.addError,
        onDone: out.close,
      );
    };
    out.onCancel = () async {
      await sub?.cancel();
      try {
        await host.cancel(token);
      } on IsolateBoundaryException {
        // Already terminated.
      } on StateError {
        // Host is mid-shutdown.
      }
      await host.closeStream(streamId);
    };
    return out.stream;
  }

  // ─── Migrations ──────────────────────────────────────────────────

  @override
  MigrationApi get migrations => _migrations ??= _IsolateMigrationApi(this);

  // ─── Observability ───────────────────────────────────────────────

  /// A.81 — Cancellation proof.
  ///
  /// Allocates a cancellation token and a stream id, opens an
  /// `OpenEventsStreamRequest`, and returns the host's stream.
  /// Cancelling the consumer's subscription cancels the token and
  /// closes the stream.
  @override
  Stream<MemoryEvent> events() {
    final token = host.cancellationAllocator.next();
    final streamId = host.streamIdAllocator.next();
    final rawStream = host.openStream<MemoryEvent>(
      OpenEventsStreamRequest(streamId: streamId, cancellation: token),
      streamId: streamId,
      payloadAdapter: (p) => p as MemoryEvent,
    );
    return _wrapWithCancellation(rawStream, streamId, token);
  }

  @override
  Future<MemoryStats> stats() async {
    final reply = await host.send<MemoryStatsResponse>(
      const MemoryStatsRequest(),
    );
    return reply.stats;
  }
}

// ─── Proxies for the getter-returned sub-APIs ─────────────────────
//
// Both `stacks` and `migrations` are exposed as getters that return a
// usable object. Each proxy marshals every call through the parent
// client's host using the per-method envelopes from
// `isolate_envelopes_full.dart`. The proxies live in this file (not in
// `stacks/` or `migrations/`) because they are an implementation
// detail of the isolate-client surface; the canonical in-process
// stack/migration implementations belong in their own modules.

/// Concrete [StackApi] for the isolate client — marshals every call
/// through the parent client's host.
class _IsolateStackApi implements StackApi {
  final TomBrainMemoryIsolateClient _client;
  _IsolateStackApi(this._client);

  TomBrainMemoryIsolateHost get _host => _client.host;

  @override
  Future<List<StackSummary>> list() async {
    final r = await _host.send<StacksListResponse>(
      const StacksListRequest(),
    );
    return r.summaries;
  }

  @override
  Future<StackInfo?> info(String name) async {
    final r = await _host.send<StacksInfoResponse>(StacksInfoRequest(name));
    return r.info;
  }

  @override
  Future<void> create(StackDecl decl) async {
    await _host.send<StacksCreateResponse>(StacksCreateRequest(decl));
  }

  @override
  Future<void> updatePolicy(String name, StackPolicy policy) async {
    await _host.send<StacksUpdatePolicyResponse>(
      StacksUpdatePolicyRequest(name: name, policy: policy),
    );
  }

  @override
  Future<void> delete(String name) async {
    await _host.send<StacksDeleteResponse>(StacksDeleteRequest(name));
  }

  @override
  Future<StackEntryId> push(
    String name,
    NodeId entry, {
    double priority = 0.0,
    Map<String, Object?>? attrs,
    Scope? scope,
  }) async {
    final r = await _host.send<StacksPushResponse>(
      StacksPushRequest(
        name: name,
        entry: entry,
        priority: priority,
        attrs: attrs,
        scope: scope,
      ),
    );
    return r.id;
  }

  @override
  Future<List<StackEntry>> peek(
    String name, {
    int k = StacksPeekRequest.defaultK,
  }) async {
    final r = await _host.send<StacksPeekResponse>(
      StacksPeekRequest(name: name, k: k),
    );
    return r.entries;
  }

  @override
  Future<StackEntry?> pop(String name) async {
    final r = await _host.send<StacksPopResponse>(StacksPopRequest(name));
    return r.entry;
  }

  @override
  Future<void> update(
    String name,
    NodeId entry, {
    double? priority,
    StackEntryStatus? status,
    Map<String, Object?>? attrs,
  }) async {
    await _host.send<StacksUpdateResponse>(
      StacksUpdateRequest(
        name: name,
        entry: entry,
        priority: priority,
        status: status,
        attrs: attrs,
      ),
    );
  }

  @override
  Future<void> remove(String name, NodeId entry) async {
    await _host.send<StacksRemoveResponse>(
      StacksRemoveRequest(name: name, entry: entry),
    );
  }

  @override
  Stream<StackEntry> streamArchived(String name, {int? limit}) {
    final streamId = _host.streamIdAllocator.next();
    final raw = _host.openStream<StackEntry>(
      OpenStacksArchivedStreamRequest(
        streamId: streamId,
        name: name,
        limit: limit,
        initialCredits: _client.stacksArchivedInitialCredits,
      ),
      streamId: streamId,
      payloadAdapter: (p) => p as StackEntry,
    );
    return _client._wrapWithAutoCredits(raw, streamId);
  }

  @override
  Stream<StackEvent> events(String name) {
    final token = _host.cancellationAllocator.next();
    final streamId = _host.streamIdAllocator.next();
    final raw = _host.openStream<StackEvent>(
      OpenStacksEventsStreamRequest(
        streamId: streamId,
        name: name,
        cancellation: token,
      ),
      streamId: streamId,
      payloadAdapter: (p) => p as StackEvent,
    );
    return _client._wrapWithCancellation(raw, streamId, token);
  }
}

/// Concrete [MigrationApi] for the isolate client.
class _IsolateMigrationApi implements MigrationApi {
  final TomBrainMemoryIsolateClient _client;
  _IsolateMigrationApi(this._client);

  TomBrainMemoryIsolateHost get _host => _client.host;

  @override
  Future<void> start(MigrationDecl decl) async {
    await _host.send<MigrationsStartResponse>(MigrationsStartRequest(decl));
  }

  @override
  Future<MigrationCursor?> cursor(String migrationId) async {
    final r = await _host.send<MigrationsCursorResponse>(
      MigrationsCursorRequest(migrationId),
    );
    return r.cursor;
  }

  @override
  Future<void> saveCursor(
    String migrationId,
    Map<String, Object?> position,
  ) async {
    await _host.send<MigrationsSaveCursorResponse>(
      MigrationsSaveCursorRequest(
        migrationId: migrationId,
        position: position,
      ),
    );
  }

  @override
  Future<MigrationStatus?> status(String migrationId) async {
    final r = await _host.send<MigrationsStatusResponse>(
      MigrationsStatusRequest(migrationId),
    );
    return r.status;
  }

  @override
  Future<List<MigrationStatus>> listInProgress() async {
    final r = await _host.send<MigrationsListInProgressResponse>(
      const MigrationsListInProgressRequest(),
    );
    return r.statuses;
  }
}
