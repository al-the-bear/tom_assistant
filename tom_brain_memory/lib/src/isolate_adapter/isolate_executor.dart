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

import '../api/memory_event.dart';
import '../api/memory_stats.dart';
import '../api/tom_brain_memory.dart';
import 'isolate_cancellation_protocol.dart';
import 'isolate_envelopes.dart';
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
        case PingRequest(:final hostMonotonicMs):
          return PongResponse(
            echoedHostMonotonicMs: hostMonotonicMs,
            isolateMonotonicMs: _monotonicMs(),
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
            ctl.closeRequested = true;
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
  void _startReadTrailProducer({
    required StreamId streamId,
    required TrailId trailId,
    required int initialCredits,
    required CancellationToken? cancellation,
    required TomBrainMemory memory,
  }) {
    final tracker = BackpressureTracker(initialCredits: initialCredits);
    _trackers[streamId.id] = tracker;
    final control = _StreamControl();
    _streamControls[streamId.id] = control;

    CancellationHandle? handle;
    if (cancellation != null) {
      handle = _cancellation.register(cancellation);
    }

    // Fire-and-forget; errors are funnelled into the terminal
    // envelope.
    unawaited(() async {
      var seq = 0;
      try {
        await for (final entry in memory.readTrail(trailId)) {
          if (control.closeRequested) {
            _sendStreamMessage(StreamCancelledEnvelope(
              streamId: streamId,
              token: cancellation,
            ));
            return;
          }
          if (handle?.isCancelled ?? false) {
            _sendStreamMessage(StreamCancelledEnvelope(
              streamId: streamId,
              token: cancellation,
            ));
            return;
          }
          try {
            await tracker.awaitCredit();
          } on StateError {
            // Tracker closed mid-wait — treat as cancellation.
            _sendStreamMessage(StreamCancelledEnvelope(
              streamId: streamId,
              token: cancellation,
            ));
            return;
          }
          // Re-check after awaiting (close may have arrived while
          // we were parked).
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
            payload: entry,
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
        if (!tracker.isClosed) {
          tracker.close();
        }
        _trackers.remove(streamId.id);
        _streamControls.remove(streamId.id);
        handle?.dispose();
      }
    }());
  }

  /// Spawns the async producer for an `events()` stream. Unbounded
  /// (no backpressure tracker). Termination is exclusively via
  /// cancellation or `StreamCloseRequest`.
  void _startEventsProducer({
    required StreamId streamId,
    required CancellationToken cancellation,
    required TomBrainMemory memory,
  }) {
    final control = _StreamControl();
    _streamControls[streamId.id] = control;
    final handle = _cancellation.register(cancellation);

    unawaited(() async {
      var seq = 0;
      StreamSubscription<MemoryEvent>? sub;
      try {
        final controller = Completer<void>();
        sub = memory.events().listen(
          (event) {
            if (control.closeRequested || handle.isCancelled) return;
            _sendStreamMessage(StreamChunkEnvelope(
              streamId: streamId,
              sequence: seq,
              payload: event,
            ));
            seq += 1;
          },
          onError: (Object e) {
            if (!controller.isCompleted) {
              _sendStreamMessage(StreamErrorEnvelope(
                streamId: streamId,
                message: e.toString(),
                exceptionType: e.runtimeType.toString(),
              ));
              controller.complete();
            }
          },
          onDone: () {
            if (!controller.isCompleted) {
              _sendStreamMessage(StreamCompleteEnvelope(
                streamId: streamId,
                sequence: seq,
              ));
              controller.complete();
            }
          },
        );
        // Park until the source ends OR cancellation/close fires.
        while (!controller.isCompleted) {
          if (control.closeRequested || handle.isCancelled) {
            _sendStreamMessage(StreamCancelledEnvelope(
              streamId: streamId,
              token: cancellation,
            ));
            controller.complete();
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 4));
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

  static int _monotonicMs() => DateTime.now().millisecondsSinceEpoch;
}

/// Internal per-stream control block. Held by the executor's
/// `_streamControls` map; the producer loop checks `closeRequested`
/// every iteration so a `StreamCloseRequest` can stop a long-
/// running stream without throwing.
class _StreamControl {
  bool closeRequested = false;
}
