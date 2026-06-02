// SSE delivery path (OpenAI) — the concrete `ChannelDelivery` for
// `AccessChannel.openai` (E.37; proto spec § 5.3 / § 10.1; AC-2).
//
// What this file owns:
//
//   * `SseSink` — the wire the SSE path writes already-rendered
//     `data: …\n\n` frames to. Abstracting the wire (rather than writing a
//     `StreamController` directly) keeps the delivery path testable without a
//     socket: tests collect frames in memory; boot (E.41+) backs it with the
//     shelf response body.
//
//   * `StreamControllerSseSink` — the runtime sink. Frames are UTF-8 encoded
//     onto a `StreamController<List<int>>` whose `body` stream the OpenAI
//     adapter returns as the `text/event-stream` response body (E.41+ wires
//     it). One sink per inbound streaming request.
//
//   * `SseDeliveryBinding` — the per-`Access` `DeliveryBinding` subtype for
//     the OpenAI channel. It carries the channel-specific state the path
//     needs: the `SseSink` to write to and the `ChatCompletionSseRenderer`
//     (E.13) that turns each `OutboundChunk` into its `chat.completion.chunk`
//     frame. The renderer is bound here — not built inside the path — because
//     the OpenAI shape requires every chunk of one completion to repeat the
//     same `id` / `created`, and those are fixed when the binding is assembled
//     (the adapter / boot knows the resolved persona-as-model at that point,
//     E.15).
//
//   * `SseChannelDelivery` — the `ChannelDelivery` the `DeliveryRegistry`
//     (E.36) dispatches `AccessChannel.openai` to. `bindDeliver` mints the
//     per-`Access` `DeliverCallback`: each `OutboundChunk` is rendered to one
//     SSE frame and written to the binding's sink; the final chunk
//     (`isFinal`) additionally writes the terminal `data: [DONE]\n\n` line and
//     closes the wire, so `[DONE]` is always the last line on the wire (proto
//     spec § 5.3).
//
// What this file does NOT do:
//
//   * No chunk sourcing — the engine pushes chunks through the produced
//     `DeliverCallback`; the dispatcher/engine wiring is boot's job (E.41+).
//   * No backpressure protocol — `DeliveryStalled` and the richer
//     SSE-disconnect cancellation land at E.39 / E.40. The callback returns an
//     empty backpressure stream for now (no stall signalled); a client
//     disconnect cancels the body subscription, which the runtime sink
//     surfaces through its controller's `onCancel`.
//   * No persona resolution — the renderer's `model` is already the resolved
//     persona-as-model id (E.15), fixed when the binding was built.

import 'dart:async';
import 'dart:convert';

import 'package:tom_brain_shared/tom_brain_shared.dart';

import '../adapters/openai_http_sse/chat_completion_sse.dart';
import '../identity/session_manager.dart' show AccessChannel;
import 'channel_delivery.dart';

/// The wire one OpenAI streaming response is delivered over.
///
/// The SSE delivery path renders each [OutboundChunk] to a `data: …\n\n`
/// frame (via [ChatCompletionSseRenderer]) and [write]s it here, then [close]s
/// the wire after the terminal `data: [DONE]\n\n` line. Abstracting the wire
/// lets the delivery path stay socket-free in tests (an in-memory sink) while
/// boot backs it with the shelf response body ([StreamControllerSseSink]).
abstract interface class SseSink {
  /// Writes one already-rendered SSE frame to the wire.
  ///
  /// [frame] is a complete `data: …\n\n` line (or the terminal
  /// `data: [DONE]\n\n`) — the SSE path renders it; the sink only transports
  /// it. Writing after [close] is a contract violation (the wire is gone) and
  /// throws [StateError].
  void write(String frame);

  /// Closes the wire after the terminal frame. Idempotent: closing an
  /// already-closed sink is a no-op.
  Future<void> close();

  /// Whether [close] has been called.
  bool get isClosed;
}

/// The runtime [SseSink]: frames are UTF-8 encoded onto a
/// `StreamController<List<int>>` whose [body] stream is the `text/event-stream`
/// response body the OpenAI adapter returns (E.41+ wires it).
///
/// One instance per inbound streaming request. The controller is *not*
/// broadcast — exactly one consumer (the HTTP response) listens. A client
/// disconnect cancels that subscription; [onClientDisconnect], when supplied,
/// fires so a later step (E.39 / E.40) can cancel the run rather than render
/// into a dead wire.
final class StreamControllerSseSink implements SseSink {
  late final StreamController<List<int>> _controller =
      StreamController<List<int>>(
    onCancel: _handleCancel,
  );

