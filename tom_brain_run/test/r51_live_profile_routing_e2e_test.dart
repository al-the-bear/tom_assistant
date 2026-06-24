// r51 — LIVE end-to-end, Profile-axis entry-procedure routing
// (session_configuration_plan.md step 12; `session_configuration.md` § 3.8 / § 5).
//
// r32 proves the default cognitive chain; r50 proves the *memory*-profile
// isolation invariant. This suite proves the third selection axis — the
// **Profile** (processing shape) — end to end over the real substrate: the
// profile a request selects decides *which entry procedure runs*, and the run
// streams a live answer through it.
//
// Four requests, four profiles, three distinct entry-procedure signatures:
//
//   * `profile-research` → the `research` profile (`mode: cognitive`) →
//     `prompt_analyzer_v1` runs (the cognitive entry router). The trail's
//     `procedures/prompt_analyzer_v1/` tree is present.
//   * `profile-quick`    → the `quick` profile (`mode: answer`) →
//     `answer_with_memory_v1` *only*; no `prompt_analyzer_v1` (the answer mode
//     bypasses the classifier — dispatcher door 0, `resolveProcedureId`).
//   * `profile-relay`    → the `relay` profile (`mode: passthrough`,
//     `anchored: false`) → `passthrough_v1` *only*, and the single LLM call's
//     raw trail records `anchorHash == 'unanchored'` (the un-anchored wire
//     prompt — `AnchorRegistry.unanchoredHash`, § 3.4 / SCP-37). No memory,
//     no classifier, no answer-with-memory run.
//   * none (a bare key, no `profile-` marker) → the built-in `default` profile
//     (`mode: cognitive`) → `prompt_analyzer_v1` runs, exactly like `research`.
//
// Each leg stands up its own live process (its own on-disk memory + trail root),
// runs one request, stops, then reads the on-disk trail tree back — the trail is
// process-global config, so per-leg isolation requires per-leg processes (the
// r50 one-process-per-test shape).
//
// Like r32 / r50 this is a LIVE suite: the substrate is the real one
// `standUpBrainProcessFromConfig` builds from `substrate:` (oMLX for chat,
// Ollama for embeddings). Off-host it skips per-test (TCP reachability probe);
// on a platform with no packaged vec0 the whole group skips. The cognitive /
// answer legs route the user-facing answer to the `assistant_claude_brain` route
// (Claude), absent from the live substrate, so the answer falls back to the
// `assistant_to_user` → oMLX role route — the same fallback that lets r32 / r50
// stream live. The passthrough relay carries no Claude pin (it inherits the
// `assistant` → oMLX route directly).

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_brain_access/tom_brain_access.dart' show serveWithShelfIo;
import 'package:tom_brain_run/tom_brain_run.dart';

import 'support/live_e2e_harness.dart';

/// The single API key the run binds. Deliberately `_`-free (D-6) so the § 3.1
/// marker grammar — which splits the Bearer on `_` — never mistakes a key
/// segment for a `profile-` selector.
const String _apiKey = 'runkey-secret';

/// The four Bearer tokens: the bare key (→ `default`) and three `profile-<name>`
/// markers wrapped around it (→ the named profile).
const String _bareBearer = _apiKey;
const String _researchBearer = 'profile-research_$_apiKey';
const String _quickBearer = 'profile-quick_$_apiKey';
const String _relayBearer = 'profile-relay_$_apiKey';

/// The Profile selection-axis registry (§ 3.8) the run carries: the built-in
/// `default` (cognitive) plus the three profiles whose markers the legs present.
/// `research` is a full cognitive process; `quick` is single-shot `answer` mode
/// (no classifier); `relay` is the memory-free, un-anchored passthrough.
const String _profilesBlock = '''
profiles:
  default:
    mode: cognitive
  research:
    mode: cognitive
  quick:
    mode: answer
  relay:
    mode: passthrough
    anchored: false
''';

