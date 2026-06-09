// E.21 contract test — the Telegram streamed-answer → consolidated-message
// outbound mapping.
//
// Two surfaces are exercised:
//   * The pure consolidation `TelegramOutboundConsolidator`
//     (telegram_outbound_mapping.dart): buffering a chunk stream into the
//     full answer, the single-message fit, the minimum-count overflow split,
//     character-safe (whole-rune) boundaries, UTF-16-code-unit counting, and
//     the empty-answer-sends-nothing rule.
//   * The adapter's `sendAnswer` method: consolidating + sending through the
//     E.5 `LoopbackChatApi` double's recorded outbound calls (Stage-1 plain
//     text — no parseMode).
//
// Per the E.21 scope ruling this test deliberately does NOT assert the
// `DeliveryRegistry` wiring (E.36+), backpressure / `DeliveryStalled`
// (E.39–E.40), whitelist behaviour (E.22), or dispatcher wiring (boot,
// E.41+).

import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:tom_chattools/tom_chattools.dart';
import 'package:test/test.dart';

import '../_support/loopback_chat_api.dart';

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
  group('TelegramOutboundConsolidator.split — pure splitting', () {
    const consolidator = TelegramOutboundConsolidator();

    test('an empty answer produces no messages (nothing to send)', () {
      expect(consolidator.split(''), isEmpty);
    });

    test('an answer within the limit is one message, verbatim', () {
      final answer = 'a' * telegramMaxMessageLength;
      final parts = consolidator.split(answer);
      expect(parts, hasLength(1));
      expect(parts.single, answer);
      expect(parts.single.length, telegramMaxMessageLength);
    });

    test('an answer one character over the limit splits into two', () {
      final answer = 'a' * (telegramMaxMessageLength + 1);
      final parts = consolidator.split(answer);
      expect(parts, hasLength(2));
      expect(parts[0].length, telegramMaxMessageLength);
      expect(parts[1].length, 1);
      // Lossless: the concatenation reproduces the answer exactly.
      expect(parts.join(), answer);
    });

    test('the split is minimal: ceil(len / limit) messages', () {
      // A small budget makes the arithmetic legible.
      const small = TelegramOutboundConsolidator(maxMessageLength: 10);
      final answer = 'x' * 25; // 25 / 10 → 3 messages.
      final parts = small.split(answer);
      expect(parts, hasLength(3));
      expect(parts.map((p) => p.length), [10, 10, 5]);
      expect(parts.join(), answer);
    });

    test('never splits a character: astral runes stay whole', () {
      // '😀' is one rune = two UTF-16 code units. With a budget of 3 units a
      // message holds exactly one emoji (2 units); a second emoji would push
      // it to 4 > 3, so each emoji lands in its own message — never half an
      // emoji.
      const tiny = TelegramOutboundConsolidator(maxMessageLength: 3);
      const answer = '😀😀😀';
      final parts = tiny.split(answer);
      expect(parts, hasLength(3));
      for (final part in parts) {
        expect(part, '😀');
        expect(part.runes.length, 1);
      }
      expect(parts.join(), answer);
    });

    test('counts UTF-16 code units, not runes, against the limit', () {
      // Four emoji = 4 runes but 8 UTF-16 code units. With a budget of 4
      // units that is two messages of two emoji each (4 units), not one.
      const budget4 = TelegramOutboundConsolidator(maxMessageLength: 4);
      const answer = '😀😀😀😀';
      final parts = budget4.split(answer);
      expect(parts, hasLength(2));
      expect(parts.every((p) => p.length == 4), isTrue); // 4 code units each.
      expect(parts.every((p) => p.runes.length == 2), isTrue);
      expect(parts.join(), answer);
    });
  });

  group('TelegramOutboundConsolidator.consolidate — chunk buffering', () {
    const consolidator = TelegramOutboundConsolidator();

    test('buffers all chunk deltas into one message when they fit', () async {
      final parts =
          await consolidator.consolidate(_answer(['Hello, ', 'brain', '!']));
      expect(parts, ['Hello, brain!']);
    });

    test('includes text carried on the final-marked chunk', () async {
      // The last chunk is isFinal AND carries text — that text must be kept.
      final parts = await consolidator.consolidate(_answer(['part1', 'part2']));
      expect(parts.single, 'part1part2');
    });

    test('an empty stream yields no messages', () async {
      final parts = await consolidator.consolidate(const Stream.empty());
      expect(parts, isEmpty);
    });

    test('a stream of only empty deltas yields no messages', () async {
      final parts = await consolidator.consolidate(_answer(['', '', '']));
      expect(parts, isEmpty);
    });

    test('buffered overflow splits into the minimum count', () async {
      const small = TelegramOutboundConsolidator(maxMessageLength: 5);
      final parts = await small.consolidate(_answer(['abc', 'defg', 'hij']));
      // 'abcdefghij' = 10 chars / 5 → 2 messages.
      expect(parts, ['abcde', 'fghij']);
    });
  });

  group('TelegramAdapter.sendAnswer — consolidate + send', () {
    test('sends one plain-text message for a fitting answer', () async {
      final api = LoopbackChatApi();
      final adapter = TelegramAdapter(chatApi: api);

      final sent = await adapter.sendAnswer(
        receiver: const ChatReceiver.id('42'),
        answer: _answer(['the ', 'answer']),
      );

      expect(api.sentMessages, ['the answer']);
      expect(api.sentReceivers.single, const ChatReceiver.id('42'));
      // Stage-1: plain text — no parseMode, no buttons, no typing indicator.
      expect(api.sentParseModes.single, isNull);
      expect(sent, hasLength(1));
      expect(sent.single.text, 'the answer');
    });

    test('sends the minimum number of messages for an overflowing answer',
        () async {
      final api = LoopbackChatApi();
      final adapter = TelegramAdapter(
        chatApi: api,
        outboundConsolidator:
            const TelegramOutboundConsolidator(maxMessageLength: 4),
      );

      final sent = await adapter.sendAnswer(
        receiver: const ChatReceiver.id('7'),
        answer: _answer(['abcdefghij']), // 10 / 4 → 3 messages.
      );

      expect(api.sentMessages, ['abcd', 'efgh', 'ij']);
      // Every part addressed to the same receiver, in order.
      expect(
        api.sentReceivers,
        everyElement(const ChatReceiver.id('7')),
      );
      expect(api.sentParseModes, everyElement(isNull));
      expect(sent, hasLength(3));
      // Lossless across the wire: the parts reconstruct the answer.
      expect(api.sentMessages.join(), 'abcdefghij');
    });

    test('sends nothing for an empty answer', () async {
      final api = LoopbackChatApi();
      final adapter = TelegramAdapter(chatApi: api);

      final sent = await adapter.sendAnswer(
        receiver: const ChatReceiver.id('1'),
        answer: _answer(['']),
      );

      expect(api.sentMessages, isEmpty);
      expect(sent, isEmpty);
    });
  });
}
