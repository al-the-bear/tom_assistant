// MemoryIsolateExecutor — the in-isolate `TomExecutor` that
// dispatches `IsolateRequest` envelopes to the held
// `TomBrainMemory` instance (plan step A.79, extended in A.81).
//
// Constructed inside `MemoryWorkerContext.initializeIsolate` and
// registered onto `TomWorker.executors` (the per-isolate static
// list). One instance per isolate; lifetime equals isolate
// lifetime.
//
// Dispatch rules:
//
//   * The executor handles `IsolateRequest` envelopes only. Any
//     other command surfaces as `TomExecutor.noResult` so the
//     `TomWorker.executors` chain can pass it to the next handler
//     (e.g. logging instrumentation Phase D will wire in).
//   * `OpenMemoryRequest` is the only envelope that touches the
//     memory's lifecycle. Every other request requires memory to
//     be open already; calling them against an unopened memory
//     surfaces as `IsolateErrorResponse(StateError, "memory is
//     not open")`.
//   * Exceptions thrown by the memory layer are caught at this
//     boundary and packed into `IsolateErrorResponse`. The host
//     re-raises as `IsolateBoundaryException` (see
//     `isolate_messages.dart`).
//
// A.81 additions:
//
//   * Owns a `CancellationRegistry` for cancellable requests.
//   * Honors `CancelRequest` by flipping the registry's flag.
//   * Handles `OpenReadTrailStreamRequest` (backpressure proof) and
//     `OpenEventsStreamRequest` (cancellation proof) by starting an
//     async producer that pushes `StreamChunkEnvelope`s via
//     `TomWorker.sendToCreator(...)` and terminates with a
//     `StreamCompleteEnvelope` / `StreamErrorEnvelope` /
//     `StreamCancelledEnvelope`.
//   * Owns the per-stream `BackpressureTracker` map so
//     `StreamPullRequest` can hand credits to the right producer.
//   * Owns the per-stream `_streamProducers` registry so
//     `StreamCloseRequest` can signal a clean stop.

import 'dart:async';

import 'package:tom_brain_shared/tom_brain_shared.dart' show TrailId;
import 'package:tom_core_kernel/tom_core_kernel.dart' show TomExecutor, TomWorker;

import '../api/memory_stats.dart';
import '../api/tom_brain_memory.dart';
import '../nodes/node.dart';
import '../retrieval/stream_query.dart';
import '../stacks/stack_types.dart';
import 'isolate_cancellation_protocol.dart';
import 'isolate_envelopes_full.dart';
import 'isolate_messages.dart';
import 'isolate_stream_protocol.dart';
import 'memory_factory.dart';

/// The executor that owns the in-isolate `TomBrainMemory`
/// instance and translates inbound envelopes into method calls
/// against it.
///
/// Not exported from the package barrel — the host owns its
/// construction and consumers never see this type. Visible to
/// `MemoryWorkerContext` (this folder) and to tests that exercise
/// the dispatch directly.
class MemoryIsolateExecutor extends TomExecutor {
  /// The factory the executor calls when an [OpenMemoryRequest]
  /// arrives and no memory has been constructed yet. Kept as a
  /// field rather than a constructor argument so that test
  /// harnesses can replace it after construction.
  final MemoryFactory factory;

  /// A.81 — in-isolate cancellation state.
  final CancellationRegistry _cancellation = CancellationRegistry();

  /// A.81 — per-stream backpressure trackers (keyed by streamId.id).
  /// Streams without backpressure (events) do not register here.
  final Map<int, BackpressureTracker> _trackers = <int, BackpressureTracker>{};

  /// A.81 — per-stream live-producer markers (keyed by streamId.id).
  /// A producer's entry holds a `_StreamControl` block the producer
  /// loop checks every iteration; a `StreamCloseRequest` flips
  /// `closed = true` so the producer terminates cleanly.
  final Map<int, _StreamControl> _streamControls = <int, _StreamControl>{};

  TomBrainMemory? _memory;

  /// `true` once [OpenMemoryRequest] has been honoured and the
  /// memory's `open()` has completed. Lifecycle marker only —
  /// the memory itself is the source of truth for downstream
  /// behaviour.
  bool _open = false;