  /// Called once when the [body] subscription is cancelled (the SSE client
  /// disconnected). Optional; the richer cancellation protocol is E.39 / E.40.
  final void Function()? _onClientDisconnect;

  bool _closed = false;

  /// Builds a runtime SSE sink. [onClientDisconnect] — when supplied — fires
  /// once if the response-body subscription is cancelled before the answer
  /// finishes (a client disconnect); the prototype leaves the run-cancellation
  /// reaction to E.39 / E.40.
  StreamControllerSseSink({void Function()? onClientDisconnect})
      : _onClientDisconnect = onClientDisconnect;

  /// The UTF-8 byte stream of SSE frames — the OpenAI `text/event-stream`
  /// response body. Single-subscription: the one HTTP response listens.
  Stream<List<int>> get body => _controller.stream;

  @override
  bool get isClosed => _closed;

  @override
  void write(String frame) {
    if (_closed) {
      throw StateError(
        'SSE frame written after the wire was closed — the OpenAI delivery '
        'path must not write past the terminal `[DONE]` frame',
      );
    }
    _controller.add(utf8.encode(frame));
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _controller.close();
  }

  void _handleCancel() {
    final void Function()? onDisconnect = _onClientDisconnect;
    if (onDisconnect != null && !_closed) {
      onDisconnect();
    }
  }
}

/// The per-`Access` [DeliveryBinding] for the OpenAI SSE channel (E.37).
///
/// Carries the channel-specific state [SseChannelDelivery] needs to stream one
/// answer back: the [sink] (the wire) and the [renderer] (the
/// `chat.completion.chunk` frame builder, E.13). The base-class [identity] /
/// [envelope] are what the [DeliveryRegistry] reads to emit the correlated
/// [AccessDelivered] (E.36); [channel] is fixed to [AccessChannel.openai] so
/// the registry routes here.
final class SseDeliveryBinding implements DeliveryBinding {
  @override
  final ResolvedIdentity identity;

  @override
  final InboundRequest envelope;

  /// The wire this answer is delivered over.
  final SseSink sink;

  /// The frame renderer (E.13). Bound per-`Access` so its `id` / `created` are
  /// fixed across every chunk of this completion, as the OpenAI shape
  /// requires; its `model` is the resolved persona-as-model id (E.15).
  final ChatCompletionSseRenderer renderer;

  /// Builds the binding for one OpenAI streaming request.
  const SseDeliveryBinding({
    required this.identity,
    required this.envelope,
    required this.sink,
    required this.renderer,
  });

  /// Always [AccessChannel.openai] — this binding only ever routes to the SSE
  /// path.
  @override
  AccessChannel get channel => AccessChannel.openai;
}

/// The OpenAI SSE outbound delivery path (E.37).
///
/// Registered with the [DeliveryRegistry] (E.36) for [AccessChannel.openai].
/// Per inbound streaming request the registry calls [bindDeliver] with the
/// request's [SseDeliveryBinding] to mint the [DeliverCallback] the engine
/// streams the answer through: each [OutboundChunk] becomes one
/// `chat.completion.chunk` `data: …\n\n` frame written to the binding's sink,
/// and the final chunk additionally writes `data: [DONE]\n\n` and closes the
/// wire (proto spec § 5.3).
final class SseChannelDelivery implements ChannelDelivery {
  /// Builds the SSE delivery path. Stateless across requests — all per-`Access`
  /// state lives on the [SseDeliveryBinding].
  const SseChannelDelivery();

  @override
  AccessChannel get channel => AccessChannel.openai;

  @override
  DeliverCallback bindDeliver(covariant SseDeliveryBinding binding) {
    final SseSink sink = binding.sink;
    final ChatCompletionSseRenderer renderer = binding.renderer;
    bool terminated = false;

    return (OutboundChunk chunk) {
      if (terminated) {
        // The engine contract is "exactly one final chunk, last"; a chunk
        // after the terminal frame would render into a closed wire. Surface
        // it loudly rather than corrupt the stream or swallow a real bug.
        throw StateError(
          'OutboundChunk delivered after the final chunk — the OpenAI SSE '
          'path has already written `[DONE]` and closed the wire',
        );
      }

      sink.write(renderer.frameFor(chunk));
      if (chunk.isFinal) {
        terminated = true;
        sink.write(ChatCompletionSseRenderer.doneFrame);
        // The wire close is irreversible and not awaited here: this is the
        // last chunk, and the `DeliverCallback` signature is synchronous in
        // its return of the (empty, for E.37) backpressure stream.
        unawaited(sink.close());
      }

      // No backpressure signalled in the prototype — E.39 / E.40 fill the
      // `DeliveryStalled` protocol through this returned stream.
      return const Stream<OutboundChunk>.empty();
    };
  }
}
