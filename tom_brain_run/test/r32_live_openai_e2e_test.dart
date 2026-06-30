// #32 — LIVE end-to-end, OpenAI channel.
//
// Plan-2 step #32 (verbatim, `prototype_implementation_plan_2.md`):
//
//   "LIVE end-to-end — OpenAI channel. Start the assembled process; send a real
//    POST /v1/chat/completions (stream + non-stream); assert the D4rt
//    `answer_with_memory_v1` runs, `recall` + `persist` hit the real on-disk
//    memory, and the answer is streamed from oMLX; then inspect the new Event +
//    Conclusion + interest stack via the MCP server. Verify: the full
//    prompt→script→memory→oMLX→answer→MCP-inspect chain passes against live oMLX
//    + Ollama."
//
// ── What this suite proves (and how it differs from #30 / #31) ───────
//
// #30 and #31 stand the *real* cognition up but never issue a chat completion —
// they only hit `/healthz` + `/v1/models`, so oMLX / Ollama are constructed but
// never dialed. #32 is the first suite that drives the **whole live chain**:
//
//   prompt → OpenAI edge → dispatcher → `answer_with_memory_v1` (D4rt) →
//   `recall`/`embed`/`classify`/`persist` against the **real on-disk
//   `SqliteTomBrainMemory`** → `llm(assistant_to_user)` **streamed from live
//   oMLX** → answer on the wire → memory inspected **through the MCP server**.
//
// The substrate is the *real* one `standUpBrainProcessFromConfig` manufactures
// from the parsed `substrate:` section (oMLX for chat, Ollama for embeddings) —
// no stub. So this suite only passes when both daemons are live; off-host it
// skips (per-test reachability probe), and on a platform with no packaged vec0
// the whole group skips (the on-disk store loads the extension at `open`).
//
// The shared scaffolding (endpoint resolution + reachability probe, the
// whole-process YAML, the vec0-binary skip gate, the standalone-platform
// install, the HTTP/SSE post helpers, and the in-process MCP inspection harness)
// lives in `support/live_e2e_harness.dart` (MSPP-60); this suite carries only
// its distinct assertions.
//
// ── Why memory is inspected after the process stops ──────────────────
//
// The run hosts `SqliteTomBrainMemory` inside a worker isolate (the production
// `createSqliteTomBrainMemory` factory), and the MCP server forwards each tool
// call to a `TomBrainMemory` it holds *directly* — it cannot reach a store
// behind a `SendPort` (the same constraint E.55 documents). But the store is
// **on disk**: once the process stops (which disposes the isolate and closes the
// database handles), a fresh in-host `SqliteTomBrainMemory` opened over the same
// directory reads back everything the run persisted. So each test runs the live
// exchange, stops the process, then re-opens the same on-disk root in-host and
// inspects it through a real `dart_mcp` client → `TomBrainMemoryMcpServer` pair.
// This is the brain's true external memory-inspection surface, exercised over
// the real persisted graph.
//
// ── Why recall is split into two queries (prompt + answer) ───────────
//
// The run persists an `Event` whose `summary` is the prompt and a `Conclusion`
// whose `statement` is the (live, non-deterministic) answer. The memory MCP
// `recall` is BM25 over the per-type FTS index, so the most reliable way to
// surface each node is to query by *its own* indexed text: `recall(prompt)`
// ranks the `Event` (summary), `recall(answer)` ranks the `Conclusion`
// (statement). The assertions then locate each node by its exact field value, so
// they survive whatever wording live oMLX returns.

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_brain_access/tom_brain_access.dart' show serveWithShelfIo;
import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show defaultMemoryProfile;

import 'support/live_e2e_harness.dart';