  /// Visible to tests only. Production callers go through the
  /// envelope protocol.
  TomBrainMemory? get memoryForTesting => _memory;

  /// Visible to tests only.
  CancellationRegistry get cancellationForTesting => _cancellation;

  /// Visible to tests only.
  int get liveStreamCount => _streamControls.length;

  MemoryIsolateExecutor(this.factory);

  @override
  Object execute(Object command) {
    if (command is! IsolateRequest) {
      return TomExecutor.noResult;
    }
    return _dispatch(command);
  }

  Future<IsolateResponse> _dispatch(IsolateRequest req) async {
    try {
      switch (req) {
        case PingRequest(:final hostWallClockMs):
          return PongResponse(
            echoedHostWallClockMs: hostWallClockMs,
            isolateWallClockMs: _wallClockMs(),
          );

        case OpenMemoryRequest(:final config):
          _memory ??= await factory();
          await _memory!.open(config);
          _open = true;
          return const OpenMemoryResponse();

        case CloseMemoryRequest():
          if (_open) {
            await _memory!.close();
            _open = false;
          }
          return const CloseMemoryResponse();

        case MemoryStatsRequest():
          final memory = _requireOpenMemory();
          final MemoryStats stats = await memory.stats();
          return MemoryStatsResponse(stats);

        // ─── A.81: cancellation control ──────────────────────────
        case CancelRequest(:final token):
          _cancellation.cancel(token);
          return const CancelResponse();

        // ─── A.81: stream control ────────────────────────────────
        case StreamPullRequest(:final streamId, :final credits):
          final tracker = _trackers[streamId.id];
          if (tracker != null && !tracker.isClosed) {
            tracker.grant(credits);
          }
          // Pull is best-effort: if the stream is gone (closed,
          // completed, or never opened on this side), we ack
          // anyway. The host's router has already dropped it.
          return const StreamPullResponse();

        case StreamCloseRequest(:final streamId):
          final ctl = _streamControls[streamId.id];
          if (ctl != null) {
            // Raises the flag (backpressured producer checkpoints) and
            // fires the close signal (unbounded producer awaits it).
            ctl.requestClose();
            // Wake any producer parked on backpressure so it can
            // observe the close flag and exit.
            _trackers[streamId.id]?.close();
          }
          return const StreamCloseResponse();

        case OpenReadTrailStreamRequest(
              :final streamId,
              :final trailId,
              :final initialCredits,
              :final cancellation,
            ):
          final memory = _requireOpenMemory();
          _startReadTrailProducer(
            streamId: streamId,
            trailId: trailId,
            initialCredits: initialCredits,
            cancellation: cancellation,
            memory: memory,
          );
          return StreamOpenedResponse(streamId);

        case OpenEventsStreamRequest(
              :final streamId,
              :final cancellation,
            ):
          final memory = _requireOpenMemory();
          _startEventsProducer(
            streamId: streamId,
            cancellation: cancellation,
            memory: memory,
          );
          return StreamOpenedResponse(streamId);

        // ─── A.82: lifecycle rest ────────────────────────────────
        case CheckpointRequest():
          await _requireOpenMemory().checkpoint();
          return const CheckpointResponse();

        // ─── A.82: WriteBudget enforcement ───────────────────────
        case BeginRunRequest(:final runId, :final budget):
          await _requireOpenMemory()
              .beginRun(runId: runId, budget: budget);
          return const BeginRunResponse();

        case EndRunRequest(:final runId):
          await _requireOpenMemory().endRun(runId);
          return const EndRunResponse();

        case RemainingBudgetRequest(:final runId):
          final b = await _requireOpenMemory().remainingBudget(runId);
          return RemainingBudgetResponse(b);

        // ─── A.82: node CRUD ─────────────────────────────────────
        case PersistRequest(:final draft, :final scope):
          final id = await _requireOpenMemory()
              .persist(draft, scope: scope);
          return PersistResponse(id);

        case GetNodeRequest(:final id):
          final n = await _requireOpenMemory().get(id);
          return GetNodeResponse(n);

        case GetManyRequest(:final ids):
          final ns = await _requireOpenMemory().getMany(ids);
          return GetManyResponse(ns);

        case DemoteRequest(:final id, :final reason):
          await _requireOpenMemory().demote(id, reason);
          return const DemoteResponse();

        case ForgetRequest(:final id, :final reason):
          await _requireOpenMemory().forget(id, reason);
          return const ForgetResponse();

        // ─── A.82: edges ─────────────────────────────────────────
        case CreateEdgeRequest(
              :final from,
              :final type,
              :final to,
              :final scope,
              :final weight,
              :final attrs,
            ):
          final eid = await _requireOpenMemory().edge(
            from,
            type,
            to,
            scope: scope,
            weight: weight,
            attrs: attrs,
          );
          return CreateEdgeResponse(eid);

        case EdgesOfRequest(:final id, :final direction, :final types):
          final es = await _requireOpenMemory()
              .edgesOf(id, direction: direction, types: types);
          return EdgesOfResponse(es);

        // ─── A.82: node-type registry ────────────────────────────
        case RegisterNodeTypeRequest(:final decl):
          await _requireOpenMemory().registerNodeType(decl);
          return const RegisterNodeTypeResponse();

        case ListNodeTypesRequest():
          final ts = await _requireOpenMemory().listNodeTypes();
          return ListNodeTypesResponse(ts);

        case GetNodeTypeRequest(:final typeName):
          final t = await _requireOpenMemory().getNodeType(typeName);
          return GetNodeTypeResponse(t);

        // ─── A.82: retrieval ─────────────────────────────────────
        case RecallRequest(:final query):
          final r = await _requireOpenMemory().recall(query);
          return RecallResponse(r);

        case OpenStreamQueryRequest(
              :final streamId,
              :final query,
              :final initialCredits,
              :final cancellation,
            ):
          final memory = _requireOpenMemory();
          _startStreamQueryProducer(
            streamId: streamId,
            query: query,
            initialCredits: initialCredits,
            cancellation: cancellation,
            memory: memory,
          );
          return StreamOpenedResponse(streamId);

        // ─── A.82: classification ────────────────────────────────
        case ClassifyRequest(:final embedding, :final target):
          final r = await _requireOpenMemory()
              .classify(embedding, target: target);
          return ClassifyResponse(r);

        case UpdateCentroidRequest(:final forKey, :final centroid):
          await _requireOpenMemory().updateCentroid(forKey, centroid);
          return const UpdateCentroidResponse();

        case FindUncertainRequest(
              :final forKey,
              :final low,
              :final high,
              :final limit,
            ):
          final ids = await _requireOpenMemory().findUncertain(
            forKey: forKey,
            low: low,
            high: high,
            limit: limit,
          );
          return FindUncertainResponse(ids);

        // ─── A.82: stacks ────────────────────────────────────────
        case StacksListRequest():
          final s = await _requireOpenMemory().stacks.list();
          return StacksListResponse(s);

        case StacksInfoRequest(:final name):
          final i = await _requireOpenMemory().stacks.info(name);
          return StacksInfoResponse(i);

        case StacksCreateRequest(:final decl):
          await _requireOpenMemory().stacks.create(decl);
          return const StacksCreateResponse();

        case StacksUpdatePolicyRequest(:final name, :final policy):
          await _requireOpenMemory().stacks.updatePolicy(name, policy);
          return const StacksUpdatePolicyResponse();

        case StacksDeleteRequest(:final name):
          await _requireOpenMemory().stacks.delete(name);
          return const StacksDeleteResponse();

        case StacksPushRequest(
              :final name,
              :final entry,
              :final priority,
              :final attrs,
              :final scope,
            ):
          final id = await _requireOpenMemory().stacks.push(
            name,
            entry,
            priority: priority,
            attrs: attrs,
            scope: scope,
          );
          return StacksPushResponse(id);

        case StacksPeekRequest(:final name, :final k):
          final es = await _requireOpenMemory().stacks.peek(name, k: k);
          return StacksPeekResponse(es);

        case StacksPopRequest(:final name):
          final e = await _requireOpenMemory().stacks.pop(name);
          return StacksPopResponse(e);

        case StacksUpdateRequest(
              :final name,
              :final entry,
              :final priority,
              :final status,
              :final attrs,
            ):
          await _requireOpenMemory().stacks.update(
            name,
            entry,
            priority: priority,
            status: status,
            attrs: attrs,
          );
          return const StacksUpdateResponse();

        case StacksRemoveRequest(:final name, :final entry):
          await _requireOpenMemory().stacks.remove(name, entry);
          return const StacksRemoveResponse();

        case OpenStacksArchivedStreamRequest(
              :final streamId,
              :final name,
              :final limit,
              :final initialCredits,
              :final cancellation,
            ):
          final memory = _requireOpenMemory();
          _startStacksArchivedProducer(
            streamId: streamId,
            name: name,
            limit: limit,
            initialCredits: initialCredits,
            cancellation: cancellation,
            memory: memory,
          );
          return StreamOpenedResponse(streamId);

        case OpenStacksEventsStreamRequest(
              :final streamId,
              :final name,
              :final cancellation,
            ):
          final memory = _requireOpenMemory();
          _startStacksEventsProducer(
            streamId: streamId,
            name: name,
            cancellation: cancellation,
            memory: memory,
          );
          return StreamOpenedResponse(streamId);

        // ─── A.82: trails ────────────────────────────────────────
        case OpenTrailRequest(:final run):
          final id = await _requireOpenMemory().openTrail(run);
          return OpenTrailResponse(id);

        case AppendTrailRequest(:final id, :final entry):
          await _requireOpenMemory().appendTrail(id, entry);
          return const AppendTrailResponse();

        case TrailCloseRequest(:final id, :final outcome):
          await _requireOpenMemory().closeTrail(id, outcome);
          return const TrailCloseResponse();

        // ─── A.82: migrations ────────────────────────────────────
        case MigrationsStartRequest(:final decl):
          await _requireOpenMemory().migrations.start(decl);
          return const MigrationsStartResponse();

        case MigrationsCursorRequest(:final migrationId):
          final c = await _requireOpenMemory()
              .migrations
              .cursor(migrationId);
          return MigrationsCursorResponse(c);

        case MigrationsSaveCursorRequest(
              :final migrationId,
              :final position,
            ):
          await _requireOpenMemory()
              .migrations
              .saveCursor(migrationId, position);
          return const MigrationsSaveCursorResponse();

        case MigrationsStatusRequest(:final migrationId):
          final s = await _requireOpenMemory()
              .migrations
              .status(migrationId);
          return MigrationsStatusResponse(s);

        case MigrationsListInProgressRequest():
          final ss =
              await _requireOpenMemory().migrations.listInProgress();
          return MigrationsListInProgressResponse(ss);

        default:
          return IsolateErrorResponse(
            exceptionType: 'UnknownIsolateRequest',
            message:
                'No dispatch handler for ${req.runtimeType}. '
                'Was the envelope added to the catalogue but not '
                'wired into MemoryIsolateExecutor?',
          );
      }
    } catch (e) {
      return IsolateErrorResponse(
        exceptionType: e.runtimeType.toString(),
        message: e.toString(),
      );
    }
  }

