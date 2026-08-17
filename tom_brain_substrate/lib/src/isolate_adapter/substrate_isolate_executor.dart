// SubstrateIsolateExecutor — the in-isolate `TomExecutor` that
// dispatches `IsolateRequest` envelopes to the held
// `TomBrainSubstrateClient` instance (Tom Brain completion-plan
// item #12).
//
// Constructed inside `SubstrateWorkerContext.initializeIsolate` and
// registered via `TomWorker.addExecutor` (the per-isolate registry).
// One instance per isolate; lifetime equals isolate lifetime. Unlike
// the memory executor, the client is built *eagerly* by the boot
// context and handed to this executor's constructor — the substrate
// surface has no require-open gate, so there is no lazy-construct step.
//
// Dispatch rules:
//
//   * Handles `IsolateRequest` envelopes only; anything else surfaces
//     as `TomExecutor.noResult` so the executor chain can pass it on.
//   * Every unary reply piggybacks a fresh `SubstrateStats` snapshot so
//     the proxy can answer its synchronous `stats()` from cache.
//   * Exceptions are caught at this boundary and packed via
//     `SubstrateIsolateExceptions.pack`; the host re-raises the typed
//     exception (or `IsolateBoundaryException` outside the taxonomy).
//
// Streaming:
//
//   `completeStream` and `events` are both **unbounded**. The producer
//   subscribes to the source, pushes each (sanitized) event as a
//   `StreamChunkEnvelope`, and terminates on the first of: source done
//   / source error / host close request. There is no backpressure and
//   no cancellation token — an LLM stream self-terminates and the host
//   tears it down via `StreamCloseRequest`.

import 'dart:async';

import 'package:tom_core_agentic/tom_core_agentic.dart'
    show IsolateStreamCloseSignal;
import 'package:tom_core_kernel/tom_core_kernel.dart' show TomExecutor, TomWorker;

import '../api/llm_stream_event.dart';
import '../api/substrate_event.dart';
import '../api/tom_brain_substrate_client.dart';
import 'substrate_isolate_exceptions.dart';
import 'substrate_isolate_messages.dart';
import 'substrate_stream_protocol.dart';

/// The executor that owns the in-isolate `TomBrainSubstrateClient`
/// instance and translates inbound envelopes into method calls.
///
/// Not exported from the package barrel — the host owns its
/// construction and consumers never see this type.
class SubstrateIsolateExecutor extends TomExecutor {
  final TomBrainSubstrateClient _client;

  /// Per-stream close-signal blocks (keyed by `streamId.id`). A
  /// `StreamCloseRequest` fires the signal so the producer exits.
  final Map<int, IsolateStreamCloseSignal> _streamControls =
      <int, IsolateStreamCloseSignal>{};

  /// Visible to tests only.
  int get liveStreamCount => _streamControls.length;

  SubstrateIsolateExecutor(this._client);

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

        case OpenSubstrateRequest(:final config):
          await _client.open(config);
          return OpenSubstrateResponse(stats: _client.stats());

        case CloseSubstrateRequest():
          await _client.close();
          return CloseSubstrateResponse(stats: _client.stats());

        case CompleteRequest(:final call):
          final report = await _client.complete(call);
          return CompleteResponse(report: report, stats: _client.stats());

        case EmbedRequest(:final text):
          final result = await _client.embed(text);
          return EmbedResponse(result: result, stats: _client.stats());

        case EmbedBatchRequest(:final texts):
          final results = await _client.embedBatch(texts);
          return EmbedBatchResponse(results: results, stats: _client.stats());

        case WebSearchRequest(:final query, :final options):
          final result = await _client.webSearch(query, options: options);
          return WebSearchResponse(result: result, stats: _client.stats());

        case WebFetchRequest(:final url, :final options):
          final result = await _client.webFetch(url, options: options);
          return WebFetchResponse(result: result, stats: _client.stats());

        case OpenCompleteStreamRequest(:final streamId, :final call):
          _startUnboundedProducer<LlmStreamEvent>(
            streamId: streamId,
            source: () => _client.completeStream(call),
            sanitize: _sanitizeStreamEvent,
          );
          return StreamOpenedResponse(streamId);

        case OpenEventsStreamRequest(:final streamId):
          _startUnboundedProducer<SubstrateEvent>(
            streamId: streamId,
            source: () => _client.events(),
            sanitize: _sanitizeSubstrateEvent,
          );
          return StreamOpenedResponse(streamId);

