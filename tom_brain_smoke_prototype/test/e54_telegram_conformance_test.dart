// E.54 — API conformance tests, Telegram (black-box, through the running
// process, over the `tom_chattools` test loopback).
//
// Plan step E.54 (verbatim): "API conformance tests — Telegram: a black-box
// test suite using the `tom_chattools` test loopback. Cover normal message,
// whitelist rejection, large-message chunking, auth-failure messaging."
//
// ── What this step is, and how it differs from E.49 ──────────────────
//
// E.49 is the *smoke* — the minimal proof that the Telegram channel rounds a
// short prompt to an answer through the booted cognition (one delivery, one
// whitelist gate). E.54 is the *conformance* pass: it drives the same running
// process over the same `tom_chattools` loopback, but asserts the four wire
// obligations the Telegram channel contract owns, end-to-end through boot:
//
//   1. NORMAL MESSAGE — a whitelisted sender's prompt runs
//      `answer_with_memory_v1` to completion; the consolidated answer is
//      delivered back as exactly one plain-text Telegram message addressed to
//      that sender, losslessly, and the exchange is persisted (Event +
//      Conclusion).
//   2. WHITELIST REJECTION — a non-whitelisted sender is gated at the edge: no
//      `Access` is built (no Event / Conclusion written).
//   3. LARGE-MESSAGE CHUNKING — an answer over Telegram's real 4096-code-unit
//      per-message limit is split, through the running process's buffered
//      delivery path (the boot wires `const TelegramChannelDelivery()` at the
//      4096 default), into the minimum number of size-compliant messages: each
//      ≤ 4096, all to the same chat, losslessly reconstructing the answer, and
//      never cutting an astral character in half.
//   4. AUTH-FAILURE MESSAGING — the gated sender draws exactly the
//      `telegramNotAuthorisedMessage` graceful decline, addressed to that
//      sender, and nothing more.
//
// Where E.53 drives the OpenAI channel over a real TCP socket, E.54 drives the
// Telegram channel over the in-process `tom_chattools` loopback the plan names
// (there is no Telegram network in the prototype — the loopback IS the wire).
// Both are black-box against the already-booted running process; neither
// reaches into the cognition.

import 'package:tom_brain_access/tom_brain_access.dart'
    show telegramMaxMessageLength, telegramNotAuthorisedMessage;
import 'package:tom_brain_memory/tom_brain_memory.dart' show MemoryStats;
import 'package:tom_brain_smoke_prototype/tom_brain_smoke_prototype.dart';
import 'package:tom_chattools/tom_chattools.dart' show ChatReceiver;
import 'package:test/test.dart';

import '_support/loopback_chat_api.dart';
import '_support/telegram_outbound.dart';

/// The Telegram bot token the smoke configures (any non-null value stands the
/// Telegram edge up; the loopback ignores it).
const String _botToken = 'conformance-bot-token';

/// The whitelisted sender id, and the one outside the whitelist.
const String _allowedSender = 'tg-conformance-allowed';
const String _blockedSender = 'tg-conformance-blocked';

