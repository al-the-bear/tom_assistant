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
//   * No persona resolution — the renderer's `model` is already the resolved
//     persona-as-model id (E.15), fixed when the binding was built.
//
// Backpressure (E.39): the runtime sink tracks a client disconnect (its
// response-body subscription cancelled) as `isDisconnected`. Before each
// chunk the path checks it; once disconnected it stops rendering into the dead
// wire and returns a *terminal* `DeliveryStalled` (`clientDisconnected`)
// through the backpressure stream (`Backpressure.stalled`) so the engine
// cancels the run rather than leaking it (E.40). A connected wire returns
// `Backpressure.clear`. The engine's actual yield/cancel reaction is wired
// when the `answer_with_memory_v1` streaming gap closes.

import 'dart:async';
import 'dart:convert';

import 'package:tom_basics/tom_basics.dart' show tomLog;
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

  /// Whether the client disconnected before the answer finished — the
  /// response-body subscription was cancelled (E.39). The SSE delivery path
  /// reads this before each [write]: once `true`, it stops rendering into the
  /// dead wire and surfaces a terminal [DeliveryStalled] through the
  /// backpressure stream so the engine cancels the run. A wire that was simply
  /// [close]d after `[DONE]` is not disconnected.
  bool get isDisconnected;
}

/// The runtime [SseSink]: frames are UTF-8 encoded onto a
/// `StreamController<List<int>>` whose [body] stream is the `text/event-stream`
/// response body the OpenAI adapter returns (E.41+ wires it).
///
/// One instance per inbound streaming request. The controller is *not*
/// broadcast — exactly one consumer (the HTTP response) listens. A client
/// disconnect cancels that subscription, which sets [isDisconnected] (the
/// signal the E.39 delivery path reads to surface a terminal stall) and fires
/// the optional [onClientDisconnect] hook.
///
/// The optional [onFirstFrame] hook fires once, when the first frame is
/// written. The live edge (E.45) uses it to commit to a `200` streamed body
/// only after the edge-security gates have passed: the gates all run *before*
/// the first `OutboundChunk` is delivered, so the first frame is the signal
/// that delivery has begun and the status can no longer be a `4xx` (P1.3 #9).
final class StreamControllerSseSink implements SseSink {
  late final StreamController<List<int>> _controller =
      StreamController<List<int>>(
    onCancel: _handleCancel,
  );

  /// Called once when the [body] subscription is cancelled (the SSE client
  /// disconnected). Optional; the run-cancellation reaction is the engine's
  /// (E.39 surfaces the stall signal that drives it).
  final void Function()? _onClientDisconnect;

  /// Called once, on the first [write]. Optional; the live edge uses it to
  /// race "delivery started" against a gate rejection (P1.3 #9).
  final void Function()? _onFirstFrame;

  bool _closed = false;
  bool _disconnected = false;
  bool _firstFrameWritten = false;

  /// Builds a runtime SSE sink. [onClientDisconnect] — when supplied — fires
  /// once if the response-body subscription is cancelled before the answer
  /// finishes (a client disconnect); the engine's run-cancellation reaction is
  /// driven by the terminal stall the E.39 delivery path surfaces off
  /// [isDisconnected]. [onFirstFrame] — when supplied — fires once on the first
  /// [write], signalling the edge that delivery has begun (P1.3 #9).
  StreamControllerSseSink({
    void Function()? onClientDisconnect,
    void Function()? onFirstFrame,
  })  : _onClientDisconnect = onClientDisconnect,
        _onFirstFrame = onFirstFrame;

  /// The UTF-8 byte stream of SSE frames — the OpenAI `text/event-stream`
  /// response body. Single-subscription: the one HTTP response listens.
  Stream<List<int>> get body => _controller.stream;

  @override
  bool get isClosed => _closed;

  @override
  bool get isDisconnected => _disconnected;

  @override
  void write(String frame) {
    if (_closed) {
      throw StateError(
        'SSE frame written after the wire was closed — the OpenAI delivery '
        'path must not write past the terminal `[DONE]` frame',
      );
    }
    if (!_firstFrameWritten) {
      _firstFrameWritten = true;
      _onFirstFrame?.call();
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
    // A cancel after a normal close (`[DONE]` written) is just teardown, not a
    // client disconnect. Only a cancel while the answer is still streaming is
    // a disconnect the delivery path must react to.
    if (_closed) {
      return;
    }
    _disconnected = true;
    _onClientDisconnect?.call();
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
    final DeliveryLifecycle lifecycle = DeliveryLifecycle();
    // The OpenAI streaming shape stamps `delta.role = "assistant"` on the
    // opening chunk (Q-E.51.2). The delivery path streams chunk-by-chunk
    // through this closure, so it tracks the first *written* frame here — a
    // disconnect that drops a chunk before any write leaves the flag set, so
    // the role still lands on whatever frame is written first.
    bool firstFrame = true;

    return (OutboundChunk chunk) {
      lifecycle.guardNotTerminated(
        'the OpenAI SSE path has already written `[DONE]` and closed the wire',
      );

      if (sink.isDisconnected) {
        // The client disconnected mid-stream (the response-body subscription
        // was cancelled, E.37's `onClientDisconnect`). Do not render into the
        // dead wire; surface a *terminal* stall through the backpressure
        // stream so the engine cancels the run rather than leaking it (E.40:
        // "a disconnected SSE doesn't leak the run"). Mark terminated so a
        // stray later chunk throws loudly rather than being silently dropped.
        lifecycle.terminate();
        return Backpressure.stalled(
          DeliveryStalled.terminal(
            channel: AccessChannel.openai.wireName,
            reason: StallReason.clientDisconnected,
            detail: 'SSE client disconnected before the answer finished',
          ),
        );
      }

      sink.write(renderer.frameFor(chunk, firstChunk: firstFrame));
      firstFrame = false;
      if (chunk.isFinal) {
        lifecycle.terminate();
        sink.write(ChatCompletionSseRenderer.doneFrame);
        // The wire close is irreversible and not awaited here: this is the
        // last chunk, and the `DeliverCallback` signature is synchronous in
        // its return of the backpressure stream. But a failure on close — a
        // broken pipe when the client has already gone — must not be silently
        // dropped (G.3.5): `_closeWire` awaits the close off the hot path and
        // logs any error rather than letting it vanish into an unhandled
        // microtask.
        unawaited(_closeWire(sink));
      }

      // The chunk was accepted and the wire is ready for more — no stall.
      return Backpressure.clear;
    };
  }

  /// Closes the SSE wire after the terminal `[DONE]` frame, logging — rather
  /// than swallowing — any failure (G.3.5).
  ///
  /// Called fire-and-forget from the synchronous [DeliverCallback], so it
  /// cannot surface an error to the caller. A close failure here is benign:
  /// the answer is fully written and `[DONE]` is already on the wire, so the
  /// most likely cause is a client that disconnected just before the close.
  /// It is logged at `warn` (not `severe`) for exactly that reason — only the
  /// error's runtime type is recorded, never its message, so a transport
  /// exception cannot leak wire contents.
  static Future<void> _closeWire(SseSink sink) async {
    try {
      await sink.close();
    } catch (error) {
      tomLog.warn(
        'SSE wire close failed after `[DONE]` (${error.runtimeType}); the '
        'answer was already fully delivered, so this is benign — most likely '
        'a client that disconnected before the close.',
      );
    }
  }
}
