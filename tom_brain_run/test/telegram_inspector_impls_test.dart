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

import 'dart:io';

import 'package:tom_brain_access/tom_brain_access.dart'
    show AccessChannel, IncomingTrailRecord, QueueSnapshot;
import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        LatencyHistogram,
        MemoryStats,
        TomBrainMemoryClient,
        TurnId;
import 'package:test/test.dart';

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
