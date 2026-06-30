// r50 — LIVE end-to-end, memory-profile isolation (memory_session_profiles_plan
// step 14; `memory_session_profiles.md` § 15, MSP-1).
//
// r32 proves the *default*-profile live chain (prompt → D4rt → on-disk default
// store → streamed answer → MCP-inspect). This suite proves the **profiled**
// chain and the isolation invariant that is the whole point of memory profiles:
//
//   * an `access.apiKeys[]` credential is namespaced (`memoryPrefix: proj_`);
//   * a request whose Bearer carries a `memory-<sel>` marker around that key
//     (`memory-alpha_<key>`) resolves to memory profile `proj_alpha`
//     (`ApiKeyConfig.resolveScope`, proven at the edge in
//     `openai_marker_scope_edge_test.dart`);
//   * the run's Event + Conclusion land in **that profile's** database
//     (`<root>/profiles/proj_alpha/`), and are **absent** from the default
//     profile's database (`<root>/profiles/defaultmemory_default/`).
//
// That last leg is the MSP-1 isolation invariant exercised over the real
// persisted graph: two profiles are two separate SQLite databases, so a recall
// in the default profile physically cannot see the profiled run's nodes.
//
// Like r32 this is a LIVE suite: the substrate is the real one
// `standUpBrainProcessFromConfig` builds from `substrate:` (oMLX for chat,
// Ollama for embeddings). Off-host it skips per-test (TCP reachability probe);
// on a platform with no packaged vec0 the whole group skips (the on-disk store
// loads the extension at `open`). Memory is inspected only after the process
// stops — the run hosts the store in a worker isolate the MCP server can't reach
// behind a SendPort, but the databases are on disk, so a fresh in-host store
// re-opened at each profile-bound config reads back exactly what the run wrote
// (the same constraint r32 documents).
//
// The shared scaffolding (endpoint resolution + reachability probe, the
// whole-process YAML, the vec0-binary skip gate, the standalone-platform
// install, the HTTP/SSE post helpers, and the in-process MCP inspection harness)
// lives in `support/live_e2e_harness.dart` (MSPP-60); this suite carries only
// its namespaced-credential config and the present/absent isolation assertions.

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_brain_access/tom_brain_access.dart' show serveWithShelfIo;
import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show defaultMemoryProfile;

import 'support/live_e2e_harness.dart';

/// The namespaced API key the run binds. It is deliberately `_`-free (D-6) so
/// the §3.1 marker grammar — which splits the Bearer on `_` — never mistakes a
/// key segment for a `session-`/`memory-` selector. Its `memoryPrefix` is
/// `proj_`, so the `memory-alpha` marker resolves to profile `proj_alpha`.
const String _apiKey = 'projkey-secret';
const String _memoryPrefix = 'proj_';
const String _memorySelector = 'alpha';

/// The profile the marker-bearing request routes to: `<memoryPrefix><selector>`.
const String _profile = '$_memoryPrefix$_memorySelector';

/// The Bearer token a profiled request presents: the residual key wrapped in a
/// `memory-<sel>` marker. (No `session-` marker — the session selector defaults,
/// which is irrelevant to memory isolation.)
const String _profiledBearer = 'memory-${_memorySelector}_$_apiKey';

