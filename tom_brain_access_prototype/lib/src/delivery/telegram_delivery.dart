// Telegram delivery path — the concrete `ChannelDelivery` for
// `AccessChannel.telegram` (E.38; proto spec § 6.3 / § 10.1; AC-2).
//
// What this file owns:
//
//   * `TelegramSink` — the wire one Telegram answer is delivered over: it
//     sends one already-consolidated, size-compliant message to the bound
//     chat. Abstracting the wire (rather than calling `ChatApi.sendMessage`
//     from inside the path) keeps the delivery path testable without a
//     `ChatApi` / televerse `Bot`: tests collect the sent messages in
//     memory; boot (E.41+) backs it with `ChatApiTelegramSink`.
//
//   * `ChatApiTelegramSink` — the runtime sink. Each consolidated part is
//     sent through a `tom_chattools` `ChatApi.sendMessage(receiver, …)` as
//     plain text (no `parseMode`, no typing indicator, no inline buttons —
//     Stage-1, def § Q13). One sink per inbound request, bound to that
//     request's chat `receiver`.
//
//   * `TelegramDeliveryBinding` — the per-`Access` `DeliveryBinding` subtype
//     for the Telegram channel. It carries the channel-specific state the
//     path needs: the `TelegramSink` to send through. Its base
//     `identity` / `envelope` are what the `DeliveryRegistry` reads to emit
//     the correlated `AccessDelivered` (E.36); `channel` is fixed to
//     `AccessChannel.telegram` so the registry routes here. It also exposes
//     `delivered` — a future that completes once the whole buffered answer
//     (every overflow part) has been sent, so boot / the backpressure step
//     (E.39) and tests can await actual delivery (the registry's
//     `AccessDelivered` fires earlier, on the final chunk passing through —
//     Q-E.38.1).
//
//   * `TelegramChannelDelivery` — the `ChannelDelivery` the `DeliveryRegistry`
//     (E.36) dispatches `AccessChannel.telegram` to. Unlike the SSE path
//     (which streams each chunk to the wire as it arrives), Telegram is
//     **buffered**: `bindDeliver` mints a `DeliverCallback` that accumulates
//     every `OutboundChunk`'s text and, on the final chunk (`isFinal`),
//     consolidates the buffered answer into the minimum number of
//     size-compliant Telegram messages (via the E.21
//     `TelegramOutboundConsolidator`) and sends them in order (def § Q13
//     Stage-1: one consolidated message, or — on overflow — N append-only
//     messages, never an edit; Q-E.2.6). An empty answer sends nothing
//     (Telegram rejects an empty body, Q-E.21.1).
//
// What this file does NOT do:
//
//   * No chunk sourcing — the engine pushes chunks through the produced
//     `DeliverCallback`; the dispatcher/engine wiring is boot's job (E.41+).
//   * No whitelist auth (E.22), identity / session / persona resolution
//     (E.24–E.27), or `Access` construction (boot, E.41+).
//
// Backpressure (E.39): a buffered channel cannot stall *during* streaming —
// every chunk is appended to the in-memory buffer, never sent — so the
// per-chunk backpressure stream is always `Backpressure.clear`. The stall a
// rate limit causes happens at *flush*: a `TelegramSink.send` that the backend
// throttles throws a transient `DeliveryStalled` (`rateLimited`, with the
// backend's `retryAfter`), which `_flush` propagates and the binding surfaces
// through its `delivered` future — the documented Telegram delivery surface
// (E.38, Q-E.38.1). This asymmetry with the SSE path (which signals
// per-chunk through the backpressure stream) is the structural consequence of
// buffered-vs-streamed delivery. Mapping a real televerse 429 to that signal
// inside `ChatApiTelegramSink` needs televerse's exception shape and is a
// documented seam (Q-E.39.3).

import 'dart:async';

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:tom_chattools/tom_chattools.dart';

import '../adapters/telegram/telegram_outbound_mapping.dart';
import '../identity/session_manager.dart' show AccessChannel;
import 'channel_delivery.dart';

