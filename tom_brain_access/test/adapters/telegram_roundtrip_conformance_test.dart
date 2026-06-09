// E.23 conformance test — the whole Telegram channel surface, end-to-end
// through the E.5 `LoopbackChatApi` double.
//
// Where E.19 – E.22 each unit-tested one substep (scaffold lifecycle, inbound
// mapping, outbound consolidation, the whitelist gate), this is the
// **black-box conformance suite** the plan calls for (Plan § Phase E, E.23):
// it drives a message *in* through the loopback client and an answer back
// *out* through the same client on one running adapter, exercising the
// composed inbound→authorise→outbound path rather than any single piece. The
// three plan bullets:
//
//   1. **Roundtrip through the test-time loopback client.** A whitelisted
//      sender's message is injected; it surfaces on
//      `authorizedInboundRequests` (mapped, E.20); the adapter then sends an
//      answer back to that conversation via `sendAnswer` (consolidated, E.21);
//      the answer lands on the loopback's recorded outbound. The full
//      inbound→outbound cycle composes over one adapter and its lifecycle.
//   2. **Whitelist enforcement** at the integrated level (now that the adapter
//      is running): a non-whitelisted sender is declined and never produces a
//      request — no `Access` is built (AC-3, AC-4).
//   3. **Large-answer chunking respects Telegram's message-size limit.** A
//      genuinely large answer (> `telegramMaxMessageLength`) driven through
//      `sendAnswer` at the **real 4096 limit** is split into the minimum
//      number of size-compliant messages, every one ≤ 4096 code units, all
//      plain text to the same receiver, losslessly reconstructing the answer.
//
// Distinct from the substep tests, this suite uses the production default
// limit (4096) on a started adapter and ties the two halves together, so it
// would fail if the inbound and outbound paths were individually correct but
// did not compose. Per the per-substep scope of the earlier steps it still
// does NOT assert the `DeliveryRegistry` wiring (E.36+), backpressure
// (E.39–E.40), identity / session / persona (E.24–E.27), or dispatcher wiring
// (boot, E.41+) — those arrive in their own steps.

import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:tom_chattools/tom_chattools.dart';
import 'package:test/test.dart';

import '../_support/loopback_chat_api.dart';

/// Lets the adapter's `asyncExpand` gate drain its awaited microtasks (an
/// awaited `sendMessage` per rejected message) before assertions.
Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 20));

/// Emits [deltas] as `OutboundChunk`s, the last one `isFinal`, mirroring the
/// engine's answer step (D.38 / proto spec § 10.1).
Stream<OutboundChunk> _answer(List<String> deltas) async* {
  for (var i = 0; i < deltas.length; i++) {
    yield OutboundChunk(
      textDelta: deltas[i],
      isFinal: i == deltas.length - 1,
      index: i,
    );
  }
}

