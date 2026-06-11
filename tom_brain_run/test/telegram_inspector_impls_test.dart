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

import 'dart:io';

import 'package:tom_brain_access/tom_brain_access.dart'
    show AccessChannel, IncomingTrailRecord;
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
