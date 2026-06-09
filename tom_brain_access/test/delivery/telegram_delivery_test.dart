// E.38 — Telegram delivery path suite.
//
// Locks the concrete `ChannelDelivery` for `AccessChannel.telegram` (proto
// spec § 6.3 / § 10.1; AC-2): the callback buffers every `OutboundChunk` and,
// on the final chunk, consolidates the answer into the minimum number of
// size-compliant messages (one when it fits, N append-only overflow parts
// when it does not — def § Q13 / Q-E.2.6) and sends them in order; an empty
// answer sends nothing (Q-E.21.1); the binding's `delivered` future tracks
// real delivery; the path dispatches correctly through the E.36
// `DeliveryRegistry`; and the runtime `ChatApiTelegramSink` sends through a
// `tom_chattools` `ChatApi.sendMessage`.

import 'package:test/test.dart';
import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:tom_chattools/tom_chattools.dart';

import '../_support/loopback_chat_api.dart';

/// An in-memory [TelegramSink] that records every sent message in order — so
/// the suite can assert consolidation / overflow / ordering without a
/// `ChatApi`.
final class _CollectingTelegramSink implements TelegramSink {
  final List<String> sent = <String>[];

  @override
  Future<void> send(String message) async {
    sent.add(message);
  }
}

/// A [TelegramSink] whose send always throws, to prove the failure surfaces
/// through the binding's `delivered` future.
final class _ThrowingTelegramSink implements TelegramSink {
  @override
  Future<void> send(String message) async {
    throw StateError('telegram backend unavailable');
  }
}

/// A [TelegramSink] that records every sent message but throws when asked to
/// send one specific message — to prove a failed out-of-band notice does not
/// abort the buffered answer (notice sends are best-effort).
final class _NoticeFailingTelegramSink implements TelegramSink {
  _NoticeFailingTelegramSink(this.failOn);

  final String failOn;
  final List<String> sent = <String>[];

  @override
  Future<void> send(String message) async {
    if (message == failOn) {
      throw StateError('notice send failed');
    }
    sent.add(message);
  }
}

TelegramDeliveryBinding _binding({
  required TelegramSink sink,
  String principalId = 'principal-1',
  String? conversationId = 'chat-1',
  String? messageId = 'msg-1',
}) {
  return TelegramDeliveryBinding(
    identity: ResolvedIdentity(principalId: principalId),
    envelope: InboundRequest(
      text: 'hello',
      conversationId: conversationId,
      messageId: messageId,
    ),
    sink: sink,
  );
}

