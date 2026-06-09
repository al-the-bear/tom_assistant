// E.40 — delivery test sweep.
//
// The final step of `## E.8 — Outbound delivery`: an integration-level sweep
// over the two delivery paths wired the way boot wires them — through the E.36
// `DeliveryRegistry`, over the *runtime* sinks (`StreamControllerSseSink` /
// `ChatApiTelegramSink`), not the in-memory fakes the per-step E.37 / E.38 /
// E.39 suites use. It locks the three things the plan names for E.40
// (proto spec § 10.1; AC-2):
//
//   1. Each path delivers correctly — a full multi-chunk answer streamed
//      end-to-end arrives, in order, on the channel's real wire, and the
//      registry emits the correlated terminal-success `AccessDelivered`.
//   2. The backpressure signal surfaces — the SSE path raises a terminal
//      `DeliveryStalled` through the backpressure stream; the Telegram path
//      raises a transient one through the binding's `delivered` future.
//   3. A disconnected SSE does not leak the run — cancelling the runtime
//      sink's body subscription (a real client disconnect) sets
//      `isDisconnected`, fires `onClientDisconnect`, and makes the next chunk
//      stall terminally instead of rendering into the dead wire; the run is
//      then terminated (a later chunk throws). This is the genuine
//      cancellation-propagation path the unit suites only simulate with a
//      toggle.

import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:tom_chattools/tom_chattools.dart';

import '../_support/loopback_chat_api.dart';

/// Drains a backpressure stream and reports the stall it carried, if any.
///
/// A backpressure stream never emits an element: it either completes empty
/// (the chunk was accepted — `Backpressure.clear`) or carries a
/// [DeliveryStalled] as a stream error (`Backpressure.stalled`).
Future<DeliveryStalled?> _stallOf(Stream<OutboundChunk> backpressure) async {
  try {
    await for (final OutboundChunk _ in backpressure) {
      // Never reached — a backpressure stream emits no elements.
    }
    return null;
  } on DeliveryStalled catch (e) {
    return e;
  }
}

ChatCompletionSseRenderer _renderer() => ChatCompletionSseRenderer(
      id: 'chatcmpl-sweep',
      model: 'tom-assistant',
      created: 1717329600,
    );

SseDeliveryBinding _sseBinding(SseSink sink) => SseDeliveryBinding(
      identity: ResolvedIdentity(principalId: 'principal-1'),
      envelope: InboundRequest(
        text: 'hello',
        conversationId: 'conv-1',
        messageId: 'msg-1',
      ),
      sink: sink,
      renderer: _renderer(),
    );

TelegramDeliveryBinding _telegramBinding(TelegramSink sink) =>
    TelegramDeliveryBinding(
      identity: ResolvedIdentity(principalId: 'principal-1'),
      envelope: InboundRequest(
        text: 'hello',
        conversationId: 'chat-1',
        messageId: 'msg-1',
      ),
      sink: sink,
    );

/// Decodes a `data: {json}\n\n` SSE frame into its payload map (callers check
/// the terminal `[DONE]` line separately).
Map<String, Object?> _payloadOf(String frame) {
  final String json = frame.substring('data: '.length, frame.length - 2);
  return jsonDecode(json) as Map<String, Object?>;
}

String _contentOf(Map<String, Object?> payload) {
  final Map<String, Object?> choice =
      (payload['choices'] as List<Object?>).single as Map<String, Object?>;
  return (choice['delta'] as Map<String, Object?>)['content'] as String;
}

/// A [TelegramSink] that throws a transient rate-limit [DeliveryStalled] on its
/// first send — the documented Telegram backpressure surface (E.39).
final class _RateLimitedTelegramSink implements TelegramSink {
  @override
  Future<void> send(String message) async {
    throw DeliveryStalled.transient(
      channel: 'telegram',
      reason: StallReason.rateLimited,
      retryAfter: const Duration(seconds: 30),
      detail: 'HTTP 429 from the Telegram backend',
    );
  }
}

