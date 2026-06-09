// PT-1.3 — prompt-list correlation. Proves the last-N turns are correlated
// across `incoming/` + `procedures/` + `sessions/` by `turnId`, newest-first,
// with the §4.1 per-row summary fields — and that the list degrades to empty
// (not an error) in unconfigured mode (§ 8.1).

import 'package:tom_brain_observatory/tom_brain_observatory.dart';
import 'package:test/test.dart';

void main() {
  final host = TrailHost.at('test/fixtures/trail/fixturehost');

  group('promptList — configured host', () {
    final rows = promptList(host);

    test('one row per incoming record, newest-first', () {
      expect(rows.map((r) => r.turnId), <String>[
        '260101-120200.000003', // 12:02 — newest
        '260101-120100.000002', // 12:01
        '260101-120000.000001', // 12:00 — oldest
      ]);
    });

    test('accepted turn row carries outcome + counts', () {
      final row = rows.firstWhere((r) => r.turnId == '260101-120000.000001');
      expect(row.channel, 'openai');
      expect(row.principalId, 'fixture-user');
      expect(row.persona, 'tom-assistant');
      expect(row.preview, 'Fixture: what did we decide about the backup topology?');
      expect(row.outcomeStatus, 'accepted');
      expect(row.wallClockMs, 2100);
      expect(row.llmCallCount, 2);
      expect(row.memoryAccessCount, 5);
    });

    test('errored turn row reflects the errored outcome', () {
      final row = rows.firstWhere((r) => r.turnId == '260101-120100.000002');
      expect(row.outcomeStatus, 'errored');
      expect(row.wallClockMs, 8300);
      expect(row.llmCallCount, 1);
    });

    test('in-flight turn row has no outcome and zero counts', () {
      final row = rows.firstWhere((r) => r.turnId == '260101-120200.000003');
      expect(row.outcomeStatus, isNull);
      expect(row.wallClockMs, isNull);
      expect(row.llmCallCount, 0);
      expect(row.memoryAccessCount, 0);
    });

    test('limit caps the window, keeping the newest', () {
      final capped = promptList(host, limit: 1);
      expect(capped, hasLength(1));
      expect(capped.single.turnId, '260101-120200.000003');
    });
  });

  group('promptList — unconfigured host (§ 8.1)', () {
    test('degrades to an empty list, never an error', () {
      final unconfigured = TrailHost.at('test/fixtures/trail/unconfiguredhost');
      expect(unconfigured.isUnconfigured, isTrue);
      expect(promptList(unconfigured), isEmpty);
    });
  });
}