  // ─── A.81: stream producers ────────────────────────────────────

  /// Spawns the async producer for a `readTrail` stream. The
  /// producer pushes one [StreamChunkEnvelope] per `TrailEntry`,
  /// waiting on the [BackpressureTracker] before each push.
  ///
  /// A `readTrail` stream is an ordinary backpressured stream whose
  /// source is `memory.readTrail(trailId)`; the generic producer owns
  /// the credit/cancel/close machinery (review D.2.8). The element
  /// type (`TrailEntry`) is inferred from the source.
  void _startReadTrailProducer({
    required StreamId streamId,
    required TrailId trailId,
    required int initialCredits,
    required CancellationToken? cancellation,
    required TomBrainMemory memory,
  }) {
    _startBackpressuredProducer(
      streamId: streamId,
      initialCredits: initialCredits,
      cancellation: cancellation,
      source: () => memory.readTrail(trailId),
    );
  }

  /// Spawns a backpressured producer over `stream(StreamQuery)`. Same
  /// shape as `_startReadTrailProducer` (chunk by chunk, credits per
  /// chunk) — the source happens to be `memory.stream(query)`.
  void _startStreamQueryProducer({
    required StreamId streamId,
    required StreamQuery query,
    required int initialCredits,
    required CancellationToken? cancellation,
    required TomBrainMemory memory,
  }) {
    _startBackpressuredProducer<Node>(
      streamId: streamId,
      initialCredits: initialCredits,
      cancellation: cancellation,
      source: () => memory.stream(query),
    );
  }