void main() {
  group('E.40 sweep — each path delivers correctly (end-to-end)', () {
    test(
        'SSE: a multi-chunk answer arrives on the runtime wire in order, '
        '[DONE]-terminated, with a correlated AccessDelivered', () async {
      final List<AccessDelivered> events = <AccessDelivered>[];
      final DeliveryRegistry registry = DeliveryRegistry(onDelivered: events.add)
        ..register(const SseChannelDelivery());

      final StreamControllerSseSink sink = StreamControllerSseSink();
      // Collect the actual UTF-8 response body the OpenAI adapter would return.
      final Future<List<List<int>>> body = sink.body.toList();

      final DeliverCallback deliver = registry.deliverFor(_sseBinding(sink));
      deliver(OutboundChunk(textDelta: 'Hello, ', index: 0));
      deliver(OutboundChunk(textDelta: 'world', index: 1));
      deliver(OutboundChunk(textDelta: '!', isFinal: true, index: 2));

      final String wire = (await body).map(utf8.decode).join();
      final List<String> frames = wire
          .split('\n\n')
          .where((String f) => f.isNotEmpty)
          .map((String f) => '$f\n\n')
          .toList();

      // Three content frames, then [DONE], in order.
      expect(frames, hasLength(4));
      expect(_contentOf(_payloadOf(frames[0])), 'Hello, ');
      expect(_contentOf(_payloadOf(frames[1])), 'world');
      expect(_contentOf(_payloadOf(frames[2])), '!');
      expect(frames.last, 'data: [DONE]\n\n');
      expect(sink.isClosed, isTrue);

      // The terminal-success event carries the chunk count and correlation.
      expect(events, hasLength(1));
      expect(events.single.chunkCount, 3);
      expect(events.single.accessId, 'msg-1');
      expect(events.single.conversationId, 'conv-1');
    });

    test(
        'Telegram: a buffered, overflowing answer arrives as ordered messages '
        'through the runtime ChatApi sink, with a correlated AccessDelivered',
        () async {
      final List<AccessDelivered> events = <AccessDelivered>[];
      final DeliveryRegistry registry = DeliveryRegistry(onDelivered: events.add)
        // A small budget forces the overflow split without a 4096-char answer.
        ..register(const TelegramChannelDelivery(
          consolidator: TelegramOutboundConsolidator(maxMessageLength: 5),
        ));

      final LoopbackChatApi chatApi = LoopbackChatApi();
      final ChatReceiver receiver = ChatReceiver.id('chat-1');
      final TelegramDeliveryBinding binding = _telegramBinding(
        ChatApiTelegramSink(chatApi: chatApi, receiver: receiver),
      );

      final DeliverCallback deliver = registry.deliverFor(binding);
      // 12 code units → ceil(12 / 5) = 3 parts of 5, 5, 2.
      deliver(OutboundChunk(textDelta: 'abcde', index: 0));
      deliver(OutboundChunk(textDelta: 'fghij', index: 1));
      deliver(OutboundChunk(textDelta: 'kl', isFinal: true, index: 2));

      await binding.delivered;

      expect(chatApi.sentMessages, <String>['abcde', 'fghij', 'kl']);
      // Lossless: the parts reassemble to the full answer.
      expect(chatApi.sentMessages.join(), 'abcdefghijkl');
      // Every part went to the bound chat as plain text.
      expect(chatApi.sentReceivers, everyElement(same(receiver)));
      expect(chatApi.sentParseModes, <String?>[null, null, null]);

      // The terminal-success event fires once for the whole answer.
      expect(events, hasLength(1));
      expect(events.single.chunkCount, 3);
      expect(events.single.accessId, 'msg-1');
    });
  });

  group('E.40 sweep — the backpressure signal surfaces', () {
    test('SSE: a stalled wire surfaces a terminal DeliveryStalled', () async {
      // A runtime sink whose subscription is cancelled before the answer ends.
      final StreamControllerSseSink sink = StreamControllerSseSink();
      final StreamSubscription<List<int>> sub = sink.body.listen((_) {});
      final DeliverCallback deliver =
          const SseChannelDelivery().bindDeliver(_sseBinding(sink));

      deliver(OutboundChunk(textDelta: 'partial', index: 0));
      await sub.cancel();
      await Future<void>.delayed(Duration.zero);

      final DeliveryStalled? stall =
          await _stallOf(deliver(OutboundChunk(textDelta: 'more', index: 1)));

      expect(stall, isNotNull);
      expect(stall!.isTerminal, isTrue);
      expect(stall.reason, StallReason.clientDisconnected);
      expect(stall.channel, AccessChannel.openai.wireName);
      expect(stall.retryAfter, isNull);
    });

    test('Telegram: a rate limit surfaces a transient DeliveryStalled', () async {
      final TelegramDeliveryBinding binding =
          _telegramBinding(_RateLimitedTelegramSink());
      final DeliverCallback deliver =
          const TelegramChannelDelivery().bindDeliver(binding);

      // Attach the delivered-future handler *before* the flush runs, so the
      // transient rate-limit error is never momentarily unhandled while we
      // inspect the (synchronous-return) per-chunk backpressure stream.
      final Future<Object?> delivered = binding.delivered
          .then<Object?>((_) => null, onError: (Object e) => e);

      // The per-chunk stream stays clear — a buffered channel cannot stall
      // mid-stream; the rate limit only bites at flush.
      final DeliveryStalled? perChunk = await _stallOf(
        deliver(OutboundChunk(textDelta: 'the whole answer', isFinal: true)),
      );
      expect(perChunk, isNull);

      // The stall surfaces through the binding's delivered future.
      final Object? caught = await delivered;
      expect(caught, isA<DeliveryStalled>());
      final DeliveryStalled stall = caught! as DeliveryStalled;
      expect(stall.isTerminal, isFalse);
      expect(stall.reason, StallReason.rateLimited);
      expect(stall.retryAfter, const Duration(seconds: 30));
    });
  });

  group('E.40 sweep — a disconnected SSE does not leak the run', () {
    test('cancelling the runtime body subscription propagates to the path',
        () async {
      int disconnects = 0;
      final StreamControllerSseSink sink =
          StreamControllerSseSink(onClientDisconnect: () => disconnects++);
      final List<List<int>> received = <List<int>>[];
      final StreamSubscription<List<int>> sub = sink.body.listen(received.add);

      final DeliveryRegistry registry = DeliveryRegistry()
        ..register(const SseChannelDelivery());
      final DeliverCallback deliver = registry.deliverFor(_sseBinding(sink));

      // First chunk streams to the live wire.
      deliver(OutboundChunk(textDelta: 'partial', index: 0));
      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(1));
      expect(_contentOf(_payloadOf(utf8.decode(received.single))), 'partial');

      // The client disconnects: the response-body subscription is cancelled.
      await sub.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(disconnects, 1);
      expect(sink.isDisconnected, isTrue);
      // A disconnect is not a normal close — the wire was never [DONE]-closed.
      expect(sink.isClosed, isFalse);

      // The next chunk stalls terminally rather than rendering into the dead
      // wire (no leak): nothing more reaches the (cancelled) body, and no
      // `[DONE]` is written.
      final DeliveryStalled? stall =
          await _stallOf(deliver(OutboundChunk(textDelta: 'more', index: 1)));
      expect(stall, isNotNull);
      expect(stall!.isTerminal, isTrue);
      expect(received, hasLength(1)); // still only the pre-disconnect frame

      // The run is terminated: a later chunk throws rather than being silently
      // dropped — cancellation has propagated all the way to the engine seam.
      expect(
        () => deliver(OutboundChunk(textDelta: 'y', index: 2)),
        throwsStateError,
      );
    });

    test('a disconnect-stalled answer emits no AccessDelivered (nothing shipped)',
        () async {
      final List<AccessDelivered> events = <AccessDelivered>[];
      final DeliveryRegistry registry = DeliveryRegistry(onDelivered: events.add)
        ..register(const SseChannelDelivery());

      final StreamControllerSseSink sink = StreamControllerSseSink();
      final StreamSubscription<List<int>> sub = sink.body.listen((_) {});
      final DeliverCallback deliver = registry.deliverFor(_sseBinding(sink));

      deliver(OutboundChunk(textDelta: 'partial', index: 0));
      await sub.cancel();
      await Future<void>.delayed(Duration.zero);

      // The next mid-stream chunk stalls and terminates the run; the engine's
      // reaction is to cancel, so no final chunk ever arrives. The stalled
      // chunk is not final and is therefore never counted as delivered — no
      // terminal-success event for an answer that never reached the client.
      await _stallOf(deliver(OutboundChunk(textDelta: 'rest', index: 1)));

      expect(events, isEmpty);
    });
  });
}
