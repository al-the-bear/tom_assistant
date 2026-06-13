// The run-layer concrete implementations of the access package's Telegram
// inspection ports.
//
// What is proven:
//   1. TrailIncomingPromptInspector reads the §5.3 `incoming/` dumps back,
//      newest-first, with a collapsed preview, and resolves the same index to
//      the full detail; an out-of-range index returns null.
//   2. TrailLogInspector tails `brain.log`, `components/*.log`, and
//      `memory/*.log` (last N lines each), in that order, skipping rotated
//      `*.log.N` files.
//   3. MemoryStatsInspector renders a `MemoryStats` snapshot to a readable
//      overview (node/edge/stack counts, trail totals).
//   4. TrailStatusInspector stitches the live queue snapshot, the newest
//      recorded prompt, and the recent procedure-run outcomes/errors into one
//      report — labelling the prompt "currently processing" when the foreground
//      slot is busy, surfacing budget-overrun errors, and degrading to its
//      empty forms when no trail exists.

import 'dart:convert';
import 'dart:io';

import 'package:tom_brain_access/tom_brain_access.dart'
    show AccessChannel, IncomingTrailRecord, QueueSnapshot;
import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show LiveRun, LiveRunRegistry, SessionTodoStores;
import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        EffortMetrics,
        LatencyHistogram,
        MemoryStats,
        TomBrainMemoryClient,
        TurnId;
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show
        EmbeddingChoice,
        McpClientConfigBlock,
        ProviderAuthConfig,
        ProviderKind,
        ProviderProfile,
        RoleRouteEntryConfig,
        SubstrateConfig,
        WebFetchConfig,
        WebSearchConfig;
import 'package:test/test.dart';

/// A substrate config with two providers (a local Ollama and a paid
/// OpenAI-format vendor) plus an embedding choice pointing at the local row.
SubstrateConfig _substrateConfig({List<ProviderProfile>? providers}) =>
    SubstrateConfig(
      providers: providers ??
          [
            ProviderProfile(
              id: 'local',
              kind: ProviderKind.ollama,
              auth: ProviderAuthConfig.none,
              baseUrl: Uri.parse('http://127.0.0.1:11434'),
              models: const ['gemma3:27b', 'nomic-embed-text'],
            ),
            ProviderProfile(
              id: 'openrouter',
              kind: ProviderKind.openai,
              auth: ProviderAuthConfig.apiKey(secretRef: '_ai/secrets/or.key'),
              baseUrl: Uri.parse('https://openrouter.ai/api/v1'),
              models: const ['meta-llama/llama-3-70b'],
            ),
          ],
      roleRoutes: const {},
      embedding: const EmbeddingChoice(
        providerId: 'local',
        model: 'nomic-embed-text',
        dims: 768,
        normalize: true,
      ),
      webSearch: const WebSearchConfig(defaultProvider: 'ddg', providers: {}),
      webFetch: const WebFetchConfig(),
      mcpClient: const McpClientConfigBlock(),
    );

/// A cognition config carrying one registered prompt that routes over the
/// `fast` LLM route (a two-entry chain referencing the substrate fixture's
/// providers).
CognitionConfig _cognitionConfig({
  Map<String, ResolvedPrompt>? prompts,
  Map<String, LlmRouteConfig>? llmRoutes,
}) =>
    CognitionConfig(
      registry: const CognitionRegistry(
        procedures: {},
        rolesFolder: 'roles',
        llmFolder: 'llm',
        llmDefault: 'default',
      ),
      prompts: prompts ??
          const {
            'assist_user.answer.main': ResolvedPrompt(
              id: 'assist_user.answer.main',
              mainProcedure: 'assist_user',
              subProcedure: 'answer',
              promptName: 'main',
              templatePath: 'assist_user/answer.md',
              kind: PromptKind.prompt,
              settings: PromptSettings(
                llm: 'fast',
                role: 'assistant_to_user',
                tools: ToolsReadonly(),
              ),
            ),
          },
      llmRoutes: llmRoutes ??
          const {
            'fast': LlmRouteConfig(name: 'fast', route: [
              RoleRouteEntryConfig(providerId: 'local', model: 'gemma3:27b'),
              RoleRouteEntryConfig(
                  providerId: 'openrouter', model: 'meta-llama/llama-3-70b'),
            ]),
          },
    );

IncomingTrailRecord _record({
  required String turnId,
  required DateTime receivedAt,
  String text = 'hello',
  AccessChannel channel = AccessChannel.telegram,
}) =>
    IncomingTrailRecord(
      turnId: TurnId.fromString(turnId),
      channel: channel,
      receivedAt: receivedAt,
      principalId: 'owner',
      sessionId: 'sess-1',
      conversationId: 'conv-1',
      profile: 'default',
      persona: 'tom-assistant',
      text: text,
      rawEnvelope: const {'locale': 'en'},
    );

