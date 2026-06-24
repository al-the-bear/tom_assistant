// r52 — LIVE end-to-end, Telegram `/switch_profile` then a prompt under the new
// profile (session_configuration_plan.md step 12; `session_configuration.md`
// § 6 / SC-6).
//
// r51 proves the Profile axis over the OpenAI gateway (the credential marker
// carries the profile). This suite proves the *Telegram* half of the same axis:
// the channel owns profile selection on the user's behalf — there is no
// credential marker — so a `/switch_profile` slash-command changes which profile
// the chat's *next* ordinary prompt is processed under, end to end over the real
// substrate.
//
// One chat, two inbound messages, one live answer:
//
//   * `/switch_profile relay` — an access-layer command (it never reaches the
//     brain): the edge replies "Now using profile relay" and the chat's active
//     profile becomes `relay` (`mode: passthrough`, `anchored: false`).
//   * an ordinary prompt — now processed under `relay`, so the dispatcher routes
//     it to `passthrough_v1` *only* (no classifier, no answer-with-memory), the
//     single LLM call's raw trail records `anchorHash == 'unanchored'`, and the
//     streamed answer is delivered back over the same Telegram chat.
//
// The Telegram backend is an in-process `LoopbackChatApi` (a `ChatApi` double)
// injected through the `telegramChatApiFactory` seam `standUpBrainProcessFromConfig`
// threads to the access process — no televerse `Bot`, no socket. The test feeds
// inbound messages into the loopback and reads the recorded outbound to assert
// the command acknowledgement and the delivered answer; the on-disk trail proves
// which entry procedure ran.
//
// Like r51 this is a LIVE suite: the substrate is the real one
// `standUpBrainProcessFromConfig` builds (oMLX for chat, Ollama for embeddings).
// Off-host it skips per the same daemon-reachability probe; on a platform with no
// packaged vec0 the whole group skips. The relay carries no Claude pin (it
// inherits the `assistant` → oMLX route directly), so the answer streams from
// oMLX exactly as r51's relay leg does.

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_brain_access/tom_brain_access.dart' show serveWithShelfIo;
import 'package:tom_brain_run/tom_brain_run.dart';

import 'support/live_e2e_harness.dart';
import 'support/loopback_chat_api.dart';

/// The bot token the config enables the Telegram channel with. Never used to
/// reach a network — the loopback `ChatApi` stands in for the backend — but a
/// non-empty token is what flips `AccessConfig.hasTelegram` on.
const String _botToken = 'r52-loopback-bot-token';

/// The whitelisted Telegram sender id. A private chat's id equals its user id,
/// so the same value keys the inbound mapping's `conversationId`.
const String _telegramUserId = 'tg-owner-1';

/// The Profile selection-axis registry (§ 6): the built-in `default` (cognitive)
/// plus the `relay` profile the chat switches to — the memory-free, un-anchored
/// passthrough.
const String _profilesBlock = '''
profiles:
  default:
    mode: cognitive
  relay:
    mode: passthrough
    anchored: false
''';