  /// Spawns a backpressured producer over `stacks.streamArchived`.
  void _startStacksArchivedProducer({
    required StreamId streamId,
    required String name,
    required int? limit,
    required int initialCredits,
    required CancellationToken? cancellation,
    required TomBrainMemory memory,
  }) {
    _startBackpressuredProducer<StackEntry>(
      streamId: streamId,
      initialCredits: initialCredits,
      cancellation: cancellation,
      source: () => memory.stacks.streamArchived(name, limit: limit),
    );
  }

  /// Spawns an unbounded producer over `stacks.events(name)`. Same
  /// shape as the lifecycle `events()` producer.
  void _startStacksEventsProducer({
    required StreamId streamId,
    required String name,
    required CancellationToken cancellation,
    required TomBrainMemory memory,
  }) {
    _startUnboundedProducer<StackEvent>(
      streamId: streamId,
      cancellation: cancellation,
      source: () => memory.stacks.events(name),
    );
  }

  /// Generic backpressured producer. Pulls one item at a time from
  /// [source], waits for credit on each push, honors close/cancel at
  /// every checkpoint. Used by `readTrail`, `stream(query)`, and
  /// `stacks.streamArchived` — they all share this contract.
  void _startBackpressuredProducer<T>({
    required StreamId streamId,
    required int initialCredits,
    required CancellationToken? cancellation,
    required Stream<T> Function() source,
  }) {
    final tracker = BackpressureTracker(initialCredits: initialCredits);
    _trackers[streamId.id] = tracker;
    final control = _StreamControl();
    _streamControls[streamId.id] = control;

    CancellationHandle? handle;
    if (cancellation != null) {
      handle = _cancellation.register(cancellation);
    }

    unawaited(() async {
      var seq = 0;
      try {
        await for (final item in source()) {
          if (control.closeRequested ||
              (handle?.isCancelled ?? false)) {
            _sendStreamMessage(StreamCancelledEnvelope(
              streamId: streamId,
              token: cancellation,
            ));
            return;
          }
          try {
            await tracker.awaitCredit();
          } on StateError {
            _sendStreamMessage(StreamCancelledEnvelope(
              streamId: streamId,
              token: cancellation,
            ));
            return;
          }
          if (control.closeRequested ||
              (handle?.isCancelled ?? false)) {
            _sendStreamMessage(StreamCancelledEnvelope(
              streamId: streamId,
              token: cancellation,
            ));
            return;
          }
          _sendStreamMessage(StreamChunkEnvelope(
            streamId: streamId,
            sequence: seq,
            payload: item,
          ));
          tracker.consume(1);
          seq += 1;
        }
        _sendStreamMessage(StreamCompleteEnvelope(
          streamId: streamId,
          sequence: seq,
        ));
      } catch (e) {
        _sendStreamMessage(StreamErrorEnvelope(
          streamId: streamId,
          message: e.toString(),
          exceptionType: e.runtimeType.toString(),
        ));
      } finally {
        if (!tracker.isClosed) tracker.close();
        _trackers.remove(streamId.id);
        _streamControls.remove(streamId.id);
        handle?.dispose();
      }
    }());
  }