        case StreamCloseRequest(:final streamId):
          _streamControls[streamId.id]?.requestClose();
          return const StreamCloseResponse();

        default:
          return IsolateErrorResponse(
            exceptionType: 'UnknownIsolateRequest',
            message: 'No dispatch handler for ${req.runtimeType}. '
                'Was the envelope added to the catalogue but not wired '
                'into SubstrateIsolateExecutor?',
          );
      }
    } catch (e) {
      final packed = SubstrateIsolateExceptions.pack(e);
      return IsolateErrorResponse(
        exceptionType: packed?.type ?? e.runtimeType.toString(),
        message: packed?.message ?? e.toString(),
        details: packed?.details ?? const <String, Object?>{},
      );
    }
  }

  /// Generic unbounded producer. No backpressure; termination is the
  /// first of: source completion, source error, or a host
  /// `StreamCloseRequest`. Each item is passed through [sanitize] (to
  /// null any non-sendable `LlmFailure.cause`) before it is shipped.
  void _startUnboundedProducer<T>({
    required StreamId streamId,
    required Stream<T> Function() source,
    required T Function(T) sanitize,
  }) {
    final control = IsolateStreamCloseSignal();
    _streamControls[streamId.id] = control;

    unawaited(() async {
      var seq = 0;
      StreamSubscription<T>? sub;
      try {
        final sourceFinished = Completer<void>();
        sub = source().listen(
          (item) {
            if (control.closeRequested) return;
            _sendStreamMessage(StreamChunkEnvelope(
              streamId: streamId,
              sequence: seq,
              payload: sanitize(item),
            ));
            seq += 1;
          },
          onError: (Object e) {
            if (!sourceFinished.isCompleted) {
              _sendStreamMessage(_streamError(streamId, e));
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
        ]);
        // If the source had not already finished, the wake-up was a
        // host close request; emit the cancelled envelope so the
        // host-side stream closes cleanly.
        if (!sourceFinished.isCompleted && control.closeRequested) {
          _sendStreamMessage(StreamCancelledEnvelope(streamId: streamId));
        }
      } catch (e) {
        _sendStreamMessage(_streamError(streamId, e));
      } finally {
        await sub?.cancel();
        _streamControls.remove(streamId.id);
      }
    }());
  }

  /// Builds a [StreamErrorEnvelope] for [streamId] from [error], routing
  /// it through the closed-taxonomy codec so the host rebuilds the typed
  /// instance.
  StreamErrorEnvelope _streamError(StreamId streamId, Object error) {
    final packed = SubstrateIsolateExceptions.pack(error);
    return StreamErrorEnvelope(
      streamId: streamId,
      message: packed?.message ?? error.toString(),
      exceptionType: packed?.type ?? error.runtimeType.toString(),
      details: packed?.details ?? const <String, Object?>{},
    );
  }

  /// One indirection so direct-dispatch tests (no creator isolate) do
  /// not crash on `sendToCreator`. In production we go through
  /// `TomWorker.sendToCreator`.
  void _sendStreamMessage(StreamSideChannelMessage message) {
    if (TomWorker.canSendToCreator()) {
      TomWorker.sendToCreator(message);
    }
  }

  /// Strips the one non-sendable field (`LlmFailure.cause`) from a
  /// failure event; all other event shapes are already sendable.
  static LlmStreamEvent _sanitizeStreamEvent(LlmStreamEvent e) {
    if (e is LlmStreamFailed) {
      return LlmStreamFailed(
        callId: e.callId,
        failure: LlmFailure(
          classCode: e.failure.classCode,
          message: e.failure.message,
        ),
        report: e.report,
      );
    }
    return e;
  }

  /// Strips the one non-sendable field (`LlmFailure.cause`) from a
  /// failed substrate event; all other event shapes are already
  /// sendable.
  static SubstrateEvent _sanitizeSubstrateEvent(SubstrateEvent e) {
    if (e is LlmCallFailed) {
      return LlmCallFailed(
        occurredAt: e.occurredAt,
        runId: e.runId,
        causedBy: e.causedBy,
        callId: e.callId,
        failure: LlmFailure(
          classCode: e.failure.classCode,
          message: e.failure.message,
        ),
        providerId: e.providerId,
        modelId: e.modelId,
        retryCount: e.retryCount,
      );
    }
    return e;
  }

  static int _wallClockMs() => DateTime.now().millisecondsSinceEpoch;
}