/// Writes one `llm/<callType>/<turnId>__<callSeq>.raw.json` dump matching the
/// §5.2 schema `LlmTrailWriter` emits, so the prompt inspector's run summary can
/// join it back by turnId. Only the fields the summary reads are populated.
void _writeLlmRaw(
  Directory root,
  String turnId, {
  required int callSeq,
  required String callType,
  required int tokensIn,
  required int tokensOut,
  required int wallClockMs,
  required String answer,
}) {
  final dir = Directory('${root.path}/llm/$callType')
    ..createSync(recursive: true);
  final stem = '${turnId}__${callSeq.toString().padLeft(2, '0')}';
  File('${dir.path}/$stem.raw.json').writeAsStringSync(jsonEncode(<String, Object?>{
    'turnId': turnId,
    'callSeq': callSeq,
    'callType': callType,
    'tokensIn': tokensIn,
    'tokensOut': tokensOut,
    'wallClockMs': wallClockMs,
    'answer': answer,
  }));
}

/// Writes one `procedures/<procedureId>/<turnId>__<runId>.log` file whose body
/// ends in [outcome], mirroring `ProcedureTreeWriter`'s rendered shape closely
/// enough for the per-procedure breakdown's outcome read.
void _writeProcedureLog(
  Directory root,
  String procedureId,
  String turnId,
  String runId, {
  required String outcome,
}) {
  final dir = Directory('${root.path}/procedures/$procedureId')
    ..createSync(recursive: true);
  File('${dir.path}/${turnId}__$runId.log').writeAsStringSync(
    'procedure $procedureId  run $runId  turn $turnId\n'
    '└─ $outcome\n',
  );
}