void main() {
  group('Telegram roundtrip — inbound → authorise → outbound (loopback)', () {
    test('a whitelisted message round-trips to a consolidated answer back '
        'on the same conversation', () async {
      final api = LoopbackChatApi();
      final adapter = TelegramAdapter(
        chatApi: api,
        whitelist: TelegramWhitelist(const ['42']),
      );

      // Attach the inbound listener before start (the eager broadcast relay,
      // Q-E.19.1) so the first post-start message is not missed.
      final requests = <InboundRequest>[];
      adapter.authorizedInboundRequests.listen(requests.add);

      await adapter.start();
      api.injectText(senderId: '42', text: 'What is the capital of France?');
      await _pump();

      // Inbound half: the message surfaced, mapped, with no decline sent.
      expect(requests, hasLength(1));
      final InboundRequest request = requests.single;
      expect(request.text, 'What is the capital of France?');
      expect(request.streaming, isFalse); // single-message channel (§ Q13).
      expect(request.conversationId, '42'); // private chat id == sender id.
      expect(
        request.metadata[telegramSenderIdMetadataKey],
        '42',
      );
      expect(api.sentMessages, isEmpty); // nothing sent yet — request only.

      // Outbound half: answer the request on its own conversation. Boot
      // (E.41+) is what wires this to the engine's deliver callback; here we
      // close the loop directly to prove the two halves compose.
      final sent = await adapter.sendAnswer(
        receiver: ChatReceiver.id(request.conversationId!),
        answer: _answer(['The capital of France is ', 'Paris.']),
      );

      expect(sent, hasLength(1));
      expect(api.sentMessages, ['The capital of France is Paris.']);
      expect(api.sentReceivers.single, const ChatReceiver.id('42'));
      // Stage-1: plain text — no parseMode, no buttons, no typing indicator.
      expect(api.sentParseModes.single, isNull);

      await adapter.stop();
    });

    test('the roundtrip survives the full lifecycle: nothing after stop',
        () async {
      final api = LoopbackChatApi();
      final adapter = TelegramAdapter(
        chatApi: api,
        whitelist: TelegramWhitelist(const ['1']),
      );
      final requests = <InboundRequest>[];
      adapter.authorizedInboundRequests.listen(requests.add);

      await adapter.start();
      api.injectText(senderId: '1', text: 'before stop');
      await _pump();
      await adapter.stop();

      // After stop the relay is closed; one request was delivered, the
      // backend was disconnected exactly once.
      expect(requests.map((r) => r.text), ['before stop']);
      expect(api.disconnectCount, 1);
      expect(api.isConnected, isFalse);
    });
  });

  group('Telegram whitelist enforcement — end-to-end on a running adapter',
      () {
    test('a non-whitelisted sender is declined and never produces a request',
        () async {
      final api = LoopbackChatApi();
      final adapter = TelegramAdapter(
        chatApi: api,
        whitelist: TelegramWhitelist(const ['42']),
      );
      final requests = <InboundRequest>[];
      adapter.authorizedInboundRequests.listen(requests.add);

      await adapter.start();
      api.injectText(senderId: '999', text: 'let me in');
      await _pump();

      // No Access-bound request; the graceful decline went back to the sender.
      expect(requests, isEmpty);
      expect(api.sentMessages, [telegramNotAuthorisedMessage]);
      expect(api.sentReceivers.single, const ChatReceiver.id('999'));
      expect(api.sentParseModes.single, isNull);

      await adapter.stop();
    });

    test('mixed traffic: only whitelisted senders round-trip, each rejected '
        'sender draws exactly one decline', () async {
      final api = LoopbackChatApi();
      final adapter = TelegramAdapter(
        chatApi: api,
        whitelist: TelegramWhitelist(const ['1', '2']),
      );
      final texts = <String>[];
      adapter.authorizedInboundRequests.listen((r) => texts.add(r.text));

      await adapter.start();
      api.injectText(senderId: '1', text: 'kept-1');
      api.injectText(senderId: '999', text: 'dropped-a');
      api.injectText(senderId: '2', text: 'kept-2');
      api.injectText(senderId: '888', text: 'dropped-b');
      await _pump();

      expect(texts, ['kept-1', 'kept-2']);
      // One decline per rejected sender, addressed to each.
      expect(
        api.sentMessages,
        [telegramNotAuthorisedMessage, telegramNotAuthorisedMessage],
      );
      expect(
        api.sentReceivers,
        [const ChatReceiver.id('999'), const ChatReceiver.id('888')],
      );

      await adapter.stop();
    });

    test('the default (unconfigured) whitelist rejects everyone at the edge',
        () async {
      final api = LoopbackChatApi();
      // No whitelist argument → the closed `TelegramWhitelist.empty()` default
      // (Q-E.22.1): an unconfigured deployment admits no one.
      final adapter = TelegramAdapter(chatApi: api);
      final requests = <InboundRequest>[];
      adapter.authorizedInboundRequests.listen(requests.add);

      await adapter.start();
      api.injectText(senderId: '1', text: 'anyone home');
      await _pump();

      expect(requests, isEmpty);
      expect(api.sentMessages, [telegramNotAuthorisedMessage]);

      await adapter.stop();
    });
  });

  group('Telegram large-answer chunking — at the real 4096 limit', () {
    test('an answer over the limit is split into the minimum number of '
        'size-compliant messages, losslessly', () async {
      final api = LoopbackChatApi();
      // The production default limit (no injected small budget) — this is the
      // real-limit conformance the plan asks for.
      final adapter = TelegramAdapter(
        chatApi: api,
        whitelist: TelegramWhitelist(const ['42']),
      );

      // 10000 code units > 4096: ceil(10000 / 4096) = 3 messages.
      final String big = 'a' * 10000;
      final sent = await adapter.sendAnswer(
        receiver: const ChatReceiver.id('42'),
        answer: _answer([big]),
      );

      expect(sent, hasLength(3));
      // Every delivered message is within Telegram's per-message limit.
      for (final String message in api.sentMessages) {
        expect(message.length, lessThanOrEqualTo(telegramMaxMessageLength));
      }
      // Minimal count: 4096 + 4096 + 1808.
      expect(
        api.sentMessages.map((m) => m.length),
        [telegramMaxMessageLength, telegramMaxMessageLength, 1808],
      );
      // Lossless across the wire and all to the same conversation, plain text.
      expect(api.sentMessages.join(), big);
      expect(api.sentReceivers, everyElement(const ChatReceiver.id('42')));
      expect(api.sentParseModes, everyElement(isNull));
    });

    test('an over-limit answer assembled from many chunks chunks correctly',
        () async {
      final api = LoopbackChatApi();
      final adapter = TelegramAdapter(chatApi: api);

      // 1000 chunks of 10 chars = 10000 code units, split across chunks so the
      // consolidator must buffer the whole stream before splitting.
      final List<String> deltas =
          List<String>.generate(1000, (_) => '0123456789');
      final sent = await adapter.sendAnswer(
        receiver: const ChatReceiver.id('7'),
        answer: _answer(deltas),
      );

      expect(sent, hasLength(3)); // ceil(10000 / 4096) = 3.
      expect(
        api.sentMessages.every((m) => m.length <= telegramMaxMessageLength),
        isTrue,
      );
      expect(api.sentMessages.join(), deltas.join());
    });

    test('an astral-heavy over-limit answer never splits a character and '
        'stays within the limit', () async {
      final api = LoopbackChatApi();
      final adapter = TelegramAdapter(chatApi: api);

      // 2049 emoji = 2049 runes = 4098 UTF-16 code units > 4096. The split
      // must keep each emoji whole, so the first message holds 2048 emoji
      // (4096 units) and the second holds the remaining one (2 units) — never
      // half an emoji, never an over-limit message.
      final String emojiWall = '😀' * 2049;
      final sent = await adapter.sendAnswer(
        receiver: const ChatReceiver.id('5'),
        answer: _answer([emojiWall]),
      );

      expect(sent, hasLength(2));
      expect(api.sentMessages[0].length, telegramMaxMessageLength); // 4096.
      expect(api.sentMessages[0].runes.length, 2048);
      expect(api.sentMessages[1].length, 2); // one emoji = 2 code units.
      expect(api.sentMessages[1].runes.length, 1);
      for (final String message in api.sentMessages) {
        expect(message.length, lessThanOrEqualTo(telegramMaxMessageLength));
      }
      // Lossless: no surrogate pair was cut in half.
      expect(api.sentMessages.join(), emojiWall);
    });

    test('an answer exactly at the limit is delivered as one message',
        () async {
      final api = LoopbackChatApi();
      final adapter = TelegramAdapter(chatApi: api);

      final String exact = 'x' * telegramMaxMessageLength;
      final sent = await adapter.sendAnswer(
        receiver: const ChatReceiver.id('9'),
        answer: _answer([exact]),
      );

      expect(sent, hasLength(1));
      expect(api.sentMessages.single.length, telegramMaxMessageLength);
      expect(api.sentMessages.single, exact);
    });
  });
}