void main() {
  // The real providers source their wire HTTP client from the `tom_core_kernel`
  // factory via the active `TomPlatformUtils`; install the standalone platform
  // so the live HTTP path is exercised end-to-end (mirrors #30 / #31 / p2_12).
  setUpAll(installStandalonePlatformForLiveHttp);

  final String? vecRoot = findSqliteVecRoot();
  final String? skipNoBinary = sqliteVecSkipReason(vecRoot);

  group('#32 LIVE end-to-end — OpenAI channel', () {
    /// Stands a fresh live cognition up over a unique on-disk memory root.
    /// Returns the running process and the parsed config (its `memory` section
    /// is reused to re-open the same store for MCP inspection after teardown).
    Future<({BrainProcess process, BrainRunConfig config})> standUpLive({
      required LiveEndpoint omlx,
      required LiveEndpoint ollama,
    }) async {
      final Directory memoryRoot =
          Directory.systemTemp.createTempSync('tom_brain_run_32_mem_');
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
          accessBlock: bearerAccessBlock(defaultBearerToken),
        ),
      );
      final BrainProcess process = await standUpBrainProcessFromConfig(
        config,
        // Bind an OS-assigned ephemeral port; read the real one back.
        serve: (handler, _) => serveWithShelfIo(handler, 0),
      );
      return (process: process, config: config);
    }

    test(
        'non-stream: prompt → answer_with_memory_v1 → recall+persist on real '
        'on-disk memory, answer from live oMLX, inspected via MCP', () async {
      final omlx = omlxEndpoint();
      final ollama = ollamaEndpoint();
      final omlxSkip = await omlx.unreachableReason();
      if (omlxSkip != null) return markTestSkipped(omlxSkip);
      final ollamaSkip = await ollama.unreachableReason();
      if (ollamaSkip != null) return markTestSkipped(ollamaSkip);

      const String prompt = 'In one short sentence, what is the capital of '
          'France?';

      final live = await standUpLive(omlx: omlx, ollama: ollama);
      String answer;
      try {
        final result = await postJson(
          live.process.port,
          '/v1/chat/completions',
          chatBody(prompt, stream: false),
          token: defaultBearerToken,
        );
        expect(result.statusCode, 200);
        final body = result.body as Map<String, Object?>;
        expect(body['object'], 'chat.completion');
        final choices = body['choices'] as List<Object?>;
        final message = (choices.single as Map<String, Object?>)['message']
            as Map<String, Object?>;
        answer = message['content'] as String;
        // A real answer streamed from live oMLX, buffered into the body.
        expect(answer.trim(), isNotEmpty,
            reason: 'live oMLX must return a non-empty completion');
      } finally {
        // Stop first: dispose the memory isolate + close the DB handles so the
        // on-disk store can be re-opened in-host for MCP inspection.
        await live.process.stop();
      }

      // Re-open the same on-disk store in-host and inspect through the MCP
      // server — the brain's real external memory-inspection surface. The
      // default-profile run writes under `<root>/profiles/defaultmemory_default/`
      // (the provisioner opens the default client at
      // `memory.withProfile(defaultMemoryProfile)`, MSPP-26/§8.1), so the
      // inspection must bind that same profile, not the bare root.
      await inspectOnDisk(live.config.memory.withProfile(defaultMemoryProfile),
          (mcp) async {
        await _assertExchangePersisted(mcp, prompt: prompt, answer: answer);
      });
    }, timeout: const Timeout(Duration(minutes: 5)));

    test(
        'stream: SSE chunk ordering + [DONE] from live oMLX, and the streamed '
        'exchange is persisted to real on-disk memory', () async {
      final omlx = omlxEndpoint();
      final ollama = ollamaEndpoint();
      final omlxSkip = await omlx.unreachableReason();
      if (omlxSkip != null) return markTestSkipped(omlxSkip);
      final ollamaSkip = await ollama.unreachableReason();
      if (ollamaSkip != null) return markTestSkipped(ollamaSkip);

      const String prompt = 'In one short sentence, name a primary colour.';

      final live = await standUpLive(omlx: omlx, ollama: ollama);
      String streamedAnswer;
      try {
        final StreamPostResult result = await postForStream(
          live.process.port,
          '/v1/chat/completions',
          chatBody(prompt, stream: true),
          token: defaultBearerToken,
        );
        expect(result.statusCode, 200);
        // The OpenAI streaming media type — proof the edge took the SSE branch.
        expect(result.contentType, isNotNull);
        expect(result.contentType!.startsWith('text/event-stream'), isTrue);

        final List<String> frames = sseFrames(result.body);
        expect(frames.length, greaterThanOrEqualTo(2),
            reason: 'at least one content frame plus the terminal [DONE]');

        // Every non-terminal frame is a well-formed chat.completion.chunk that
        // repeats one stable id; their deltas concatenate to the answer.
        final StringBuffer content = StringBuffer();
        final Set<String> ids = <String>{};
        for (final String frame in frames) {
          final Map<String, Object?>? payload = sseFramePayload(frame);
          if (payload == null) continue;
          expect(payload['object'], 'chat.completion.chunk');
          ids.add(payload['id'] as String);
          final choice = (payload['choices'] as List<Object?>).first
              as Map<String, Object?>;
          final delta = choice['delta'] as Map<String, Object?>;
          if (delta['content'] is String) {
            content.write(delta['content'] as String);
          }
        }
        expect(ids, hasLength(1), reason: 'one completion, many chunks');
        streamedAnswer = content.toString();
        expect(streamedAnswer.trim(), isNotEmpty,
            reason: 'live oMLX must stream non-empty completion text');

        // The wire is terminated by exactly one final data: [DONE] line.
        expect(frames.last, 'data: [DONE]');
        expect(frames.where((String f) => f == 'data: [DONE]'), hasLength(1));
      } finally {
        await live.process.stop();
      }

      // The streamed exchange persisted to real memory just like the buffered
      // path: the same procedure runs regardless of the delivery mode. Bind the
      // default profile (see the non-stream test) so the inspection reads the
      // directory the default-profile run actually wrote to.
      await inspectOnDisk(live.config.memory.withProfile(defaultMemoryProfile),
          (mcp) async {
        await _assertExchangePersisted(
          mcp,
          prompt: prompt,
          answer: streamedAnswer,
        );
      });
    }, timeout: const Timeout(Duration(minutes: 5)));
  }, skip: skipNoBinary);
}

