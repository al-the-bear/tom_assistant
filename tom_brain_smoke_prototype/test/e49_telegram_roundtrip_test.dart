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
import '_support/telegram_outbound.dart';

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

    const String promptText = 'how do I automate backups?';

    test('a whitelisted sender gets the answer delivered back', () async {
      loopback.injectText(senderId: _allowedSender, text: promptText);

      await waitForAnswersTo(loopback, _allowedSender, prompts: <String>[promptText]);

      // Exactly one substantive message was answered back: the consolidated
      // answer (the prototype's single procedure produces the whole answer as
      // one part). The boot startup announcement and the per-prompt processing
      // acknowledgement are control pings, stripped here.
      final List<String> answers =
          answerMessagesTo(loopback, _allowedSender, prompts: <String>[promptText]);
      expect(answers, <String>[_answerText]);
    });

    test(
        'the channel wraps the answer in the startup announcement and the '
        'processing acknowledgement', () async {
      loopback.injectText(senderId: _allowedSender, text: promptText);

      await waitForAnswersTo(loopback, _allowedSender, prompts: <String>[promptText]);

      // The delivered sequence opens with the boot ping then the immediate
      // "Processing" echo — both control pings the buffered edge sends before
      // the run produces anything. (Out-of-band tool/thinking notices and the
      // answer follow; the contract under test here is the two leading control
      // pings, asserted by their fixed positions.)
      expect(loopback.sentMessages.first, smokeStartupAnnouncement());
      expect(loopback.sentMessages[1], smokeProcessingAck(promptText));
      // The substantive answer (notices and pings stripped) is the consolidated
      // answer text, and every message went to the sender's chat.
      expect(
        answerMessagesTo(loopback, _allowedSender,
            prompts: <String>[promptText]),
        <String>[_answerText],
      );
      expect(
        loopback.sentReceivers,
        everyElement(ChatReceiver.id(_allowedSender)),
      );
    });

    test('the run persists an Event + a Conclusion', () async {
      loopback.injectText(senderId: _allowedSender, text: promptText);

      await waitForAnswersTo(loopback, _allowedSender, prompts: <String>[promptText]);

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
      // sender — no "Processing" ack (the request never admitted) and no answer.
      // The boot startup announcement goes to the *whitelisted* owner, not the
      // blocked sender, so the blocked sender's only message is the decline.
      await waitForAnswersTo(loopback, _blockedSender);

      expect(
        answerMessagesTo(loopback, _blockedSender),
        <String>[telegramNotAuthorisedMessage],
      );
    });

    test('a gated request builds no Access — nothing is written to memory',
        () async {
      loopback.injectText(
        senderId: _blockedSender,
        text: 'let me in please',
      );

      await waitForAnswersTo(loopback, _blockedSender);

      final MemoryStats stats = await smoke.memory.stats();
      expect(stats.nodeCountByType['Event'] ?? 0, 0);
      expect(stats.nodeCountByType['Conclusion'] ?? 0, 0);
    });
  });
}
