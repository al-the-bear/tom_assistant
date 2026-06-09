// PT-4.1 (backend) — the SSE live-tail endpoints (§ 4.8). `GET
// /api/traces/<turnId>/stream` streams a turn's cognitive steps as
// `text/event-stream`, one `data:` event per `### `-headed step, closing after
// `✅ DONE`. `GET /api/stream` is the list-level stream: an SSE tick the prompt
// list re-fetches on. Both are backed by a read-only file watch over the
// per-session streaming live-trail the brain already writes — OBS-5: no hook
// inside the brain, and the watch never writes the trail.

import 'dart:convert';
import 'dart:io';

import 'package:tom_brain_observatory/tom_brain_observatory.dart';
import 'package:test/test.dart';

import 'support/obs_harness.dart';

void main() {
  final api = TrailReadApi(host: TrailHost.at(fixtureHostPath));

  group('GET /api/traces/<turnId>/stream', () {
    test('streams one event per cognitive step, terminating on DONE', () async {
      final res = await obsGet(api, 'api/traces/$fixtureFinishedTurn/stream');
      expect(res.statusCode, 200);
      expect(res.headers['content-type'], contains('text/event-stream'));

      final events = (await drainSse(res)).cast<Map<String, Object?>>();
      // The fixture turn: thinking, recallMulti, tool web.search, assistant, DONE.
      expect(events.length, 5);
      expect(events.first['heading'], '🧠 thinking (recall_planner)');
      expect(events.last['done'], isTrue);
      expect(events.where((e) => e['done'] == true), hasLength(1));
    });

    test('404 when no session live-trail carries the turn', () async {
      final res = await obsGet(api, 'api/traces/999999-000000.000000/stream');
      expect(res.statusCode, HttpStatus.notFound);
    });

    // OBS-5 (streaming mutates no trail file; the live-tail is an OS file-watch,
    // not an in-process hook) is proven in `obs_conformance_test.dart` (Phase 8).
  });

  group('GET /api/stream', () {
    test('emits an initial list-changed tick on connect', () async {
      final res = await obsGet(api, 'api/stream');
      expect(res.statusCode, 200);
      expect(res.headers['content-type'], contains('text/event-stream'));

      // The list stream never closes; take the first chunk then stop.
      final first = utf8.decode(await res.read().first);
      expect(first, contains('data:'));
      final payload = jsonDecode(
          first.split('data: ').last.trim()) as Map<String, Object?>;
      expect(payload['changed'], isTrue);
    });
  });
}