void main() {
  // The real providers source their wire HTTP client from `tom_core_kernel` via
  // the active `TomPlatformUtils`; the standalone platform makes the live HTTP
  // path work under `dart test` / testkit (mirrors r32 / r50).
  setUpAll(installStandalonePlatformForLiveHttp);

  final String? vecRoot = findSqliteVecRoot();
  final String? skipNoBinary = sqliteVecSkipReason(vecRoot);

  group('r51 LIVE end-to-end — Profile-axis entry-procedure routing', () {
    /// Stands a live process up whose config carries the profiles registry and a
    /// disk trail rooted at a fresh temp dir, returning the process + the trail
    /// root so the test can read the on-disk procedure / llm trees after stop.
    Future<({BrainProcess process, Directory trailRoot})> standUpLive({
      required LiveEndpoint omlx,
      required LiveEndpoint ollama,
    }) async {
      final Directory memoryRoot =
          Directory.systemTemp.createTempSync('tom_brain_run_51_mem_');
      final Directory trailRoot =
          Directory.systemTemp.createTempSync('tom_brain_run_51_trail_');
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
          accessBlock: bearerAccessBlock(_apiKey),
          profilesBlock: _profilesBlock,
          trailBlock: 'trail:\n  root: "${trailRoot.path}"\n',
        ),
      );
      final BrainProcess process = await standUpBrainProcessFromConfig(
        config,
        serve: (handler, _) => serveWithShelfIo(handler, 0),
      );
      return (process: process, trailRoot: trailRoot);
    }

    /// Streams one chat request under [bearer] and returns the assembled answer
    /// text, asserting the SSE shape (mirrors r50's frame walk).
    Future<String> streamAnswer(
      BrainProcess process, {
      required String bearer,
      required String prompt,
    }) async {
      final StreamPostResult result = await postForStream(
        process.port,
        '/v1/chat/completions',
        chatBody(prompt, stream: true),
        token: bearer,
      );
      expect(result.statusCode, 200,
          reason: 'the key authenticates and the profile marker resolves');
      expect(result.contentType, isNotNull);
      expect(result.contentType!.startsWith('text/event-stream'), isTrue);

      final List<String> frames = sseFrames(result.body);
      final StringBuffer content = StringBuffer();
      for (final String frame in frames) {
        final Map<String, Object?>? payload = sseFramePayload(frame);
        if (payload == null) continue;
        expect(payload['object'], 'chat.completion.chunk');
        final choice =
            (payload['choices'] as List<Object?>).first as Map<String, Object?>;
        final delta = choice['delta'] as Map<String, Object?>;
        if (delta['content'] is String) {
          content.write(delta['content'] as String);
        }
      }
      expect(frames.last, 'data: [DONE]');
      final String answer = content.toString();
      expect(answer.trim(), isNotEmpty,
          reason: 'live oMLX must stream a non-empty completion');
      return answer;
    }

    Future<String?> skipUnlessLive() async {
      final omlx = omlxEndpoint();
      final ollama = ollamaEndpoint();
      final omlxSkip = await omlx.unreachableReason();
      if (omlxSkip != null) return omlxSkip;
      final ollamaSkip = await ollama.unreachableReason();
      if (ollamaSkip != null) return ollamaSkip;
      return null;
    }

    test(
        'profile-research routes a cognitive request to prompt_analyzer_v1 and '
        'streams an answer', () async {
      final skip = await skipUnlessLive();
      if (skip != null) return markTestSkipped(skip);

      final live = await standUpLive(omlx: omlxEndpoint(), ollama: ollamaEndpoint());
      try {
        final answer = await streamAnswer(live.process,
            bearer: _researchBearer,
            prompt: 'In one short sentence, what is the capital of France?');
        expect(answer.trim(), isNotEmpty);
      } finally {
        await live.process.stop();
      }

      // The cognitive entry router ran: its per-procedure tree is on disk.
      expect(_procedureRan(live.trailRoot, 'prompt_analyzer_v1'), isTrue,
          reason: 'cognitive mode enters through prompt_analyzer_v1');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test(
        'profile-quick routes an answer-mode request straight to '
        'answer_with_memory_v1, bypassing the classifier', () async {
      final skip = await skipUnlessLive();
      if (skip != null) return markTestSkipped(skip);

      final live = await standUpLive(omlx: omlxEndpoint(), ollama: ollamaEndpoint());
      try {
        final answer = await streamAnswer(live.process,
            bearer: _quickBearer,
            prompt: 'In one short sentence, what is the capital of Italy?');
        expect(answer.trim(), isNotEmpty);
      } finally {
        await live.process.stop();
      }

      expect(_procedureRan(live.trailRoot, 'answer_with_memory_v1'), isTrue,
          reason: 'answer mode runs answer_with_memory_v1 directly');
      expect(_procedureRan(live.trailRoot, 'prompt_analyzer_v1'), isFalse,
          reason: 'answer mode bypasses the cognitive classifier (door 0)');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test(
        'profile-relay routes a passthrough request to passthrough_v1 and the '
        'wire prompt is un-anchored', () async {
      final skip = await skipUnlessLive();
      if (skip != null) return markTestSkipped(skip);

      final live = await standUpLive(omlx: omlxEndpoint(), ollama: ollamaEndpoint());
      try {
        final answer = await streamAnswer(live.process,
            bearer: _relayBearer,
            prompt: 'In one short sentence, what is the capital of Spain?');
        expect(answer.trim(), isNotEmpty);
      } finally {
        await live.process.stop();
      }

      // Only the relay procedure ran — no classifier, no answer-with-memory.
      expect(_procedureRan(live.trailRoot, 'passthrough_v1'), isTrue,
          reason: 'passthrough mode runs passthrough_v1');
      expect(_procedureRan(live.trailRoot, 'prompt_analyzer_v1'), isFalse,
          reason: 'passthrough makes no classifier call');
      expect(_procedureRan(live.trailRoot, 'answer_with_memory_v1'), isFalse,
          reason: 'passthrough touches no memory orchestration');

      // The single LLM call's raw trail records the un-anchored sentinel — proof
      // the dedication anchor was omitted for this `anchored: false` profile
      // (§ 3.4 / SCP-37). It is the literal `unanchored`, NOT a `sha256:` digest.
      final anchorHashes = _llmAnchorHashes(live.trailRoot);
      expect(anchorHashes, isNotEmpty,
          reason: 'the relay made exactly one LLM call, captured to the trail');
      expect(anchorHashes, everyElement('unanchored'),
          reason: 'an anchored: false passthrough records the un-anchored '
              'sentinel, never a sha256: anchor digest');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test(
        'a bare key (no profile- marker) falls back to the default cognitive '
        'profile and runs prompt_analyzer_v1', () async {
      final skip = await skipUnlessLive();
      if (skip != null) return markTestSkipped(skip);

      final live = await standUpLive(omlx: omlxEndpoint(), ollama: ollamaEndpoint());
      try {
        final answer = await streamAnswer(live.process,
            bearer: _bareBearer,
            prompt: 'In one short sentence, what is the capital of Germany?');
        expect(answer.trim(), isNotEmpty);
      } finally {
        await live.process.stop();
      }

      expect(_procedureRan(live.trailRoot, 'prompt_analyzer_v1'), isTrue,
          reason: 'the default profile is cognitive → prompt_analyzer_v1');
    }, timeout: const Timeout(Duration(minutes: 5)));
  }, skip: skipNoBinary);
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