/// Asserts the run's exchange landed in real memory: a recalled `Event` whose
/// `summary` is [prompt], a recalled `Conclusion` whose `statement` is [answer],
/// and a cold-path `interests` stack entry resolving to an `InterestItem` whose
/// `topic` is [prompt] — all read through the MCP server.
Future<void> _assertExchangePersisted(
  McpInspector mcp, {
  required String prompt,
  required String answer,
}) async {
  // The Event is indexed by its `summary` (the prompt); recall by the prompt.
  final byPrompt = await mcp.recall(text: prompt, k: 50);
  final events = byPrompt
      .where((n) => n['typeName'] == 'Event')
      .where((n) => (n['values'] as Map)['summary'] == prompt)
      .toList(growable: false);
  expect(events, isNotEmpty,
      reason: 'the run persisted an Event whose summary is the prompt');

  // The Conclusion is indexed by its `statement` (the answer); recall by the
  // answer text so BM25 ranks it regardless of the live wording.
  final byAnswer = await mcp.recall(text: answer, k: 50);
  final conclusions = byAnswer
      .where((n) => n['typeName'] == 'Conclusion')
      .where((n) => (n['values'] as Map)['statement'] == answer)
      .toList(growable: false);
  expect(conclusions, isNotEmpty,
      reason: 'the run persisted a Conclusion whose statement is the answer');

  // The cold-classification path pushed an InterestItem onto `interests`.
  final stacks = await mcp.stackList();
  final interests =
      stacks.where((s) => s['name'] == 'interests').toList(growable: false);
  expect(interests, hasLength(1),
      reason: 'the cold path pushed the `interests` stack');
  expect((interests.single['size'] as int), greaterThanOrEqualTo(1));

  final entries = await mcp.stackPeek(name: 'interests', k: 16);
  expect(entries, isNotEmpty);
  final interestIds =
      entries.map((e) => e['nodeId'] as String).toList(growable: false);
  final fetched = await mcp.get(ids: interestIds);
  final topics = fetched
      .where((n) => n['typeName'] == 'InterestItem')
      .map((n) => (n['values'] as Map)['topic'])
      .toList(growable: false);
  expect(topics, contains(prompt),
      reason: 'an InterestItem carries the prompt as its topic');
}