/// The wire one Telegram answer is delivered over.
///
/// The Telegram delivery path buffers an answer, splits it into the minimum
/// number of size-compliant messages (via [TelegramOutboundConsolidator]),
/// and [send]s each part here, in order. Abstracting the wire lets the
/// delivery path stay `ChatApi`-free in tests (an in-memory sink) while boot
/// backs it with the real `tom_chattools` backend ([ChatApiTelegramSink]).
abstract interface class TelegramSink {
  /// Sends one already-consolidated, size-compliant Telegram message to the
  /// bound chat.
  ///
  /// [message] is a whole part of the consolidated answer (the answer itself
  /// when it fits one message; one of the N overflow parts otherwise) — the
  /// path consolidates and splits it; the sink only transports it. Completes
  /// when the backend has accepted the message; the path awaits each [send]
  /// in turn so the parts arrive in order.
  ///
  /// On a backend rate limit a sink throws a transient [DeliveryStalled]
  /// (`rateLimited`, with the backend's `retryAfter`); the delivery path
  /// stops sending the remaining parts and surfaces it through the binding's
  /// `delivered` future (E.39). Any other failure surfaces the same way as a
  /// plain delivery error.
  Future<void> send(String message);
}

/// The runtime [TelegramSink]: each consolidated part is sent through a
/// `tom_chattools` [ChatApi.sendMessage] to the bound [ChatReceiver] as
/// plain text (boot wires it, E.41+).
///
/// One instance per inbound request, bound to that request's chat. Plain
/// text only — no `parseMode`, no typing indicator, no inline buttons
/// (Stage-1, def § Q13).
final class ChatApiTelegramSink implements TelegramSink {
  final ChatApi _chatApi;
  final ChatReceiver _receiver;

  /// Builds a runtime Telegram sink that sends through [chatApi] to
  /// [receiver].
  const ChatApiTelegramSink({
    required ChatApi chatApi,
    required ChatReceiver receiver,
  })  : _chatApi = chatApi,
        _receiver = receiver;

  @override
  Future<void> send(String message) async {
    await _chatApi.sendMessage(_receiver, message);
  }
}

/// The per-`Access` [DeliveryBinding] for the Telegram channel (E.38).
///
/// Carries the channel-specific state [TelegramChannelDelivery] needs to
/// deliver one answer: the [sink] (the wire bound to this request's chat).
/// The base-class [identity] / [envelope] are what the [DeliveryRegistry]
/// reads to emit the correlated [AccessDelivered] (E.36); [channel] is fixed
/// to [AccessChannel.telegram] so the registry routes here.
///
/// [delivered] completes when the whole buffered answer has been sent (every
/// overflow part). The registry's [AccessDelivered] fires earlier — on the
/// final chunk passing through `deliverFor` — because Telegram buffers and
/// sends *after* the final chunk arrives (Q-E.38.1); a consumer that needs to
/// know the bytes are actually on the wire (boot / the E.39 backpressure step,
/// and the E.38 test suite) awaits [delivered].
final class TelegramDeliveryBinding implements DeliveryBinding {
  @override
  final ResolvedIdentity identity;

  @override
  final InboundRequest envelope;

  /// The wire this answer is delivered over (bound to this request's chat).
  final TelegramSink sink;

  final Completer<void> _delivered = Completer<void>();

  /// Builds the binding for one Telegram inbound request.
  TelegramDeliveryBinding({
    required this.identity,
    required this.envelope,
    required this.sink,
  });

  /// Always [AccessChannel.telegram] — this binding only ever routes to the
  /// Telegram path.
  @override
  AccessChannel get channel => AccessChannel.telegram;

