// Module 3 (model) — the `/api/dream/*` JSON contract decodes into the
// client-side DTOs (§ 5A / § 8.3 (14)). Proves the lane selector, the run-row
// summary (including the omitted-optional → null rule, § 3.1), and the run-tree
// detail reusing the shared `ProcedureRun` decoder (a turn-less run, § 3.6).

import 'package:flutter_test/flutter_test.dart';
import 'package:tom_brain_observatory_web/src/model/dream_run.dart';

void main() {
  group('DreamLane.fromJson', () {
    test('decodes id, agents, and run count', () {
      final lane = DreamLane.fromJson(<String, dynamic>{
        'id': 'fast',
        'agents': <String>['dream_extract_v1', 'dream_connect_v1'],
        'runCount': 3,
      });
      expect(lane.id, 'fast');
      expect(lane.agents, <String>['dream_extract_v1', 'dream_connect_v1']);
      expect(lane.runCount, 3);
    });

    test('the synthetic other lane decodes with no agents', () {
      final lane = DreamLane.fromJson(<String, dynamic>{
        'id': 'other',
        'runCount': 1,
      });
      expect(lane.id, 'other');
      expect(lane.agents, isEmpty);
      expect(lane.runCount, 1);
    });
  });

  group('DreamRunRow.fromJson', () {
    test('decodes a full row', () {
      final row = DreamRunRow.fromJson(<String, dynamic>{
        'runId': 'run_1781400000000002_0',
        'procedureId': 'dream_synthesise_v1',
        'laneId': 'slow',
        'recordedAt': '2026-01-02T03:00:00.000Z',
        'outcomeStatus': 'accepted',
        'elapsedMs': 12500,
        'llmCallCount': 1,
        'memoryAccessCount': 3,
      });
      expect(row.runId, 'run_1781400000000002_0');
      expect(row.procedureId, 'dream_synthesise_v1');
      expect(row.laneId, 'slow');
      expect(row.recordedAt, DateTime.utc(2026, 1, 2, 3));
      expect(row.outcomeStatus, 'accepted');
      expect(row.elapsedMs, 12500);
      expect(row.llmCallCount, 1);
      expect(row.memoryAccessCount, 3);
    });

    test('omitted optionals decode to null / zero (§ 3.1)', () {
      final row = DreamRunRow.fromJson(<String, dynamic>{
        'runId': 'run_x_0',
        'procedureId': 'dream_custom_v1',
        'laneId': 'other',
        'llmCallCount': 0,
        'memoryAccessCount': 1,
      });
      expect(row.recordedAt, isNull);
      expect(row.outcomeStatus, isNull);
      expect(row.elapsedMs, isNull);
    });
  });

  group('DreamRun.fromJson', () {
    test('decodes the run-tree as a turn-less ProcedureRun (§ 3.6)', () {
      final run = DreamRun.fromJson(<String, dynamic>{
        'runId': 'run_1781400000000001_0',
        'procedureId': 'dream_extract_v1',
        'laneId': 'fast',
        'run': <String, dynamic>{
          'procedureId': 'dream_extract_v1',
          'runId': 'run_1781400000000001_0',
          'status': 'accepted',
          'elapsedMs': 3200,
          'nodes': <Map<String, dynamic>>[
            <String, dynamic>{'kind': 'note', 'category': 'extract'},
          ],
        },
      });
      expect(run.runId, 'run_1781400000000001_0');
      expect(run.procedureId, 'dream_extract_v1');
      expect(run.laneId, 'fast');
      expect(run.run.turnId, isNull); // turn-less.
      expect(run.run.status, 'accepted');
      expect(run.run.nodes, hasLength(1));
    });
  });
}