  /// Generic unbounded producer. No backpressure tracker; termination
  /// is purely via cancellation / close / source completion.
  void _startUnboundedProducer<T>({
    required StreamId streamId,
    required CancellationToken cancellation,
    required Stream<T> Function() source,
  }) {
    final control = _StreamControl();
    _streamControls[streamId.id] = control;
    final handle = _cancellation.register(cancellation);

    unawaited(() async {
      var seq = 0;
      StreamSubscription<T>? sub;
      try {
        // Completes when the source finishes (done or error). Producer
        // termination is the first of: source finishing, a
        // `StreamCloseRequest`, or cancellation — all three are
        // futures, so we `await` whichever fires first rather than
        // polling the flags on a timer (review D.5.2).
        final sourceFinished = Completer<void>();
        sub = source().listen(
          (item) {
            if (control.closeRequested || handle.isCancelled) return;
            _sendStreamMessage(StreamChunkEnvelope(
              streamId: streamId,
              sequence: seq,
              payload: item,
            ));
            seq += 1;
          },
          onError: (Object e) {
            if (!sourceFinished.isCompleted) {
              _sendStreamMessage(StreamErrorEnvelope(
                streamId: streamId,
                message: e.toString(),
                exceptionType: e.runtimeType.toString(),
              ));
              sourceFinished.complete();
            }
          },
          onDone: () {
            if (!sourceFinished.isCompleted) {
              _sendStreamMessage(StreamCompleteEnvelope(
                streamId: streamId,
                sequence: seq,
              ));
              sourceFinished.complete();
            }
          },
        );
        await Future.any<void>(<Future<void>>[
          sourceFinished.future,
          control.closeSignal.future,
          handle.cancelled,
        ]);
        // If the source had not already finished, the wake-up was a
        // close or cancel; emit the cancelled envelope to close the
        // host-side stream cleanly.
        if (!sourceFinished.isCompleted &&
            (control.closeRequested || handle.isCancelled)) {
          _sendStreamMessage(StreamCancelledEnvelope(
            streamId: streamId,
            token: cancellation,
          ));
        }
      } catch (e) {
        _sendStreamMessage(StreamErrorEnvelope(
          streamId: streamId,
          message: e.toString(),
          exceptionType: e.runtimeType.toString(),
        ));
      } finally {
        await sub?.cancel();
        _streamControls.remove(streamId.id);
        handle.dispose();
      }
    }());
  }