  /// Completes once the buffered answer has been fully sent — all overflow
  /// parts, in order — or with the send's error if a part failed.
  ///
  /// Telegram delivery is buffered: the path accumulates chunks and sends the
  /// consolidated message(s) on the final chunk. This future is how a
  /// consumer awaits that send (the synchronous [DeliverCallback] cannot
  /// return it). An answer that never carries a final chunk leaves this
  /// pending, as the SSE path leaves its wire open.
  Future<void> get delivered => _delivered.future;

  /// Binds the actual send to [delivered]: the delivery path calls this on the
  /// final chunk with the future that completes when every consolidated part
  /// has been sent (or with the send's error). The path holds only the public
  /// binding, so completion is a public contract here rather than a reach into
  /// a private `Completer` (G.4.4).
  void completeDelivery(Future<void> sendFuture) {
    _delivered.complete(sendFuture);
  }
}

/// The Telegram outbound delivery path (E.38) — buffered single-message +
/// chunked-overflow.
///
/// Registered with the [DeliveryRegistry] (E.36) for
/// [AccessChannel.telegram]. Per inbound request the registry calls
/// [bindDeliver] with the request's [TelegramDeliveryBinding] to mint the
/// [DeliverCallback] the engine streams the answer through. Unlike the SSE
/// path, the callback does not write per chunk: it buffers every
/// [OutboundChunk]'s text and, on the final chunk, consolidates the buffered
/// answer (via [consolidator]) into the minimum number of size-compliant
/// Telegram messages and sends them through the binding's sink, in order
/// (proto spec § 6.3; def § Q13).
final class TelegramChannelDelivery implements ChannelDelivery {
  /// Buffers an answer and splits it into the size-compliant Telegram
  /// message(s) the path sends (E.21). Channel-level policy (the same split
  /// for every request), so it lives on the path, not the per-`Access`
  /// binding. Defaults to Telegram's real 4096-code-unit limit; injectable so
  /// a test can force the overflow split with a small budget.
  final TelegramOutboundConsolidator consolidator;

  /// Builds the Telegram delivery path with the given [consolidator]
  /// (default: Telegram's real per-message limit). Stateless across requests
  /// — all per-`Access` state lives on the [TelegramDeliveryBinding] and the
  /// bound closure.
  const TelegramChannelDelivery({
    this.consolidator = const TelegramOutboundConsolidator(),
  });

  @override
  AccessChannel get channel => AccessChannel.telegram;

  @override
  DeliverCallback bindDeliver(covariant TelegramDeliveryBinding binding) {
    final StringBuffer answer = StringBuffer();
    final DeliveryLifecycle lifecycle = DeliveryLifecycle();

    return (OutboundChunk chunk) {
      lifecycle.guardNotTerminated(
        'the Telegram delivery path has already consolidated and flushed the '
        'answer',
      );

      answer.write(chunk.textDelta);
      if (chunk.isFinal) {
        lifecycle.terminate();
        final List<String> parts = consolidator.split(answer.toString());
        // The send is async and the `DeliverCallback` return is synchronous;
        // the actual delivery is observable through `binding.delivered`. We
        // chain the flush future into the binding's completer so a consumer
        // (boot / E.39 / the test suite) can await real delivery and observe
        // a send error.
        binding.completeDelivery(_flush(binding.sink, parts));
      }

      // A buffered channel cannot stall during streaming — the chunk was
      // appended to the buffer, not sent. Any rate-limit stall surfaces at
      // flush through `binding.delivered` (E.39), so every chunk's
      // backpressure stream is clear.
      return Backpressure.clear;
    };
  }

  /// Sends each consolidated [parts] message through [sink], in order.
  ///
  /// Awaits each send before the next so the parts arrive in order (an empty
  /// list — an empty answer — sends nothing, Q-E.21.1). A send that throws —
  /// a transient [DeliveryStalled] on a rate limit (E.39), or any other
  /// delivery error — breaks the loop, so the remaining parts are not sent,
  /// and propagates to the binding's `delivered` future.
  static Future<void> _flush(TelegramSink sink, List<String> parts) async {
    for (final String part in parts) {
      await sink.send(part);
    }
  }
}
