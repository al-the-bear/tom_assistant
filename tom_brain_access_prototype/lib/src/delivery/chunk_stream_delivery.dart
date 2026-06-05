// Raw chunk-stream delivery path — the concrete `ChannelDelivery` for the
// adapter-renders channels (`AccessChannel.ollama`, plan-2 #27;
// `AccessChannel.anthropic`, plan-2 #28).
//
// Why a second delivery path, distinct from the SSE one:
//
//   The OpenAI SSE path (`sse_delivery.dart`) renders each `OutboundChunk`
//   into a `chat.completion.chunk` `data: …\n\n` frame *inside the delivery
//   path* — the wire format is OpenAI-specific and baked in. The Ollama and
//   Anthropic adapters render their *own* dialects (NDJSON + `done:true` /
//   named-SSE + `message_stop`) and do so themselves, downstream, from a
//   `Stream<OutboundChunk>` answer-stream seam (`OllamaAnswerStream` /
//   `AnthropicAnswerStream`). So the delivery path for those channels must NOT
//   render anything — it must forward the raw `OutboundChunk`s onto a stream
//   the adapter drains. This file is that path.
//
// What this file owns:
//
//   * `OutboundChunkSink` — the wire the path forwards raw `OutboundChunk`s
//     to. Abstracting it (rather than writing a `StreamController` directly)
//     keeps the path testable without an adapter: tests collect chunks in
//     memory; boot (plan-2 #30) backs it with the controller whose `body`
//     stream feeds the adapter's answer-stream seam.
//
//   * `StreamControllerChunkSink` — the runtime sink. Each `OutboundChunk` is
//     added to a `StreamController<OutboundChunk>` whose [body] the adapter
//     returns as its answer stream. One sink per inbound streaming request; a
//     client disconnect cancels that subscription and sets [isDisconnected].
//
//   * `ChunkStreamDeliveryBinding` — the per-`Access` `DeliveryBinding`. Unlike
//     the SSE / Telegram bindings it carries its [channel] as a *field*: one
//     delivery class serves both the Ollama and Anthropic channels, so the
//     binding records which one this `Access` belongs to (for the correlated
//     `AccessDelivered` and the terminal-stall channel name).
//
//   * `ChunkStreamChannelDelivery` — the `ChannelDelivery` the
//     `DeliveryRegistry` dispatches the adapter-renders channels to. It is
//     constructed *with* the channel it serves (`const
//     ChunkStreamChannelDelivery(AccessChannel.ollama)`), so boot registers one
//     instance per channel. `bindDeliver` forwards each `OutboundChunk` to the
//     binding's sink and, on the final chunk, closes the wire.
//
// What this file does NOT do:
//
//   * No wire formatting — the adapter renders its dialect from the forwarded
//     stream; this path moves raw chunks only.
//   * No chunk sourcing — the engine pushes chunks through the produced
//     `DeliverCallback`; the dispatcher/engine wiring is boot's job (#30).
//
// Backpressure (E.39, mirrored): the runtime sink tracks a client disconnect
// (its stream subscription cancelled) as [isDisconnected]. Before each chunk
// the path checks it; once disconnected it stops forwarding into the dead wire
// and returns a *terminal* `DeliveryStalled` (`clientDisconnected`) through the
// backpressure stream so the engine cancels the run rather than leaking it. A
// connected wire returns `Backpressure.clear`.

import 'dart:async';

import 'package:tom_basics/tom_basics.dart' show tomLog;
import 'package:tom_brain_shared/tom_brain_shared.dart';

import '../identity/session_manager.dart' show AccessChannel;
import 'channel_delivery.dart';

/// The wire one adapter-renders streaming response is delivered over.
///
/// The chunk-stream delivery path forwards each raw [OutboundChunk] here; the
/// originating adapter (Ollama / Anthropic) drains the wire and renders its own
/// dialect. Abstracting the wire lets the path stay adapter-free in tests (an
/// in-memory sink) while boot backs it with the controller whose stream feeds
/// the adapter's answer-stream seam ([StreamControllerChunkSink]).
abstract interface class OutboundChunkSink {
  /// Forwards one raw [OutboundChunk] to the wire. Adding after [close] is a
  /// contract violation (the wire is gone) and throws [StateError].
  void add(OutboundChunk chunk);

