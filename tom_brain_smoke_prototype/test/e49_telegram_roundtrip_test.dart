// E.49 — end-to-end Telegram roundtrip smoke.
//
// Plan step E.49 (verbatim): "Send a Telegram message via the loopback client.
// Verify the answer is delivered and that the whitelist gates a non-whitelisted
// sender."
//
// Where E.47 / E.48 proved the OpenAI channel end-to-end, E.49 proves the
// *Telegram* channel through the same booted cognition. The smoke now stands the
// Telegram edge up over an injected loopback `ChatApi`: a message injected into
// the loopback flows through the adapter's whitelist gate, the access edge's
// admission pipeline, the dispatcher, the stub substrate, and the buffered
// Telegram delivery path back to the loopback as the sent answer.
//
// Two obligations:
//
//   1. DELIVERY — a whitelisted sender's message runs `answer_with_memory_v1`
//      to completion; the consolidated answer is delivered back as a Telegram
//      message addressed to that sender, and the exchange is persisted (one
//      `Event` + one `Conclusion`).
//   2. THE WHITELIST GATE — a non-whitelisted sender is rejected at the edge:
//      the graceful decline is sent back and nothing else (no `Access` is built,
//      so no `Event` / `Conclusion` is written).

import 'package:tom_brain_access/tom_brain_access.dart'
    show telegramNotAuthorisedMessage;
import 'package:tom_brain_memory/tom_brain_memory.dart' show MemoryStats;
import 'package:tom_brain_smoke_prototype/tom_brain_smoke_prototype.dart';
import 'package:tom_chattools/tom_chattools.dart' show ChatReceiver;
import 'package:test/test.dart';

import '_support/loopback_chat_api.dart';

/// The chunked answer the stub substrate streams; its concatenation is the
/// answer the Telegram channel must deliver.
const List<String> _answerChunks = <String>['Back up by ', 'rsyncing nightly.'];
const String _answerText = 'Back up by rsyncing nightly.';

/// The Telegram bot token the smoke configures (any non-null value makes the
/// access process stand the Telegram edge up; the loopback ignores it).
const String _botToken = 'smoke-bot-token';

/// The whitelisted sender id, and the one outside the whitelist.
const String _allowedSender = 'tg-allowed';
const String _blockedSender = 'tg-blocked';

/// Polls until the loopback has recorded at least [atLeast] sent message(s), or
/// throws on [timeout]. The whole Telegram path is async across the memory
/// worker isolate, so the test waits for delivery rather than assuming it is
/// synchronous.
Future<void> _waitForSent(
  LoopbackChatApi loopback, {
  int atLeast = 1,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (loopback.sentMessages.length < atLeast) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError(
        'timed out waiting for $atLeast sent Telegram message(s); '
        'got ${loopback.sentMessages.length}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  group('E.49 Telegram roundtrip', () {
    late LoopbackChatApi loopback;
    late SmokeProcess smoke;

    setUp(() async {
      loopback = LoopbackChatApi();
      smoke = await standUpSmokeProcess(
        substrate: SmokeSubstrate()
          ..answerChunks = List<String>.of(_answerChunks),
        telegramBotToken: _botToken,
        telegramWhitelist: const <String>{_allowedSender},
        telegramChatApiFactory: (_) => loopback,
      );
    });

    tearDown(() async {
      await smoke.stop();
    });

    test('a whitelisted sender gets the answer delivered back', () async {
      loopback.injectText(
        senderId: _allowedSender,
        text: 'how do I automate backups?',
      );

      await _waitForSent(loopback);

      // Exactly one message was sent back: the consolidated answer (the
      // prototype's single procedure produces the whole answer as one part).
      expect(loopback.sentMessages, hasLength(1));
      expect(loopback.sentMessages.single, _answerText);

      // It was addressed to the sender's chat.
      final ChatReceiver receiver = loopback.sentReceivers.single;
      expect(receiver, ChatReceiver.id(_allowedSender));
    });

    test('the run persists an Event + a Conclusion', () async {
      loopback.injectText(
        senderId: _allowedSender,
        text: 'how do I automate backups?',
      );

      await _waitForSent(loopback);

      final MemoryStats stats = await smoke.memory.stats();
      expect(stats.nodeCountByType['Event'], 1);
      expect(stats.nodeCountByType['Conclusion'], 1);
      expect(stats.trailCount, greaterThanOrEqualTo(1));
    });
  });

  group('E.49 Telegram whitelist gate', () {
    late LoopbackChatApi loopback;
    late SmokeProcess smoke;

    setUp(() async {
      loopback = LoopbackChatApi();
      smoke = await standUpSmokeProcess(
        substrate: SmokeSubstrate()
          ..answerChunks = List<String>.of(_answerChunks),
        telegramBotToken: _botToken,
        telegramWhitelist: const <String>{_allowedSender},
        telegramChatApiFactory: (_) => loopback,
      );
    });

    tearDown(() async {
      await smoke.stop();
    });

    test('a non-whitelisted sender draws the graceful decline, nothing more',
        () async {
      loopback.injectText(
        senderId: _blockedSender,
        text: 'let me in please',
      );

      // The edge gate sends exactly the decline, addressed to the rejected
      // sender. Wait for it, then prove nothing else arrives.
      await _waitForSent(loopback);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(loopback.sentMessages, hasLength(1));
      expect(loopback.sentMessages.single, telegramNotAuthorisedMessage);
      expect(loopback.sentReceivers.single, ChatReceiver.id(_blockedSender));
    });

    test('a gated request builds no Access — nothing is written to memory',
        () async {
      loopback.injectText(
        senderId: _blockedSender,
        text: 'let me in please',
      );

      await _waitForSent(loopback);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final MemoryStats stats = await smoke.memory.stats();
      expect(stats.nodeCountByType['Event'] ?? 0, 0);
      expect(stats.nodeCountByType['Conclusion'] ?? 0, 0);
    });
  });
}