void main() {
  // The real providers source their wire HTTP client from `tom_core_kernel` via
  // the active `TomPlatformUtils`; the standalone platform makes the live HTTP
  // path work under `dart test` / testkit (mirrors r51).
  setUpAll(installStandalonePlatformForLiveHttp);

  final String? vecRoot = findSqliteVecRoot();
  final String? skipNoBinary = sqliteVecSkipReason(vecRoot);

  group('r52 LIVE end-to-end — Telegram /switch_profile then a prompt', () {
    /// Stands a live process up whose config enables the Telegram channel
    /// (driven by [loopback]) and carries the profiles registry + a disk trail
    /// rooted at a fresh temp dir, returning the process + the trail root.
    Future<({BrainProcess process, Directory trailRoot})> standUpLive({
      required LoopbackChatApi loopback,
      required LiveEndpoint omlx,
      required LiveEndpoint ollama,
    }) async {
      final Directory memoryRoot =
          Directory.systemTemp.createTempSync('tom_brain_run_52_mem_');
      final Directory trailRoot =
          Directory.systemTemp.createTempSync('tom_brain_run_52_trail_');
      addTearDown(() {
        if (memoryRoot.existsSync()) memoryRoot.deleteSync(recursive: true);
        if (trailRoot.existsSync()) trailRoot.deleteSync(recursive: true);
      });

      final BrainRunConfig config = BrainRunConfigLoader.parse(
        liveRunYaml(
          omlx: omlx,
          ollama: ollama,
          memoryRoot: memoryRoot.path,
          binariesRoot: vecRoot!,
          cognitionRoot: cognitionConfigRoot(),
          accessBlock: telegramAccessBlock(
            botToken: _botToken,
            telegramUserId: _telegramUserId,
          ),
          profilesBlock: _profilesBlock,
          trailBlock: 'trail:\n  root: "${trailRoot.path}"\n',
        ),
      );
      final BrainProcess process = await standUpBrainProcessFromConfig(
        config,
        serve: (handler, _) => serveWithShelfIo(handler, 0),
        // The loopback stands in for the Telegram backend — the same instance
        // regardless of the (unused) bot token the factory is handed.
        telegramChatApiFactory: (_) => loopback,
      );
      return (process: process, trailRoot: trailRoot);
    }

    Future<String?> skipUnlessLive() async {
      // The relay profile is passthrough-only — no memory recall, so no
      // embedding call — so this leg needs *only* the oMLX chat daemon, not
      // Ollama (unlike r51, whose cognitive / answer legs drive memory recall).
      final omlx = omlxEndpoint();
      final omlxSkip = await omlx.unreachableReason();
      if (omlxSkip != null) return omlxSkip;
      return null;
    }

    test(
        '/switch_profile relay activates the profile, then a prompt is processed '
        'as an un-anchored passthrough and the answer is delivered', () async {
      final skip = await skipUnlessLive();
      if (skip != null) return markTestSkipped(skip);

      final loopback = LoopbackChatApi();
      final live = await standUpLive(
        loopback: loopback,
        omlx: omlxEndpoint(),
        ollama: ollamaEndpoint(),
      );
      try {
        // ── 1. The slash-command: switch the chat to the relay profile ──
        loopback.injectText(
          senderId: _telegramUserId,
          text: '/switch_profile relay',
          messageId: 's1',
        );
        await _waitUntil(() => loopback.sentMessages
            .any((m) => m.contains('Now using profile relay')));

        // The command was answered, addressed to the sending chat, and never
        // reached the brain (no procedure ran yet).
        expect(
          loopback.sentReceivers.last.toString(),
          contains(_telegramUserId),
          reason: 'the acknowledgement is addressed to the sending chat',
        );
        expect(_procedureRan(live.trailRoot, 'passthrough_v1'), isFalse,
            reason: 'the command is an access-layer concern, not a brain run');

        // ── 2. An ordinary prompt under the now-active relay profile ──
        final int beforeCount = loopback.sentMessages.length;
        loopback.injectText(
          senderId: _telegramUserId,
          text: 'In one short sentence, what is the capital of Portugal?',
          messageId: 'p1',
        );
        // The buffered Telegram delivery flushes the answer on the run's final
        // chunk; wait for a delivered message that is neither the "Processing"
        // acknowledgement nor the earlier command reply.
        await _waitUntil(() => loopback.sentMessages
            .skip(beforeCount)
            .any((m) => m.trim().isNotEmpty && !m.startsWith('Processing:')));

        final String answer = loopback.sentMessages
            .skip(beforeCount)
            .firstWhere(
                (m) => m.trim().isNotEmpty && !m.startsWith('Processing:'));
        expect(answer.trim(), isNotEmpty,
            reason: 'live oMLX must stream a non-empty completion to the chat');
      } finally {
        await live.process.stop();
      }

      // The prompt ran the relay procedure *only* — passthrough makes no
      // classifier call and touches no memory orchestration.
      expect(_procedureRan(live.trailRoot, 'passthrough_v1'), isTrue,
          reason: 'the relay profile enters through passthrough_v1');
      expect(_procedureRan(live.trailRoot, 'prompt_analyzer_v1'), isFalse,
          reason: 'passthrough makes no classifier call');
      expect(_procedureRan(live.trailRoot, 'answer_with_memory_v1'), isFalse,
          reason: 'passthrough touches no memory orchestration');

      // The single LLM call's raw trail records the un-anchored sentinel — proof
      // the dedication anchor was omitted for this `anchored: false` profile
      // (§ 3.4 / SCP-37). It is the literal `unanchored`, not a `sha256:` digest.
      final anchorHashes = _llmAnchorHashes(live.trailRoot);
      expect(anchorHashes, isNotEmpty,
          reason: 'the relay made exactly one LLM call, captured to the trail');
      expect(anchorHashes, everyElement('unanchored'),
          reason: 'an anchored: false passthrough records the un-anchored '
              'sentinel, never a sha256: anchor digest');
    }, timeout: const Timeout(Duration(minutes: 5)));
  }, skip: skipNoBinary);
}

/// Polls [ready] every 50 ms until it is true or [timeout] elapses (then fails).
/// The live answer arrives asynchronously over the loopback outbound, so the
/// test waits on the recorded `sentMessages` rather than a fixed delay.
Future<void> _waitUntil(
  bool Function() ready, {
  Duration timeout = const Duration(minutes: 2),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out after $timeout waiting for the expected Telegram outbound');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// True when the trail recorded at least one run of [procedureId]: the §5.7
/// per-procedure tree writer emits `procedures/<procedureId>/<turnId>__<runId>.log`,
/// so the procedure's directory exists and is non-empty iff it ran.
bool _procedureRan(Directory trailRoot, String procedureId) {
  final dir = Directory('${trailRoot.path}/procedures/$procedureId');
  return dir.existsSync() &&
      dir.listSync().whereType<File>().any((f) => f.path.endsWith('.log'));
}

/// The `anchorHash` of every raw LLM call the trail captured: the §5.2 writer
/// emits `llm/<callType>/<turnId>__<callSeq>.raw.json` carrying `anchorHash`.
List<String> _llmAnchorHashes(Directory trailRoot) {
  final llmDir = Directory('${trailRoot.path}/llm');
  if (!llmDir.existsSync()) return const <String>[];
  return llmDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.raw.json'))
      .map((f) =>
          (jsonDecode(f.readAsStringSync()) as Map<String, Object?>)['anchorHash']
              as String)
      .toList(growable: false);
}