  /// Spawns the async producer for an `events()` stream. Unbounded
  /// (no backpressure tracker). Termination is exclusively via
  /// cancellation or `StreamCloseRequest`.
  ///
  /// The lifecycle event stream is an ordinary unbounded stream whose
  /// source is `memory.events()`; the generic producer owns the
  /// subscribe/cancel/close machinery (review D.2.8). The element type
  /// (`MemoryEvent`) is inferred from the source.
  void _startEventsProducer({
    required StreamId streamId,
    required CancellationToken cancellation,
    required TomBrainMemory memory,
  }) {
    _startUnboundedProducer(
      streamId: streamId,
      cancellation: cancellation,
      source: () => memory.events(),
    );
  }

  /// One indirection so tests can swap the transport. In production
  /// we go through `TomWorker.sendToCreator`; in unit tests where
  /// there is no creator isolate we no-op (the executor is exercised
  /// directly, the side channel is verified by integration tests).
  void _sendStreamMessage(StreamSideChannelMessage message) {
    if (TomWorker.canSendToCreator()) {
      TomWorker.sendToCreator(message);
    }
  }

  TomBrainMemory _requireOpenMemory() {
    if (!_open || _memory == null) {
      throw StateError(
        'Memory is not open. Send OpenMemoryRequest before any '
        'other envelope.',
      );
    }
    return _memory!;
  }

  /// Wall-clock millisecond reading echoed in [PongResponse]. Named
  /// for what it is — `DateTime.now()` is not monotonic; the ping
  /// round-trip is measured against the host's single clock, so this
  /// is only ever used for the same-process delta, never for
  /// cross-process duration arithmetic.
  static int _wallClockMs() => DateTime.now().millisecondsSinceEpoch;
}

/// Internal per-stream control block. Held by the executor's
/// `_streamControls` map. A `StreamCloseRequest` calls [requestClose],
/// which both raises the flag (read at the backpressured producer's
/// checkpoints) and fires [closeSignal] (awaited by the unbounded
/// producer instead of a poll timer — review D.5.2).
class _StreamControl {
  bool closeRequested = false;

  /// Completes the first time [requestClose] is called. Never
  /// completes if the stream is not asked to close.
  final Completer<void> closeSignal = Completer<void>();

  /// Idempotently flags the stream for close and fires [closeSignal].
  void requestClose() {
    closeRequested = true;
    if (!closeSignal.isCompleted) closeSignal.complete();
  }
}