void main() {
  late LoopbackChatApi loopback;
  late SmokeProcess smoke;

  /// Stands the running process up with the Telegram edge over a fresh loopback
  /// and the canned [answerChunks]. Records the handles so the single
  /// [tearDown] tears the process down.
  Future<void> stand(List<String> answerChunks) async {
    loopback = LoopbackChatApi();
    smoke = await standUpSmokeProcess(
      substrate: SmokeSubstrate()..answerChunks = List<String>.of(answerChunks),
      telegramBotToken: _botToken,
      telegramWhitelist: const <String>{_allowedSender},
      telegramChatApiFactory: (_) => loopback,
    );
  }

  tearDown(() async {
    await smoke.stop();
  });

  group('E.54 Telegram conformance — normal message', () {
    test('a whitelisted prompt delivers exactly one consolidated answer, '
        'addressed to the sender, losslessly', () async {
      const List<String> chunks = <String>['Back up by ', 'rsyncing nightly.'];
      const String answer = 'Back up by rsyncing nightly.';
      const String prompt = 'how do I automate backups?';
      await stand(chunks);

      loopback.injectText(senderId: _allowedSender, text: prompt);
      await waitForAnswersTo(loopback, _allowedSender,
          prompts: <String>[prompt]);

      // Under the 4096 limit → exactly one buffered answer message, plain text,
      // the whole answer (control pings and out-of-band notices stripped),
      // addressed to the sender's private chat.
      final List<String> answers = answerMessagesTo(loopback, _allowedSender,
          prompts: <String>[prompt]);
      expect(answers, hasLength(1));
      expect(answers.single, answer);
      expect(
        loopback.sentReceivers,
        everyElement(ChatReceiver.id(_allowedSender)),
      );
    });

    test('the normal-message run persists an Event + a Conclusion', () async {
      await stand(const <String>['ok']);

      loopback.injectText(senderId: _allowedSender, text: 'ping');
      await waitForAnswersTo(loopback, _allowedSender, prompts: <String>['ping']);

      final MemoryStats stats = await smoke.memory.stats();
      expect(stats.nodeCountByType['Event'], 1);
      expect(stats.nodeCountByType['Conclusion'], 1);
      expect(stats.trailCount, greaterThanOrEqualTo(1));
    });
  });

  group('E.54 Telegram conformance — whitelist rejection + auth-failure '
      'messaging', () {
    test('a non-whitelisted sender draws exactly the graceful decline, '
        'addressed to that sender, and nothing more', () async {
      await stand(const <String>['ok']);

      loopback.injectText(senderId: _blockedSender, text: 'let me in please');
      await waitForAnswersTo(loopback, _blockedSender);

      // The blocked sender's only substantive message is the decline — it never
      // admitted, so it draws no processing ack, and the startup announcement
      // goes to the whitelisted owner, not this sender.
      final List<String> answers = answerMessagesTo(loopback, _blockedSender);
      expect(answers, hasLength(1));
      expect(answers.single, telegramNotAuthorisedMessage);
    });

    test('a gated request builds no Access — nothing is written to memory',
        () async {
      await stand(const <String>['ok']);

      loopback.injectText(senderId: _blockedSender, text: 'let me in please');
      await waitForAnswersTo(loopback, _blockedSender);

      final MemoryStats stats = await smoke.memory.stats();
      expect(stats.nodeCountByType['Event'] ?? 0, 0);
      expect(stats.nodeCountByType['Conclusion'] ?? 0, 0);
    });
  });

  group('E.54 Telegram conformance — large-message chunking (real 4096 limit)',
      () {
    test('an over-limit answer is split into the minimum number of '
        'size-compliant messages, losslessly, all to the same chat', () async {
      // 10000 code units > 4096 ⇒ ceil(10000 / 4096) = 3 messages
      // (4096 + 4096 + 1808). The substrate streams it in several chunks so the
      // buffered delivery path must accumulate the whole answer before it
      // splits.
      const String big = 'aaaaaaaaaa'; // 10 units per chunk…
      final List<String> chunks =
          List<String>.generate(1000, (_) => big); // …× 1000 = 10000 units.
      final String whole = chunks.join();
      const String prompt = 'tell me a long story';
      await stand(chunks);

      loopback.injectText(senderId: _allowedSender, text: prompt);
      await waitForAnswersTo(loopback, _allowedSender,
          prompts: <String>[prompt], count: 3);

      // The answer parts only (control pings + out-of-band notices stripped):
      // the consolidator splits the buffered answer; the notices are single
      // un-split messages that never begin with answer text.
      final List<String> answers = answerMessagesTo(loopback, _allowedSender,
          prompts: <String>[prompt]);
      expect(answers, hasLength(3));
      // Every delivered part is within Telegram's per-message limit.
      for (final String message in answers) {
        expect(message.length, lessThanOrEqualTo(telegramMaxMessageLength));
      }
      // Minimal count: 4096 + 4096 + 1808.
      expect(
        answers.map((String m) => m.length).toList(),
        <int>[telegramMaxMessageLength, telegramMaxMessageLength, 1808],
      );
      // Lossless across the wire, every part to the sender's own chat.
      expect(answers.join(), whole);
      expect(
        loopback.sentReceivers,
        everyElement(ChatReceiver.id(_allowedSender)),
      );
    });

    test('an astral-heavy over-limit answer never splits a character and '
        'stays within the limit', () async {
      // 2049 emoji = 2049 runes = 4098 UTF-16 code units > 4096. The split must
      // keep each emoji whole: the first message holds 2048 emoji (4096 units),
      // the second the remaining one (2 units) — never half a surrogate pair.
      final String emojiWall = '😀' * 2049;
      const String prompt = 'emoji please';
      await stand(<String>[emojiWall]);

      loopback.injectText(senderId: _allowedSender, text: prompt);
      await waitForAnswersTo(loopback, _allowedSender,
          prompts: <String>[prompt], count: 2);

      final List<String> answers = answerMessagesTo(loopback, _allowedSender,
          prompts: <String>[prompt]);
      expect(answers, hasLength(2));
      expect(answers[0].length, telegramMaxMessageLength); // 4096
      expect(answers[0].runes.length, 2048);
      expect(answers[1].length, 2); // one emoji = 2 code units
      expect(answers[1].runes.length, 1);
      for (final String message in answers) {
        expect(message.length, lessThanOrEqualTo(telegramMaxMessageLength));
      }
      // Lossless: no surrogate pair was cut in half.
      expect(answers.join(), emojiWall);
    });

    test('an answer exactly at the limit is delivered as one message', () async {
      final String exact = 'x' * telegramMaxMessageLength;
      const String prompt = 'exact';
      await stand(<String>[exact]);

      loopback.injectText(senderId: _allowedSender, text: prompt);
      await waitForAnswersTo(loopback, _allowedSender,
          prompts: <String>[prompt]);

      final List<String> answers = answerMessagesTo(loopback, _allowedSender,
          prompts: <String>[prompt]);
      expect(answers, hasLength(1));
      expect(answers.single.length, telegramMaxMessageLength);
      expect(answers.single, exact);
    });
  });
}
