// Module 3 — dreaming-cycle monitor (`prompt_tracing.md` § 5A) at the HTTP edge.
// Route-level tests over the fixture trail tree for the three `/api/dream/*`
// endpoints (§ 8.3 (14)): the lane selector, the run list (all lanes + a single
// lane), and the single run-tree detail (200 + 404). The builder-level
// behaviour (lane grouping, the synthetic `other` lane, per-tree counts) is
// proven in `dream_list_builder_test.dart`; here we prove the JSON wire shape
// and the status codes a front-end depends on.

import 'dart:convert';
import 'dart:io';

import 'package:tom_brain_observatory/tom_brain_observatory.dart';
import 'package:test/test.dart';

import 'support/obs_harness.dart';

void main() {
  final host = TrailHost.at(fixtureHostPath);
  final api = TrailReadApi(host: host);

  // Pin the three dream-fixture mtimes so the newest-first ordering (§ 5A.2) is
  // deterministic regardless of checkout, matching `dream_list_builder_test`.
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

  group('GET /api/dream/lanes', () {
    test('returns the canonical lanes plus the synthetic other lane', () async {
      final res = await obsGet(api, 'api/dream/lanes');
      expect(res.statusCode, 200);
      final lanes = jsonDecode(await res.readAsString()) as List;
      expect(lanes.map((l) => (l as Map)['id']),
          <String>['fast', 'slow', 'deep', 'monthly', 'other']);
    });

    test('each lane carries its agent set and recent-run count', () async {
      final res = await obsGet(api, 'api/dream/lanes');
      final lanes = <String, Map<String, Object?>>{
        for (final lane in jsonDecode(await res.readAsString()) as List)
          (lane as Map)['id'] as String: lane.cast<String, Object?>(),
      };
      expect(lanes['fast']!['agents'],
          <String>['dream_extract_v1', 'dream_connect_v1']);
      expect(lanes['fast']!['runCount'], 1);
      expect(lanes['other']!['runCount'], 1);
    });
  });

  group('GET /api/dream/runs', () {
    test('all lanes, newest-first', () async {
      final res = await obsGet(api, 'api/dream/runs');
      expect(res.statusCode, 200);
      final rows = jsonDecode(await res.readAsString()) as List;
      expect(rows.map((r) => (r as Map)['procedureId']),
          <String>['dream_extract_v1', 'dream_synthesise_v1', 'dream_custom_v1']);
    });

    test('the row carries lane, outcome, and per-tree counts', () async {
      final res = await obsGet(api, 'api/dream/runs');
      final rows = jsonDecode(await res.readAsString()) as List;
      final synth = (rows.firstWhere(
        (r) => (r as Map)['procedureId'] == 'dream_synthesise_v1',
      ) as Map);
      expect(synth['runId'], 'run_1781400000000002_0');
      expect(synth['laneId'], 'slow');
      expect(synth['outcomeStatus'], 'accepted');
      expect(synth['elapsedMs'], 12500);
      expect(synth['llmCallCount'], 1);
      expect(synth['memoryAccessCount'], 3);
    });

    test('?lane= narrows to one lane', () async {
      final res = await obsGet(api, 'api/dream/runs?lane=fast');
      final rows = jsonDecode(await res.readAsString()) as List;
      expect(rows, hasLength(1));
      expect((rows.single as Map)['procedureId'], 'dream_extract_v1');
    });

    test('?lane=other selects the synthetic lane', () async {
      final res = await obsGet(api, 'api/dream/runs?lane=other');
      final rows = jsonDecode(await res.readAsString()) as List;
      expect(rows, hasLength(1));
      expect((rows.single as Map)['procedureId'], 'dream_custom_v1');
    });
  });

  group('GET /api/dream/stream', () {
    // MSPP-57 — the dreaming-side live-tail. Over the committed (finished)
    // fixture runs the stream adopts the newest dream run, replays its run-tree
    // operations as `data:` frames, and closes with a terminal `done` frame.
    test('replays the newest run\'s ops and closes on the outcome', () async {
      final res = await obsGet(api, 'api/dream/stream');
      expect(res.statusCode, 200);
      expect(res.headers['content-type'], contains('text/event-stream'));

      final frames = (await drainSse(res)).cast<Map<String, Object?>>();
      // The newest (pinned) run is dream_extract_v1: recall, llm, persist, done.
      expect(
          frames.map((f) => f['kind'] ?? (f['done'] == true ? 'done' : null)),
          <Object?>['primitive', 'llm', 'primitive', 'done']);
      expect(frames.last['runId'], 'run_1781400000000001_0');
      expect(frames.last['status'], 'accepted');
    });

    test('?lane= narrows the stream to that lane\'s newest run', () async {
      final res = await obsGet(api, 'api/dream/stream?lane=slow');
      final frames = (await drainSse(res)).cast<Map<String, Object?>>();
      // The slow lane's newest run is dream_synthesise_v1 (a sub-run recall, the
      // llm, a persist, an edge), so the terminal frame names that run.
      expect(frames.last['done'], isTrue);
      expect(frames.last['runId'], 'run_1781400000000002_0');
      expect(frames.where((f) => f['kind'] == 'llm'), hasLength(1));
    });
  });

  group('GET /api/dream/runs/{runId}', () {
    test('resolves a turn-less run to its run-tree', () async {
      final res = await obsGet(api, 'api/dream/runs/run_1781400000000001_0');
      expect(res.statusCode, 200);
      final run = jsonDecode(await res.readAsString()) as Map;
      expect(run['runId'], 'run_1781400000000001_0');
      expect(run['procedureId'], 'dream_extract_v1');
      expect(run['laneId'], 'fast');
      expect((run['run'] as Map)['procedureId'], 'dream_extract_v1');
      expect((run['run'] as Map)['turnId'], isNull); // turn-less (§ 3.6).
    });

    test('unknown runId → 404, not an SPA fallthrough', () async {
      final res = await obsGet(api, 'api/dream/runs/run_does_not_exist_9');
      expect(res.statusCode, 404);
    });

    test('a turn-bound runId is not resolvable as a dream run (→ 404)',
        () async {
      final res = await obsGet(api, 'api/dream/runs/run_1781337010868413_2');
      expect(res.statusCode, 404);
    });
  });
}