  /// Closes the wire after the final chunk. Idempotent: closing an
  /// already-closed sink is a no-op.
  Future<void> close();

  /// Whether [close] has been called.
  bool get isClosed;

  /// Whether the client disconnected before the answer finished — the wire's
  /// stream subscription was cancelled (E.39). The delivery path reads this
  /// before each [add]: once `true`, it stops forwarding into the dead wire and
  /// surfaces a terminal [DeliveryStalled] through the backpressure stream so
  /// the engine cancels the run. A wire that was simply [close]d after the
  /// final chunk is not disconnected.
  bool get isDisconnected;
}

/// The runtime [OutboundChunkSink]: chunks are added to a
/// `StreamController<OutboundChunk>` whose [body] stream the originating
/// adapter returns as its answer stream (plan-2 #30 wires it).
///
/// One instance per inbound streaming request. The controller is *not*
/// broadcast — exactly one consumer (the adapter's renderer) listens. A client
/// disconnect cancels that subscription, which sets [isDisconnected] (the
/// signal the delivery path reads to surface a terminal stall) and fires the
/// optional [onClientDisconnect] hook.
///
/// The optional [onFirstChunk] hook fires once, when the first chunk is
/// forwarded. The live edge (plan-2 #30) uses it the way the SSE sink uses
/// `onFirstFrame`: to commit to a `200` streamed body only after the
/// edge-security gates have passed. The gates all run *before* the first
/// `OutboundChunk` is delivered, so the first chunk is the signal that delivery
/// has begun and the status can no longer be a `4xx` (P1.3 #9).
final class StreamControllerChunkSink implements OutboundChunkSink {
  late final StreamController<OutboundChunk> _controller =
      StreamController<OutboundChunk>(onCancel: _handleCancel);

  /// Called once when the [body] subscription is cancelled (the client
  /// disconnected). Optional; the run-cancellation reaction is the engine's
  /// (E.39 surfaces the stall signal that drives it).
  final void Function()? _onClientDisconnect;

  /// Called once, on the first [add]. Optional; the live edge uses it to race
  /// "delivery started" against a gate rejection (P1.3 #9).
  final void Function()? _onFirstChunk;

  bool _closed = false;
  bool _disconnected = false;
  bool _firstChunkForwarded = false;

  /// Builds a runtime chunk-stream sink. [onClientDisconnect] — when supplied —
  /// fires once if the answer-stream subscription is cancelled before the
  /// answer finishes (a client disconnect). [onFirstChunk] — when supplied —
  /// fires once on the first [add], signalling the edge that delivery has begun
  /// (P1.3 #9).
  StreamControllerChunkSink({
    void Function()? onClientDisconnect,
    void Function()? onFirstChunk,
  })  : _onClientDisconnect = onClientDisconnect,
        _onFirstChunk = onFirstChunk;

  /// The raw `OutboundChunk` stream the originating adapter drains and renders
  /// into its own dialect. Single-subscription: the one adapter renderer
  /// listens.
  Stream<OutboundChunk> get body => _controller.stream;

  @override
  bool get isClosed => _closed;

  @override
  bool get isDisconnected => _disconnected;

  @override
  void add(OutboundChunk chunk) {
    if (_closed) {
      throw StateError(
        'OutboundChunk added after the wire was closed — the chunk-stream '
        'delivery path must not forward past the final chunk',
      );
    }
    if (!_firstChunkForwarded) {
      _firstChunkForwarded = true;
      _onFirstChunk?.call();
    }
    _controller.add(chunk);
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
    // A cancel after a normal close (final chunk forwarded) is just teardown,
    // not a client disconnect. Only a cancel while the answer is still
    // streaming is a disconnect the delivery path must react to.
    if (_closed) {
      return;
    }
    _disconnected = true;
    _onClientDisconnect?.call();
  }
}

/// The per-`Access` [DeliveryBinding] for an adapter-renders channel.
///
/// Carries the [sink] (the wire the answer's raw chunks are forwarded over)
/// and — unlike the SSE / Telegram bindings — the [channel] as a *field*,
/// because one [ChunkStreamChannelDelivery] class serves both the Ollama and
/// Anthropic channels. The base-class [identity] / [envelope] are what the
/// [DeliveryRegistry] reads to emit the correlated [AccessDelivered].
final class ChunkStreamDeliveryBinding implements DeliveryBinding {
  @override
  final AccessChannel channel;