void main() {
  // The real providers source their wire HTTP client from `tom_core_kernel` via
  // the active `TomPlatformUtils`; the standalone platform makes the live HTTP
  // path work under `dart test` / testkit (mirrors r32).
  setUpAll(installStandalonePlatformForLiveHttp);

  final String? vecRoot = findSqliteVecRoot();
  final String? skipNoBinary = sqliteVecSkipReason(vecRoot);

  group('r50 LIVE end-to-end — memory-profile isolation', () {
    Future<({BrainProcess process, BrainRunConfig config})> standUpLive({
      required LiveEndpoint omlx,
      required LiveEndpoint ollama,
    }) async {
      final Directory memoryRoot =
          Directory.systemTemp.createTempSync('tom_brain_run_50_mem_');
      addTearDown(() {
        if (memoryRoot.existsSync()) memoryRoot.deleteSync(recursive: true);
      });

      final BrainRunConfig config = BrainRunConfigLoader.parse(
        liveRunYaml(
          omlx: omlx,
          ollama: ollama,
          memoryRoot: memoryRoot.path,
          binariesRoot: vecRoot!,
          cognitionRoot: cognitionConfigRoot(),
          // One namespaced credential (`memoryPrefix: proj_`) whose
          // marker-wrapped Bearer routes a request to the `proj_alpha` profile.
          accessBlock: apiKeyAccessBlock(
            key: _apiKey,
            principal: 'owner',
            sessionPrefix: _memoryPrefix,
            memoryPrefix: _memoryPrefix,
            displayName: 'Project bot',
          ),
        ),
      );
      final BrainProcess process = await standUpBrainProcessFromConfig(
        config,
        serve: (handler, _) => serveWithShelfIo(handler, 0),
      );
      return (process: process, config: config);
    }

    test(
        'a memory-marker request streams an answer into its profile and the '
        'default profile cannot see it (MSP-1)', () async {
      final omlx = omlxEndpoint();
      final ollama = ollamaEndpoint();
      final omlxSkip = await omlx.unreachableReason();
      if (omlxSkip != null) return markTestSkipped(omlxSkip);
      final ollamaSkip = await ollama.unreachableReason();
      if (ollamaSkip != null) return markTestSkipped(ollamaSkip);

      const String prompt =
          'In one short sentence, what is the capital of Japan?';

      final live = await standUpLive(omlx: omlx, ollama: ollama);
      String answer;
      try {
        final StreamPostResult result = await postForStream(
          live.process.port,
          '/v1/chat/completions',
          chatBody(prompt, stream: true),
          token: _profiledBearer,
        );
        expect(result.statusCode, 200,
            reason: 'the namespaced key authenticates and the marker resolves');
        expect(result.contentType, isNotNull);
        expect(result.contentType!.startsWith('text/event-stream'), isTrue);

        final List<String> frames = sseFrames(result.body);
        final StringBuffer content = StringBuffer();
        for (final String frame in frames) {
          final Map<String, Object?>? payload = sseFramePayload(frame);
          if (payload == null) continue;
          expect(payload['object'], 'chat.completion.chunk');
          final choice = (payload['choices'] as List<Object?>).first
              as Map<String, Object?>;
          final delta = choice['delta'] as Map<String, Object?>;
          if (delta['content'] is String) {
            content.write(delta['content'] as String);
          }
        }
        answer = content.toString();
        expect(answer.trim(), isNotEmpty,
            reason: 'live oMLX must stream a non-empty completion');
        expect(frames.last, 'data: [DONE]');
      } finally {
        // Stop first: dispose the memory isolate(s) + close the DB handles so
        // the on-disk profile stores can be re-opened in-host for inspection.
        await live.process.stop();
      }

      // The exchange landed in the routed profile's database.
      await inspectOnDisk(live.config.memory.withProfile(_profile),
          (mcp) async {
        await _assertExchangePresent(mcp, prompt: prompt, answer: answer);
      });

      // …and is invisible to the default profile's database (MSP-1 isolation).
      // Opening it materialises a fresh, empty store (no default-routed request
      // was ever made), so neither node can surface there.
      await inspectOnDisk(live.config.memory.withProfile(defaultMemoryProfile),
          (mcp) async {
        await _assertExchangeAbsent(mcp, prompt: prompt, answer: answer);
      });
    }, timeout: const Timeout(Duration(minutes: 5)));
  }, skip: skipNoBinary);
}

/// Asserts the run's exchange is present in the inspected profile: an `Event`
/// whose `summary` is [prompt] and a `Conclusion` whose `statement` is [answer],
/// each recalled by its own indexed text (mirrors r32's recall-split rationale).
Future<void> _assertExchangePresent(
  McpInspector mcp, {
  required String prompt,
  required String answer,
}) async {
  final byPrompt = await mcp.recall(text: prompt, k: 50);
  final events = byPrompt
      .where((n) => n['typeName'] == 'Event')
      .where((n) => (n['values'] as Map)['summary'] == prompt)
      .toList(growable: false);
  expect(events, isNotEmpty,
      reason: 'the profiled run persisted an Event whose summary is the prompt');

  final byAnswer = await mcp.recall(text: answer, k: 50);
  final conclusions = byAnswer
      .where((n) => n['typeName'] == 'Conclusion')
      .where((n) => (n['values'] as Map)['statement'] == answer)
      .toList(growable: false);
  expect(conclusions, isNotEmpty,
      reason: 'the profiled run persisted a Conclusion whose statement is the '
          'answer');
}

/// Asserts the run's exchange is NOT present in the inspected profile — the
/// isolation leg. Recall by both texts must surface no `Event`/`Conclusion`
/// carrying the profiled run's exact field values.
Future<void> _assertExchangeAbsent(
  McpInspector mcp, {
  required String prompt,
  required String answer,
}) async {
  final byPrompt = await mcp.recall(text: prompt, k: 50);
  final leakedEvents = byPrompt
      .where((n) => n['typeName'] == 'Event')
      .where((n) => (n['values'] as Map)['summary'] == prompt)
      .toList(growable: false);
  expect(leakedEvents, isEmpty,
      reason: 'the default profile must not see the profiled run\'s Event');

  final byAnswer = await mcp.recall(text: answer, k: 50);
  final leakedConclusions = byAnswer
      .where((n) => n['typeName'] == 'Conclusion')
      .where((n) => (n['values'] as Map)['statement'] == answer)
      .toList(growable: false);
  expect(leakedConclusions, isEmpty,
      reason:
          'the default profile must not see the profiled run\'s Conclusion');
}