void main() {
  group('E.38 TelegramChannelDelivery — contract', () {
    test('serves AccessChannel.telegram', () {
      expect(const TelegramChannelDelivery().channel, AccessChannel.telegram);
    });

    test('the binding channel is always telegram', () {
      final TelegramDeliveryBinding binding =
          _binding(sink: _CollectingTelegramSink());
      expect(binding.channel, AccessChannel.telegram);
    });
  });

  group('E.38 TelegramChannelDelivery — buffered single message', () {
    test('a non-final chunk sends nothing yet (buffered, not streamed)',
        () async {
      final _CollectingTelegramSink sink = _CollectingTelegramSink();
      final DeliverCallback deliver =
          const TelegramChannelDelivery().bindDeliver(_binding(sink: sink));

      deliver(OutboundChunk(textDelta: 'Hello ', index: 0));
      // Telegram is buffered — nothing is sent until the final chunk.
      await Future<void>.delayed(Duration.zero);
      expect(sink.sent, isEmpty);
    });

    test('multiple chunks consolidate into one message on the final chunk',
        () async {
      final _CollectingTelegramSink sink = _CollectingTelegramSink();
      final TelegramDeliveryBinding binding = _binding(sink: sink);
      final DeliverCallback deliver =
          const TelegramChannelDelivery().bindDeliver(binding);

      deliver(OutboundChunk(textDelta: 'Hello, ', index: 0));
      deliver(OutboundChunk(textDelta: 'world', index: 1));
      deliver(OutboundChunk(textDelta: '!', isFinal: true, index: 2));

      await binding.delivered;
      expect(sink.sent, <String>['Hello, world!']);
    });

    test('a single consolidated final chunk sends one message', () async {
      final _CollectingTelegramSink sink = _CollectingTelegramSink();
      final TelegramDeliveryBinding binding = _binding(sink: sink);
      final DeliverCallback deliver =
          const TelegramChannelDelivery().bindDeliver(binding);

      deliver(OutboundChunk(textDelta: 'whole answer', isFinal: true));

      await binding.delivered;
      expect(sink.sent, <String>['whole answer']);
    });

    test('an empty answer sends nothing (Q-E.21.1)', () async {
      final _CollectingTelegramSink sink = _CollectingTelegramSink();
      final TelegramDeliveryBinding binding = _binding(sink: sink);
      final DeliverCallback deliver =
          const TelegramChannelDelivery().bindDeliver(binding);

      deliver(OutboundChunk(textDelta: '', isFinal: true));

      await binding.delivered;
      expect(sink.sent, isEmpty);
    });
  });

  group('E.38 TelegramChannelDelivery — out-of-band notices', () {
    test('a notice chunk sends its own message immediately (before the answer)',
        () async {
      final _CollectingTelegramSink sink = _CollectingTelegramSink();
      final DeliverCallback deliver =
          const TelegramChannelDelivery().bindDeliver(_binding(sink: sink));

      deliver(OutboundChunk(textDelta: '', notice: '🔧 tool memory.read'));
      // The notice is sent out-of-band, not buffered — it lands without
      // waiting for any final chunk.
      await Future<void>.delayed(Duration.zero);
      expect(sink.sent, <String>['🔧 tool memory.read']);
    });

    test('a notice-only chunk does not append to the buffered answer',
        () async {
      final _CollectingTelegramSink sink = _CollectingTelegramSink();
      final TelegramDeliveryBinding binding = _binding(sink: sink);
      final DeliverCallback deliver =
          const TelegramChannelDelivery().bindDeliver(binding);

      deliver(OutboundChunk(textDelta: 'Hello, ', index: 0));
      deliver(OutboundChunk(textDelta: '', notice: '🔧 tool memory.read'));
      deliver(OutboundChunk(textDelta: 'world!', isFinal: true, index: 1));

      await binding.delivered;
      // The notice arrives first as its own message; the answer consolidates
      // separately, with no notice text folded in.
      expect(sink.sent, <String>['🔧 tool memory.read', 'Hello, world!']);
    });

    test('notices arrive in order, all before the answer', () async {
      final _CollectingTelegramSink sink = _CollectingTelegramSink();
      final TelegramDeliveryBinding binding = _binding(sink: sink);
      final DeliverCallback deliver =
          const TelegramChannelDelivery().bindDeliver(binding);

      deliver(OutboundChunk(textDelta: '', notice: 'n1'));
      deliver(OutboundChunk(textDelta: '', notice: 'n2'));
      deliver(OutboundChunk(textDelta: 'answer', isFinal: true));

      await binding.delivered;
      expect(sink.sent, <String>['n1', 'n2', 'answer']);
    });

    test('a failed notice send does not abort the answer (best-effort)',
        () async {
      final _NoticeFailingTelegramSink sink =
          _NoticeFailingTelegramSink('bad notice');
      final TelegramDeliveryBinding binding = _binding(sink: sink);
      final DeliverCallback deliver =
          const TelegramChannelDelivery().bindDeliver(binding);

      deliver(OutboundChunk(textDelta: '', notice: 'bad notice'));
      deliver(OutboundChunk(textDelta: 'the answer', isFinal: true));

      // The failed notice is swallowed; delivered completes normally and the
      // answer still lands.
      await binding.delivered;
      expect(sink.sent, <String>['the answer']);
    });

    test('an empty notice string is ignored (no message sent)', () async {
      final _CollectingTelegramSink sink = _CollectingTelegramSink();
      final TelegramDeliveryBinding binding = _binding(sink: sink);
      final DeliverCallback deliver =
          const TelegramChannelDelivery().bindDeliver(binding);

      deliver(OutboundChunk(textDelta: 'answer', notice: '', isFinal: true));

      await binding.delivered;
      expect(sink.sent, <String>['answer']);
    });
  });

  group('E.38 TelegramChannelDelivery — chunked overflow', () {
    test('an answer over the per-message budget splits into ordered parts',
        () async {
      final _CollectingTelegramSink sink = _CollectingTelegramSink();
      final TelegramDeliveryBinding binding = _binding(sink: sink);
      // A 5-code-unit budget forces the overflow split without a 4096-char
      // answer; the consolidator never cuts a character in half.
      final DeliverCallback deliver = const TelegramChannelDelivery(
        consolidator: TelegramOutboundConsolidator(maxMessageLength: 5),
      ).bindDeliver(binding);

      // 12 chars → ceil(12/5) = 3 parts of 5, 5, 2.
      deliver(OutboundChunk(textDelta: 'abcde', index: 0));
      deliver(OutboundChunk(textDelta: 'fghij', index: 1));
      deliver(OutboundChunk(textDelta: 'kl', isFinal: true, index: 2));

      await binding.delivered;
      expect(sink.sent, <String>['abcde', 'fghij', 'kl']);
      // Lossless: the parts reassemble to the full answer.
      expect(sink.sent.join(), 'abcdefghijkl');
    });
  });

  group('E.38 TelegramChannelDelivery — callback semantics', () {
    test('the produced callback returns an empty backpressure stream',
        () async {
      final DeliverCallback deliver = const TelegramChannelDelivery()
          .bindDeliver(_binding(sink: _CollectingTelegramSink()));

      final List<OutboundChunk> back =
          await deliver(OutboundChunk(textDelta: 'x', index: 0)).toList();
      expect(back, isEmpty);
    });

    test('a chunk after the final one throws StateError', () {
      final DeliverCallback deliver = const TelegramChannelDelivery()
          .bindDeliver(_binding(sink: _CollectingTelegramSink()));

      deliver(OutboundChunk(textDelta: 'done', isFinal: true));
      expect(
        () => deliver(OutboundChunk(textDelta: 'stray')),
        throwsStateError,
      );
    });

    test('each Access binds an independent buffer', () async {
      const TelegramChannelDelivery path = TelegramChannelDelivery();
      final _CollectingTelegramSink sinkA = _CollectingTelegramSink();
      final _CollectingTelegramSink sinkB = _CollectingTelegramSink();
      final TelegramDeliveryBinding bindingA = _binding(sink: sinkA);
      final TelegramDeliveryBinding bindingB = _binding(sink: sinkB);

      final DeliverCallback a = path.bindDeliver(bindingA);
      final DeliverCallback b = path.bindDeliver(bindingB);

      a(OutboundChunk(textDelta: 'answer A', isFinal: true));
      // b is a separate binding — not terminated by a's final chunk, and its
      // buffer is independent.
      b(OutboundChunk(textDelta: 'answer B', isFinal: true));

      await Future.wait(<Future<void>>[bindingA.delivered, bindingB.delivered]);
      expect(sinkA.sent, <String>['answer A']);
      expect(sinkB.sent, <String>['answer B']);
    });

    test('a send failure surfaces through the binding.delivered future',
        () async {
      final TelegramDeliveryBinding binding =
          _binding(sink: _ThrowingTelegramSink());
      final DeliverCallback deliver =
          const TelegramChannelDelivery().bindDeliver(binding);

      deliver(OutboundChunk(textDelta: 'boom', isFinal: true));

      await expectLater(binding.delivered, throwsStateError);
    });
  });

  group('E.38 ChatApiTelegramSink — runtime wire', () {
    test('sends each part through ChatApi.sendMessage to the receiver',
        () async {
      final LoopbackChatApi chatApi = LoopbackChatApi();
      final ChatReceiver receiver = ChatReceiver.id('chat-7');
      final ChatApiTelegramSink sink =
          ChatApiTelegramSink(chatApi: chatApi, receiver: receiver);

      await sink.send('part one');
      await sink.send('part two');

      expect(chatApi.sentMessages, <String>['part one', 'part two']);
      expect(chatApi.sentReceivers, hasLength(2));
      // Plain text only — Stage-1 sends no parseMode (def § Q13).
      expect(chatApi.sentParseModes, <String?>[null, null]);
    });

    test('drives the full path end-to-end through the runtime sink', () async {
      final LoopbackChatApi chatApi = LoopbackChatApi();
      final TelegramDeliveryBinding binding = TelegramDeliveryBinding(
        identity: ResolvedIdentity(principalId: 'p-1'),
        envelope: InboundRequest(text: 'hi', conversationId: 'chat-9'),
        sink: ChatApiTelegramSink(
          chatApi: chatApi,
          receiver: ChatReceiver.id('chat-9'),
        ),
      );
      final DeliverCallback deliver = const TelegramChannelDelivery(
        consolidator: TelegramOutboundConsolidator(maxMessageLength: 4),
      ).bindDeliver(binding);

      deliver(OutboundChunk(textDelta: 'abcd', index: 0));
      deliver(OutboundChunk(textDelta: 'ef', isFinal: true, index: 1));

      await binding.delivered;
      expect(chatApi.sentMessages, <String>['abcd', 'ef']);
    });
  });

  group('E.38 TelegramChannelDelivery — through the DeliveryRegistry (E.36)',
      () {
    test('the registry dispatches telegram to the Telegram path', () async {
      final DeliveryRegistry registry = DeliveryRegistry()
        ..register(const TelegramChannelDelivery());
      final _CollectingTelegramSink sink = _CollectingTelegramSink();
      final TelegramDeliveryBinding binding = _binding(sink: sink);

      final DeliverCallback deliver = registry.deliverFor(binding);
      deliver(OutboundChunk(textDelta: 'hi there', isFinal: true));

      await binding.delivered;
      expect(sink.sent, <String>['hi there']);
    });

    test('the final chunk emits a correlated AccessDelivered', () {
      final List<AccessDelivered> events = <AccessDelivered>[];
      final DeliveryRegistry registry =
          DeliveryRegistry(onDelivered: events.add)
            ..register(const TelegramChannelDelivery());
      final _CollectingTelegramSink sink = _CollectingTelegramSink();

      final DeliverCallback deliver = registry.deliverFor(
        _binding(
          sink: sink,
          principalId: 'principal-9',
          conversationId: 'chat-9',
          messageId: 'msg-9',
        ),
      );
      deliver(OutboundChunk(textDelta: 'a', index: 0));
      deliver(OutboundChunk(textDelta: 'b', isFinal: true, index: 1));

      expect(events, hasLength(1));
      final AccessDelivered event = events.single;
      expect(event.chunkCount, 2);
      expect(event.principalId, 'principal-9');
      expect(event.conversationId, 'chat-9');
      expect(event.accessId, 'msg-9');
    });

    test('one registry serves both delivery paths (SSE + Telegram)', () {
      final DeliveryRegistry registry = DeliveryRegistry()
        ..register(const SseChannelDelivery())
        ..register(const TelegramChannelDelivery());

      expect(registry.supports(AccessChannel.openai), isTrue);
      expect(registry.supports(AccessChannel.telegram), isTrue);
      expect(registry.channels, hasLength(2));
    });
  });
}