QueueSnapshot _queue({
  bool foregroundRunning = false,
  int foregroundWaiting = 0,
  int foregroundQueueDepth = 4,
  bool backgroundRunning = false,
  bool draining = false,
}) =>
    QueueSnapshot(
      foregroundRunning: foregroundRunning,
      foregroundWaiting: foregroundWaiting,
      foregroundQueueDepth: foregroundQueueDepth,
      backgroundRunning: backgroundRunning,
      draining: draining,
    );

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tbr_tg_inspector_');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('TrailIncomingPromptInspector', () {
    test('lists recorded prompts newest-first with a collapsed preview',
        () async {
      final writer = IncomingTrailWriter(root: root);
      writer.write(_record(
        turnId: '260608-120000.000001',
        receivedAt: DateTime.utc(2026, 6, 8, 11),
        text: 'the older prompt',
      ));
      writer.write(_record(
        turnId: '260608-120000.000002',
        receivedAt: DateTime.utc(2026, 6, 8, 12),
        text: 'the   newer\n\nprompt',
      ));

      final inspector = TrailIncomingPromptInspector(trailRoot: root);
      final digests = await inspector.recentPrompts(limit: 10, previewLength: 200);

      expect(digests, hasLength(2));
      expect(digests[0].index, 0);
      expect(digests[0].receivedAt, DateTime.utc(2026, 6, 8, 12));
      // Whitespace runs are collapsed to single spaces.
      expect(digests[0].preview, 'the newer prompt');
      expect(digests[1].index, 1);
      expect(digests[1].preview, 'the older prompt');
    });

    test('honours the limit and truncates the preview to previewLength',
        () async {
      final writer = IncomingTrailWriter(root: root);
      for (var i = 1; i <= 3; i++) {
        writer.write(_record(
          turnId: '260608-120000.00000$i',
          receivedAt: DateTime.utc(2026, 6, 8, 10 + i),
          text: 'x' * 50,
        ));
      }

      final inspector = TrailIncomingPromptInspector(trailRoot: root);
      final digests = await inspector.recentPrompts(limit: 2, previewLength: 10);

      expect(digests, hasLength(2));
      expect(digests.first.preview, '${'x' * 10}…');
    });

    test('promptDetail resolves the same index and includes the full text',
        () async {
      IncomingTrailWriter(root: root).write(_record(
        turnId: '260608-120000.000009',
        receivedAt: DateTime.utc(2026, 6, 8, 12),
        text: 'the full detail body',
      ));

      final inspector = TrailIncomingPromptInspector(trailRoot: root);
      final detail = await inspector.promptDetail(0);

      expect(detail, isNotNull);
      expect(detail, contains('Prompt [0]'));
      expect(detail, contains('turnId: 260608-120000.000009'));
      expect(detail, contains('channel: telegram'));
      expect(detail, contains('the full detail body'));
    });

    test('promptDetail returns null for an out-of-range index', () async {
      IncomingTrailWriter(root: root).write(_record(
        turnId: '260608-120000.000001',
        receivedAt: DateTime.utc(2026, 6, 8, 12),
      ));
      final inspector = TrailIncomingPromptInspector(trailRoot: root);
      expect(await inspector.promptDetail(5), isNull);
      expect(await inspector.promptDetail(-1), isNull);
    });

    test('returns an empty list when no incoming trail exists', () async {
      final inspector = TrailIncomingPromptInspector(trailRoot: root);
      expect(await inspector.recentPrompts(limit: 10, previewLength: 50),
          isEmpty);
    });
  });

  group('TrailIncomingPromptInspector — run summary (§ 9.4 Todo 10)', () {
    test('joins the run\'s LLM calls and procedure runs by turnId', () async {
      const turnId = '260608-120000.000042';
      IncomingTrailWriter(root: root).write(_record(
        turnId: turnId,
        receivedAt: DateTime.utc(2026, 6, 8, 12),
        text: 'analyse this',
      ));
      // Three LLM calls for the turn: a recaller answer, a tool-deciding
      // assistant turn (functional dialect → resolves to a tool call), and the
      // terminal plain answer.
      _writeLlmRaw(root, turnId,
          callSeq: 1,
          callType: 'recaller',
          tokensIn: 612,
          tokensOut: 48,
          wallClockMs: 400,
          answer: 'recalled context summary');
      _writeLlmRaw(root, turnId,
          callSeq: 2,
          callType: 'assistant_to_user',
          tokensIn: 1038,
          tokensOut: 24,
          wallClockMs: 700,
          answer: 'call:web.search{query: "today\'s news"}');
      _writeLlmRaw(root, turnId,
          callSeq: 3,
          callType: 'assistant_to_user',
          tokensIn: 174,
          tokensOut: 30,
          wallClockMs: 500,
          answer: 'Here is the answer.');
      // A procedure run log for the same turn (its outcome line drives the
      // per-procedure breakdown).
      _writeProcedureLog(root, 'answer_with_memory_v1', turnId, 'run_07',
          outcome: 'outcome accepted (entries=12, 1.6s)');

      final detail = await TrailIncomingPromptInspector(trailRoot: root)
          .promptDetail(0);

      expect(detail, isNotNull);
      // The prompt block is still present.
      expect(detail, contains('Prompt [0]'));
      expect(detail, contains('analyse this'));
      // The run summary, joined by turnId.
      expect(detail, contains('Run summary (turn $turnId):'));
      expect(detail,
          contains('LLM calls: 3 (1 tool-deciding, 2 answer-producing)'));
      expect(detail, contains('Tool invocations: 1'));
      expect(detail, contains('Tokens: 1824 in / 102 out'));
      expect(detail, contains('Wall-clock: 1.6s'));
      // Per-role breakdown (sorted by role).
      expect(detail, contains('assistant_to_user: 2 calls, 1212→54 tok'));
      expect(detail, contains('recaller: 1 call, 612→48 tok'));
      // Per-procedure breakdown.
      expect(detail, contains('answer_with_memory_v1: accepted'));
    });

    test('counts multiple tool calls in one answer as multiple invocations',
        () async {
      const turnId = '260608-120000.000043';
      IncomingTrailWriter(root: root).write(_record(
        turnId: turnId,
        receivedAt: DateTime.utc(2026, 6, 8, 12),
      ));
      _writeLlmRaw(root, turnId,
          callSeq: 1,
          callType: 'assistant_to_user',
          tokensIn: 100,
          tokensOut: 10,
          wallClockMs: 200,
          answer:
              'call:a{} and call:b{x: 1}'); // two functional calls in one turn

      final detail = await TrailIncomingPromptInspector(trailRoot: root)
          .promptDetail(0);

      expect(detail,
          contains('LLM calls: 1 (1 tool-deciding, 0 answer-producing)'));
      expect(detail, contains('Tool invocations: 2'));
    });

    test('omits the run summary entirely when the turn has no run activity',
        () async {
      IncomingTrailWriter(root: root).write(_record(
        turnId: '260608-120000.000044',
        receivedAt: DateTime.utc(2026, 6, 8, 12),
        text: 'a prompt that never ran',
      ));

      final detail = await TrailIncomingPromptInspector(trailRoot: root)
          .promptDetail(0);

      expect(detail, isNotNull);
      expect(detail, contains('a prompt that never ran'));
      expect(detail, isNot(contains('Run summary')));
    });
  });

  group('TrailLogInspector', () {
    test('tails brain.log + components + memory in order, skipping rotated logs',
        () async {
      File('${root.path}/brain.log')
          .writeAsStringSync('b1\nb2\nb3\nb4\nb5\n');
      Directory('${root.path}/components').createSync(recursive: true);
      File('${root.path}/components/sub.log').writeAsStringSync('c1\nc2\n');
      // A rotated file must be skipped.
      File('${root.path}/components/sub.log.1').writeAsStringSync('old\n');
      Directory('${root.path}/memory').createSync(recursive: true);
      File('${root.path}/memory/store.log').writeAsStringSync('m1\nm2\n');

      final inspector = TrailLogInspector(trailRoot: root);
      final tails = await inspector.tailLogs(lines: 3);

      expect(tails.map((t) => t.name).toList(),
          ['brain.log', 'components/sub.log', 'memory/store.log']);
      // brain.log tail is the last 3 of 5 lines.
      expect(tails[0].content, 'b3\nb4\nb5');
      expect(tails[1].content, 'c1\nc2');
      expect(tails[2].content, 'm1\nm2');
    });

    test('returns an empty list when there are no log files', () async {
      final inspector = TrailLogInspector(trailRoot: root);
      expect(await inspector.tailLogs(lines: 50), isEmpty);
    });
  });

  group('MemoryStatsInspector', () {
    test('renders node/edge/stack counts and trail totals', () async {
      final inspector = MemoryStatsInspector(
        client: _StatsMemoryClient(const MemoryStats(
          nodeCountByType: {'Event': 3, 'Claim': 1},
          edgeCountByType: {'mentions': 2},
          stackSizes: {'questions_open': 4},
          trailCount: 7,
          trailBytes: 2048,
          recallLatencyPerMode: {
            'vector': LatencyHistogram(p50Ms: 1.5, p95Ms: 9.0),
          },
          classificationConfidenceHistogram: {},
          migrationProgress: {'restructure_x': 0.42},
        )),
      );

      final status = await inspector.status();

      expect(status, contains('Memory status'));
      expect(status, contains('Nodes (total 4):'));
      expect(status, contains('Event: 3'));
      expect(status, contains('Edges (total 2):'));
      expect(status, contains('mentions: 2'));
      expect(status, contains('questions_open: 4'));
      expect(status, contains('Trails: 7 files, 2048 bytes'));
      expect(status, contains('vector: 1.5 / 9.0'));
      expect(status, contains('restructure_x: 42%'));
    });

    test('shows (none) for empty sections', () async {
      final inspector =
          MemoryStatsInspector(client: _StatsMemoryClient(MemoryStats.empty));
      final status = await inspector.status();
      expect(status, contains('Nodes (total 0):'));
      expect(status, contains('(none)'));
    });
  });

  group('TrailStatusInspector', () {
    test('reports an active foreground prompt as currently processing',
        () async {
      IncomingTrailWriter(root: root).write(_record(
        turnId: '260608-120000.000001',
        receivedAt: DateTime.utc(2026, 6, 8, 12),
        text: 'what is the weather',
      ));

      final inspector = TrailStatusInspector(
        queueSnapshot: () => _queue(
          foregroundRunning: true,
          foregroundWaiting: 2,
        ),
        trailRoot: root,
      );
      final report = await inspector.report();

      expect(report, contains('Brain status'));
      expect(report, contains('active — a prompt is being processed'));
      expect(report, contains('Foreground: running (waiting 2, queue depth 4)'));
      expect(report, contains('Background: idle'));
      expect(report, contains('Latest prompt (currently processing):'));
      expect(report, contains('what is the weather'));
    });

    test('labels the latest prompt "last received" when the foreground is idle',
        () async {
      IncomingTrailWriter(root: root).write(_record(
        turnId: '260608-120000.000002',
        receivedAt: DateTime.utc(2026, 6, 8, 12),
        text: 'an earlier question',
      ));

      final inspector = TrailStatusInspector(
        queueSnapshot: () => _queue(backgroundRunning: true),
        trailRoot: root,
      );
      final report = await inspector.report();

      expect(report, contains('idle (background work running)'));
      expect(report, contains('Latest prompt (last received):'));
    });

    test('surfaces a procedure run outcome and its budget-overrun error',
        () async {
      final runDir = Directory('${root.path}/procedures/answer_with_memory_v1')
        ..createSync(recursive: true);
      File('${runDir.path}/turn_01__run_07.log').writeAsStringSync(
        'run answer_with_memory_v1\n'
        '├─ llm answerer\n'
        '└─ error procedure.budget.exceeded: token budget of 2000 exhausted\n'
        '└─ outcome failed (entries=2, 3.4s)\n',
      );

      final inspector = TrailStatusInspector(
        queueSnapshot: _queue,
        trailRoot: root,
      );
      final report = await inspector.report();

      expect(report, contains('Recent runs:'));
      expect(
          report,
          contains(
              'answer_with_memory_v1/turn_01__run_07: outcome failed (entries=2, 3.4s)'));
      expect(report, contains('Errors:'));
      expect(
          report,
          contains('answer_with_memory_v1/turn_01__run_07: '
              'error procedure.budget.exceeded: token budget of 2000 exhausted'));
    });

    test('a run with no outcome line shows "(in progress)" and no error',
        () async {
      final runDir = Directory('${root.path}/procedures/research_v1')
        ..createSync(recursive: true);
      File('${runDir.path}/turn_02__run_09.log')
          .writeAsStringSync('run research_v1\n├─ llm planner\n');

      final inspector = TrailStatusInspector(
        queueSnapshot: () => _queue(foregroundRunning: true),
        trailRoot: root,
      );
      final report = await inspector.report();

      expect(report, contains('research_v1/turn_02__run_09: (in progress)'));
      expect(report, contains('Errors:\n  (none)'));
    });

    test('degrades to empty forms when no trail exists', () async {
      final inspector = TrailStatusInspector(
        queueSnapshot: _queue,
        trailRoot: root,
      );
      final report = await inspector.report();

      expect(report, contains('idle (nothing being processed)'));
      expect(report, contains('Latest prompt (none recorded yet):'));
      expect(report, contains('(no prompts recorded yet)'));
      expect(report, contains('(no runs recorded yet)'));
      expect(report, contains('Errors:\n  (none)'));
    });

    test('reports the draining state during shutdown', () async {
      final inspector = TrailStatusInspector(
        queueSnapshot: () => _queue(draining: true),
        trailRoot: root,
      );
      final report = await inspector.report();
      expect(report, contains('draining (shutting down)'));
    });
  });

  group('SessionTodosInspector', () {
    test('lists a session\'s working todos with done boxes and ids', () async {
      final stores = SessionTodoStores();
      final store = stores.forSession('sess-1');
      final id1 = store.add('write the test');
      store.add('make it pass');
      store.update(id1, done: true);

      final inspector = SessionTodosInspector(stores: stores);
      final text = await inspector.list('sess-1');

      expect(text, contains('Working todo list (2):'));
      expect(text, contains('[x] $id1  write the test'));
      expect(text, contains('[ ] t2  make it pass'));
    });

    test('reports the empty case without creating a store', () async {
      final stores = SessionTodoStores();
      final inspector = SessionTodosInspector(stores: stores);

      expect(await inspector.list('never-seen'), 'The working todo list is empty.');
      // The peek must not have minted a store for the unseen session.
      expect(stores.peek('never-seen'), isNull);
    });

    test('clear empties the list and reports the count', () async {
      final stores = SessionTodoStores();
      final store = stores.forSession('sess-2');
      store.add('one');
      store.add('two');

      final inspector = SessionTodosInspector(stores: stores);
      final result = await inspector.clear('sess-2');

      expect(result, 'Cleared 2 entries from the working todo list.');
      expect(stores.peek('sess-2')!.list(), isEmpty);
    });

    test('clear of a single entry uses the singular noun', () async {
      final stores = SessionTodoStores();
      stores.forSession('sess-3').add('only one');

      final inspector = SessionTodosInspector(stores: stores);
      expect(await inspector.clear('sess-3'),
          'Cleared 1 entry from the working todo list.');
    });

    test('clear of an empty/unseen session reports it was already empty',
        () async {
      final stores = SessionTodoStores();
      final inspector = SessionTodosInspector(stores: stores);
      expect(await inspector.clear('unseen'),
          'The working todo list was already empty.');
    });
  });

  group('LiveUsageInspector', () {
    test('reports nothing in flight when the registry is empty', () async {
      final registry = LiveRunRegistry();
      final inspector = LiveUsageInspector(registry: registry);
      expect(await inspector.currentUsage(),
          'No prompt is being processed right now.');
    });

    test('renders the live budget of the foreground prompt', () async {
      final registry = LiveRunRegistry();
      registry.open(LiveRun(
        runId: 'top',
        procedureId: 'answer_with_thinking_v1',
        parentRunId: null,
        turnId: 'turn-1',
        startedAt: DateTime(2026, 6, 11, 10),
        readEffort: () => EffortMetrics(
          llmCalls: 3,
          inputTokens: 150,
          outputTokens: 25,
          toolCalls: 2,
          memoryReads: 4,
          memoryWrites: 1,
        ),
      ));
      // A clock pinned 1h 1m 5s after the run started.
      final inspector = LiveUsageInspector(
        registry: registry,
        now: () => DateTime(2026, 6, 11, 11, 1, 5),
      );

      final text = await inspector.currentUsage();
      expect(text, contains('procedure: answer_with_thinking_v1'));
      expect(text, contains('elapsed: 1h 1m 5s'));
      expect(text, contains('open runs: 1'));
      expect(text, contains('LLM calls: 3'));
      expect(text, contains('tool calls: 2'));
      expect(text, contains('estimated tokens: 175 (in 150 / out 25)'));
      expect(text, contains('memory reads: 4'));
      expect(text, contains('memory writes: 1'));
    });

    test('a just-started prompt renders seconds only', () async {
      final registry = LiveRunRegistry();
      registry.open(LiveRun(
        runId: 'top',
        procedureId: 'answer_with_memory_v1',
        parentRunId: null,
        turnId: 'turn-1',
        startedAt: DateTime(2026, 6, 11, 10),
        readEffort: () => EffortMetrics.zero,
      ));
      final inspector = LiveUsageInspector(
        registry: registry,
        now: () => DateTime(2026, 6, 11, 10, 0, 3),
      );
      expect(await inspector.currentUsage(), contains('elapsed: 3s'));
    });
  });

  group('LiveStopController', () {
    test('reports nothing to stop when the registry is empty', () async {
      final registry = LiveRunRegistry();
      final controller = LiveStopController(registry: registry);
      expect(await controller.stopCurrentPrompt(),
          'No prompt is being processed right now.');
    });

    test('cancels the foreground prompt and confirms the stop', () async {
      final registry = LiveRunRegistry();
      var cancelled = false;
      registry.open(LiveRun(
        runId: 'top',
        procedureId: 'answer_with_thinking_v1',
        parentRunId: null,
        turnId: 'turn-1',
        startedAt: DateTime(2026, 6, 11, 10),
        readEffort: () => EffortMetrics.zero,
        cancel: () => cancelled = true,
      ));
      final controller = LiveStopController(registry: registry);

      final text = await controller.stopCurrentPrompt();
      expect(cancelled, isTrue);
      expect(text, contains('Stopping the prompt being processed'));
    });

    test('ignores a turn-less background run (nothing to stop)', () async {
      final registry = LiveRunRegistry();
      var cancelled = false;
      registry.open(LiveRun(
        runId: 'bg',
        procedureId: 'dream_v1',
        parentRunId: null,
        turnId: null,
        startedAt: DateTime(2026, 6, 11, 10),
        readEffort: () => EffortMetrics.zero,
        cancel: () => cancelled = true,
      ));
      final controller = LiveStopController(registry: registry);

      expect(await controller.stopCurrentPrompt(),
          'No prompt is being processed right now.');
      expect(cancelled, isFalse);
    });
  });

  group('SubstrateModelsInspector', () {
    test('renders providers and models with provider:model ids', () async {
      final inspector = SubstrateModelsInspector(config: _substrateConfig());
      final text = await inspector.models();

      expect(text, contains('Models & providers (2 providers):'));
      expect(
        text,
        contains('Provider local (kind: ollama, '
            'url: http://127.0.0.1:11434, auth: none)'),
      );
      expect(text, contains('local:gemma3:27b'));
      expect(
        text,
        contains('Provider openrouter (kind: openai, '
            'url: https://openrouter.ai/api/v1, auth: api_key)'),
      );
      expect(text, contains('openrouter:meta-llama/llama-3-70b'));
    });

    test('flags the model backing the embedding service', () async {
      final inspector = SubstrateModelsInspector(config: _substrateConfig());
      final text = await inspector.models();
      expect(text, contains('local:nomic-embed-text  [embedding]'));
      // Only the embedding model is flagged, not the chat model.
      expect(text, isNot(contains('local:gemma3:27b  [embedding]')));
    });

    test('never prints the API key, only that auth is api_key', () async {
      final inspector = SubstrateModelsInspector(config: _substrateConfig());
      final text = await inspector.models();
      expect(text, isNot(contains('_ai/secrets/or.key')));
    });

    test('shows (no models declared) for a provider without models', () async {
      final inspector = SubstrateModelsInspector(
        config: _substrateConfig(providers: [
          ProviderProfile(
            id: 'empty',
            kind: ProviderKind.stub,
            auth: ProviderAuthConfig.none,
            models: const [],
          ),
        ]),
      );
      final text = await inspector.models();
      expect(text, contains('Provider empty (kind: stub, auth: none)'));
      expect(text, contains('(no models declared)'));
    });

    test('reports no providers when the config is empty', () async {
      final inspector =
          SubstrateModelsInspector(config: _substrateConfig(providers: []));
      expect(await inspector.models(), 'No providers are configured.');
    });
  });

  group('CognitionPromptsInspector', () {
    test('renders prompt ids with route, role, tools, kind, and chain',
        () async {
      final inspector = CognitionPromptsInspector(config: _cognitionConfig());
      final text = await inspector.prompts();

      expect(text, contains('Prompt types (1 prompt):'));
      expect(text, contains('assist_user.answer.main'));
      expect(
        text,
        contains('llm: fast  role: assistant_to_user  '
            'tools: readonly  kind: prompt'),
      );
      // The resolved route chain is shown with the same provider:model ids
      // /show_models prints.
      expect(text, contains('local:gemma3:27b'));
      expect(text, contains('openrouter:meta-llama/llama-3-70b'));
    });

    test('renders an explicit tool list and (default) when tools are unset',
        () async {
      final inspector = CognitionPromptsInspector(
        config: _cognitionConfig(prompts: const {
          'p.explicit.main': ResolvedPrompt(
            id: 'p.explicit.main',
            mainProcedure: 'p',
            subProcedure: 'explicit',
            promptName: 'main',
            templatePath: 'p/explicit.md',
            kind: PromptKind.fragment,
            settings: PromptSettings(
              llm: 'fast',
              tools: ToolsExplicit(['mem.recall', 'sub.send']),
            ),
          ),
          'p.bare.main': ResolvedPrompt(
            id: 'p.bare.main',
            mainProcedure: 'p',
            subProcedure: 'bare',
            promptName: 'main',
            templatePath: 'p/bare.md',
            kind: PromptKind.prompt,
            settings: PromptSettings(),
          ),
        }),
      );
      final text = await inspector.prompts();

      expect(text, contains('tools: [mem.recall, sub.send]'));
      expect(text, contains('kind: fragment'));
      // The bare prompt: no tools set anywhere, no llm route.
      expect(text, contains('tools: (default)'));
      expect(text, contains('llm: (unset)'));
    });

    test('reports no prompt types when none are registered', () async {
      final inspector =
          CognitionPromptsInspector(config: _cognitionConfig(prompts: const {}));
      expect(await inspector.prompts(), 'No prompt types are registered.');
    });

    test('shows an active model override beside the prompt it targets', () async {
      final overrides = ModelOverrideRegistry()
        ..set('assist_user.answer.main',
            providerId: 'openrouter', model: 'meta-llama/llama-3-70b');
      final inspector = CognitionPromptsInspector(
        config: _cognitionConfig(),
        overrides: overrides,
      );
      final text = await inspector.prompts();

      // The committed route chain still renders…
      expect(text, contains('local:gemma3:27b'));
      // …and the active override is called out explicitly.
      expect(text,
          contains('override → openrouter:meta-llama/llama-3-70b'));
    });

    test('shows no override line when the registry has none for a prompt',
        () async {
      final inspector = CognitionPromptsInspector(
        config: _cognitionConfig(),
        overrides: ModelOverrideRegistry(),
      );
      expect(await inspector.prompts(), isNot(contains('override →')));
    });
  });

  group('ModelOverrideRegistry', () {
    test('records, reads back, and reports its overrides', () {
      final registry = ModelOverrideRegistry();
      expect(registry.isEmpty, isTrue);
      expect(registry.overrideFor('p.x.main'), isNull);

      registry.set('p.x.main', providerId: 'local', model: 'gemma3:27b');
      expect(registry.isEmpty, isFalse);
      final ov = registry.overrideFor('p.x.main')!;
      expect(ov.providerId, 'local');
      expect(ov.model, 'gemma3:27b');

      // A second set on the same id replaces it.
      registry.set('p.x.main', providerId: 'openrouter', model: 'm');
      expect(registry.overrideFor('p.x.main')!.providerId, 'openrouter');
    });
  });

  group('TomBrainModelSwitcher (/switch_model)', () {
    TomBrainModelSwitcher switcher(ModelOverrideRegistry registry) =>
        TomBrainModelSwitcher(
          cognition: _cognitionConfig(),
          substrate: _substrateConfig(),
          overrides: registry,
        );

    test('a valid switch mutates the registry and confirms', () async {
      final registry = ModelOverrideRegistry();
      final text = await switcher(registry).switchModel(
        promptId: 'assist_user.answer.main',
        modelId: 'openrouter:meta-llama/llama-3-70b',
      );

      final ov = registry.overrideFor('assist_user.answer.main')!;
      expect(ov.providerId, 'openrouter');
      expect(ov.model, 'meta-llama/llama-3-70b');
      expect(text, contains('assist_user.answer.main'));
      expect(text, contains('openrouter:meta-llama/llama-3-70b'));
    });

    test('a model id is split on the FIRST colon (model names hold colons)',
        () async {
      final registry = ModelOverrideRegistry();
      await switcher(registry).switchModel(
        promptId: 'assist_user.answer.main',
        modelId: 'local:gemma3:27b',
      );
      final ov = registry.overrideFor('assist_user.answer.main')!;
      expect(ov.providerId, 'local');
      expect(ov.model, 'gemma3:27b');
    });

    test('an unknown prompt id is reported and changes nothing', () async {
      final registry = ModelOverrideRegistry();
      final text = await switcher(registry).switchModel(
        promptId: 'no.such.prompt',
        modelId: 'local:gemma3:27b',
      );
      expect(text, contains('No prompt type named "no.such.prompt"'));
      expect(registry.isEmpty, isTrue);
    });

    test('a model id without a colon is reported and changes nothing',
        () async {
      final registry = ModelOverrideRegistry();
      final text = await switcher(registry).switchModel(
        promptId: 'assist_user.answer.main',
        modelId: 'gemma3',
      );
      expect(text, contains('<providerId>:<model>'));
      expect(registry.isEmpty, isTrue);
    });

    test('an unknown provider is reported and changes nothing', () async {
      final registry = ModelOverrideRegistry();
      final text = await switcher(registry).switchModel(
        promptId: 'assist_user.answer.main',
        modelId: 'ghost:gemma3:27b',
      );
      expect(text, contains('No provider named "ghost"'));
      expect(registry.isEmpty, isTrue);
    });

    test('a model the provider does not advertise is reported and changes '
        'nothing', () async {
      final registry = ModelOverrideRegistry();
      final text = await switcher(registry).switchModel(
        promptId: 'assist_user.answer.main',
        modelId: 'local:not-a-model',
      );
      expect(text, contains('does not advertise a model named "not-a-model"'));
      expect(registry.isEmpty, isTrue);
    });

    group('with a persistence store (request e)', () {
      late Directory dir;
      late ModelOverrideStore store;

      setUp(() {
        dir = Directory.systemTemp.createTempSync('switch_model_persist_');
        store = ModelOverrideStore(filePath: '${dir.path}/model_overrides.yaml');
      });

      tearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });

      TomBrainModelSwitcher persistingSwitcher(ModelOverrideRegistry registry) =>
          TomBrainModelSwitcher(
            cognition: _cognitionConfig(),
            substrate: _substrateConfig(),
            overrides: registry,
            store: store,
          );

      test('a valid switch persists the override and confirms it survives a '
          'restart', () async {
        final registry = ModelOverrideRegistry();
        final text = await persistingSwitcher(registry).switchModel(
          promptId: 'assist_user.answer.main',
          modelId: 'local:gemma3:27b',
        );

        expect(text, contains('persisted'));
        // The override is on disk, reloadable into a fresh registry.
        final reloaded = store.load();
        expect(reloaded['assist_user.answer.main']!.providerId, 'local');
        expect(reloaded['assist_user.answer.main']!.model, 'gemma3:27b');
      });

      test('an invalid switch writes nothing to disk', () async {
        final registry = ModelOverrideRegistry();
        await persistingSwitcher(registry).switchModel(
          promptId: 'no.such.prompt',
          modelId: 'local:gemma3:27b',
        );
        expect(store.load(), isEmpty);
      });
    });
  });

  group('ToolCatalogueInspector', () {
    const catalogue = <Map<String, Object?>>[
      {
        'name': 'memory.read',
        'group': 'memory',
        'description': 'Recalls nodes from memory for a query (read-only).',
        'input_schema': {
          'type': 'object',
          'properties': {
            'query': {'type': 'string'}
          },
        },
      },
      {
        'name': 'file.write',
        'group': 'file',
        'description': 'Writes a file within the writeable scope.',
        'input_schema': {'type': 'object'},
      },
      {
        'name': 'memory.write',
        'group': 'memory',
        'description': 'Persists a node to memory.',
        'input_schema': {'type': 'object'},
      },
    ];

    test('lists tools grouped by family with a one-line description', () async {
      final inspector = ToolCatalogueInspector(catalogue: catalogue);
      final text = await inspector.toolsList();

      expect(text, contains('Tools (3):'));
      expect(text, contains('memory:'));
      expect(text, contains(
          '  memory.read — Recalls nodes from memory for a query (read-only).'));
      expect(text, contains('  memory.write — Persists a node to memory.'));
      expect(text, contains('file:'));
      // memory.read sorts before memory.write within the group.
      expect(text.indexOf('memory.read'),
          lessThan(text.indexOf('memory.write')));
      // The `file` group sorts before `memory`.
      expect(text.indexOf('file:'), lessThan(text.indexOf('memory:')));
    });

    test('inspects one tool with its group, description, and JSON schema',
        () async {
      final inspector = ToolCatalogueInspector(catalogue: catalogue);
      final text = await inspector.toolDetail('memory.read');

      expect(text, contains('Tool memory.read'));
      expect(text, contains('group: memory'));
      expect(text, contains(
          'description: Recalls nodes from memory for a query (read-only).'));
      expect(text, contains('input schema:'));
      expect(text, contains('"query"'));
    });

    test('reports an unknown tool name', () async {
      final inspector = ToolCatalogueInspector(catalogue: catalogue);
      expect(await inspector.toolDetail('no.such.tool'),
          'No tool named "no.such.tool" is configured.');
    });

    test('reports an empty catalogue', () async {
      final inspector = ToolCatalogueInspector(catalogue: const []);
      expect(await inspector.toolsList(), 'No tools are configured.');
    });

    test('defaults to the engine shipped catalogue (non-empty)', () async {
      final text = await ToolCatalogueInspector().toolsList();
      expect(text, startsWith('Tools ('));
      // The shipped set includes the memory + file families.
      expect(text, contains('memory.read'));
      expect(text, contains('file.write'));
    });
  });
}

/// A memory client double that answers only `stats()`; every other member falls
/// through `noSuchMethod` (none are exercised by the inspector).
class _StatsMemoryClient implements TomBrainMemoryClient {
  _StatsMemoryClient(this._stats);

  final MemoryStats _stats;

  @override
  Future<MemoryStats> stats() async => _stats;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