  @override
  final ResolvedIdentity identity;

  @override
  final InboundRequest envelope;

  /// The wire this answer's raw chunks are forwarded over; the originating
  /// adapter drains it.
  final OutboundChunkSink sink;

  /// Builds the binding for one adapter-renders streaming request. [channel] is
  /// the originating channel ([AccessChannel.ollama] or
  /// [AccessChannel.anthropic]); the registry routes on it.
  const ChunkStreamDeliveryBinding({
    required this.channel,
    required this.identity,
    required this.envelope,
    required this.sink,
  });
}

/// The raw chunk-stream outbound delivery path (Ollama / Anthropic).
///
/// Registered with the [DeliveryRegistry] once per adapter-renders channel —
/// boot registers `const ChunkStreamChannelDelivery(AccessChannel.ollama)` and
/// `const ChunkStreamChannelDelivery(AccessChannel.anthropic)`. Per inbound
/// streaming request the registry calls [bindDeliver] with the request's
/// [ChunkStreamDeliveryBinding] to mint the [DeliverCallback] the engine
/// streams the answer through: each [OutboundChunk] is forwarded raw to the
/// binding's sink, and the final chunk additionally closes the wire so the
/// adapter's renderer sees the stream end.
final class ChunkStreamChannelDelivery implements ChannelDelivery {
  /// The channel this instance serves — fixed at construction, since one class
  /// backs both adapter-renders channels.
  @override
  final AccessChannel channel;

  /// Builds the path for [channel]. Stateless across requests — all
  /// per-`Access` state lives on the [ChunkStreamDeliveryBinding].
  const ChunkStreamChannelDelivery(this.channel);

  @override
  DeliverCallback bindDeliver(covariant ChunkStreamDeliveryBinding binding) {
    final OutboundChunkSink sink = binding.sink;
    final AccessChannel boundChannel = binding.channel;
    final DeliveryLifecycle lifecycle = DeliveryLifecycle();

    return (OutboundChunk chunk) {
      lifecycle.guardNotTerminated(
        'the chunk-stream path has already forwarded the final chunk and '
        'closed the wire',
      );

      if (sink.isDisconnected) {
        // The client disconnected mid-stream (the answer-stream subscription
        // was cancelled). Do not forward into the dead wire; surface a
        // *terminal* stall through the backpressure stream so the engine
        // cancels the run rather than leaking it (E.40). Mark terminated so a
        // stray later chunk throws loudly rather than being silently dropped.
        lifecycle.terminate();
        return Backpressure.stalled(
          DeliveryStalled.terminal(
            channel: boundChannel.wireName,
            reason: StallReason.clientDisconnected,
            detail: '${boundChannel.wireName} client disconnected before the '
                'answer finished',
          ),
        );
      }

      sink.add(chunk);
      if (chunk.isFinal) {
        lifecycle.terminate();
        // The wire close is irreversible and not awaited here: this is the
        // last chunk, and the `DeliverCallback` returns its backpressure stream
        // synchronously. A failure on close must not be silently dropped
        // (G.3.5): `_closeWire` awaits the close off the hot path and logs any
        // error rather than letting it vanish into an unhandled microtask.
        unawaited(_closeWire(sink, boundChannel));
      }

      // The chunk was forwarded and the wire is ready for more — no stall.
      return Backpressure.clear;
    };
  }

  /// Closes the chunk-stream wire after the final chunk, logging — rather than
  /// swallowing — any failure (G.3.5).
  ///
  /// Called fire-and-forget from the synchronous [DeliverCallback], so it
  /// cannot surface an error to the caller. A close failure here is benign: the
  /// answer is fully forwarded, so the most likely cause is a client that
  /// disconnected just before the close. Only the error's runtime type is
  /// recorded, never its message, so a transport exception cannot leak wire
  /// contents.
  static Future<void> _closeWire(
    OutboundChunkSink sink,
    AccessChannel channel,
  ) async {
    try {
      await sink.close();
    } catch (error) {
      tomLog.warn(
        '${channel.wireName} chunk-stream wire close failed after the final '
        'chunk (${error.runtimeType}); the answer was already fully '
        'forwarded, so this is benign — most likely a client that '
        'disconnected before the close.',
      );
    }
  }
}
