// Module 3 — dreaming-cycle monitor (`prompt_tracing.md` § 5A). Proves the
// turn-less dream-run discovery + lane grouping: lanes derived from the canonical
// `CadenceSchedule`, the synthetic `other` lane for unclaimed agents, the
// newest-first run list with per-run counts, lane filtering, and the single
// run-tree detail. Degrades to empty (not an error) in unconfigured mode (§ 8.1).

import 'dart:io';

import 'package:tom_brain_observatory/tom_brain_observatory.dart';
import 'package:test/test.dart';

void main() {
  final host = TrailHost.at('test/fixtures/trail/fixturehost');

  // The three dream fixtures live under procedures/dream_*; pin their mtimes so
  // the newest-first ordering (§ 5A.2) is deterministic regardless of checkout.
  setUpAll(() {
    final base = DateTime.utc(2026, 1, 2, 3, 0, 0);
    File('${host.root.path}/procedures/dream_extract_v1/'
            'run_1781400000000001_0.log')
        .setLastModifiedSync(base);
    File('${host.root.path}/procedures/dream_synthesise_v1/'
            'run_1781400000000002_0.log')
        .setLastModifiedSync(base.subtract(const Duration(minutes: 1)));
    File('${host.root.path}/procedures/dream_custom_v1/'
            'run_1781400000000003_0.log')
        .setLastModifiedSync(base.subtract(const Duration(minutes: 2)));
  });

  group('dreamLanes — configured host', () {
    test('emits the four canonical lanes plus a synthetic other lane', () {
      final lanes = dreamLanes(host);
      expect(lanes.map((l) => l.id),
          <String>['fast', 'slow', 'deep', 'monthly', 'other']);
    });

    test('lane agent sets mirror CadenceSchedule.defaults()', () {
      final fast = dreamLanes(host).firstWhere((l) => l.id == 'fast');
      expect(fast.agents, <String>['dream_extract_v1', 'dream_connect_v1']);
    });

    test('run counts reflect the discovered dream runs per lane', () {
      final byId = <String, DreamLane>{
        for (final lane in dreamLanes(host)) lane.id: lane,
      };
      expect(byId['fast']!.runCount, 1); // dream_extract_v1
      expect(byId['slow']!.runCount, 1); // dream_synthesise_v1
      expect(byId['deep']!.runCount, 0);
      expect(byId['monthly']!.runCount, 0);
      expect(byId['other']!.runCount, 1); // dream_custom_v1 (no lane)
    });
  });

  group('dreamRunRows — configured host', () {
    test('all lanes, newest-first by recorded time', () {
      final rows = dreamRunRows(host);
      expect(rows.map((r) => r.procedureId),
          <String>['dream_extract_v1', 'dream_synthesise_v1', 'dream_custom_v1']);
    });

    test('row carries lane, outcome, elapsed, and per-tree counts', () {
      final synth = dreamRunRows(host)
          .firstWhere((r) => r.procedureId == 'dream_synthesise_v1');
      expect(synth.runId, 'run_1781400000000002_0');
      expect(synth.laneId, 'slow');
      expect(synth.outcomeStatus, 'accepted');
      expect(synth.elapsedMs, 12500);
      expect(synth.llmCallCount, 1);
      // recall (in sub-run) + persist + edge = 3 primitive accesses.
      expect(synth.memoryAccessCount, 3);
    });

    test('lane filter narrows to one lane', () {
      final fast = dreamRunRows(host, lane: 'fast');
      expect(fast, hasLength(1));
      expect(fast.single.procedureId, 'dream_extract_v1');
    });

    test('the synthetic other lane is selectable', () {
      final other = dreamRunRows(host, lane: 'other');
      expect(other, hasLength(1));
      expect(other.single.procedureId, 'dream_custom_v1');
    });
  });

  group('dreamRunFor — configured host', () {
    test('resolves a run-tree by its bare runId', () {
      final run = dreamRunFor(host, 'run_1781400000000001_0');
      expect(run, isNotNull);
      expect(run!.procedureId, 'dream_extract_v1');
      expect(run.laneId, 'fast');
      expect(run.run.turnId, isNull); // a dream run is turn-less (§ 3.6).
      expect(run.run.status, 'accepted');
    });

    test('returns null for an unknown runId (→ 404)', () {
      expect(dreamRunFor(host, 'run_does_not_exist_9'), isNull);
    });

    test('a turn-bound runId is not resolvable as a dream run', () {
      // The 12:03 answer run is turn-bound (its log basename carries `__`); it
      // must not surface through the dream path.
      expect(dreamRunFor(host, 'run_1781337010868413_2'), isNull);
    });
  });

  group('dream views — unconfigured host (§ 8.1)', () {
    final unconfigured = TrailHost.at('test/fixtures/trail/unconfiguredhost');

    test('degrade to empty / null, never an error', () {
      expect(dreamLanes(unconfigured), isEmpty);
      expect(dreamRunRows(unconfigured), isEmpty);
      expect(dreamRunFor(unconfigured, 'run_1781400000000001_0'), isNull);
    });
  });
}
