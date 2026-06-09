// E.43 — the `GET /healthz` liveness endpoint.
//
// Plan step E.43 (verbatim): "Implement health check `GET /healthz` returning
// `{ status: "ok", uptime_s: N, queues: {…} }`."
//
// `HealthCheck` renders `{ status, uptime_s, queues }`. It reads the dispatcher
// coordinator's live state through an injectable `QueueSnapshotSource` seam
// (the access layer holds only a `Dispatcher`, never the coordinator), and
// stamps uptime from an injectable clock captured at construction. These tests
// drive it with a probe snapshot source + a controllable clock, both directly
// (`currentBody` / `uptimeSeconds`) and through the mounted `shelf` handler
// with a synthesised request. What is proven:
//
//   1. The body conforms to the spec shape: `status: "ok"`, `uptime_s`, and a
//      `queues` object carrying the live coordinator snapshot.
//   2. `uptime_s` measures whole seconds since construction off the clock, and
//      is clamped at zero against a non-monotonic clock.
//   3. A draining coordinator flips `status` to `"draining"`.
//   4. The `queues` payload reflects the live snapshot each call (busy slots,
//      waiting queue length, depth) — it is re-read, not cached.
//   5. `GET /healthz` answers `200 application/json` with that body; any other
//      route on the handler is a `404`.

import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:tom_brain_access/tom_brain_access.dart';

/// A snapshot with overridable fields; defaults model a fully-idle coordinator.
QueueSnapshot _snapshot({
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

/// Calls the mounted handler for [method] [path] and returns the response.
Future<Response> _call(HealthCheck health, String method, String path) async {
  return await health.handler(
    Request(method, Uri.parse('http://localhost$path')),
  );
}

/// Reads and JSON-decodes a response body into a map.
Future<Map<String, Object?>> _bodyJson(Response response) async {
  return jsonDecode(await response.readAsString()) as Map<String, Object?>;
}

void main() {
  group('E.43 HealthCheck', () {
    test('renders the spec body shape { status: "ok", uptime_s, queues }',
        () async {
      DateTime now = DateTime.utc(2026, 6, 2, 12, 0, 0);
      final health = HealthCheck(
        queueSnapshot: _snapshot,
        clock: () => now,
      );

      now = now.add(const Duration(seconds: 42));
      final Map<String, Object?> body = health.currentBody();

      expect(body['status'], HealthCheck.statusOk);
      expect(body['uptime_s'], 42);
      expect(body['queues'], isA<Map<String, Object?>>());
      final queues = body['queues'] as Map<String, Object?>;
      expect(queues['foreground'], <String, Object?>{
        'running': false,
        'waiting': 0,
        'depth': 4,
      });
      expect(queues['background'], <String, Object?>{'running': false});
      expect(queues['draining'], false);
    });

    test('uptime_s counts whole seconds since construction', () {
      DateTime now = DateTime.utc(2026, 6, 2, 12, 0, 0);
      final health = HealthCheck(
        queueSnapshot: _snapshot,
        clock: () => now,
      );

      expect(health.uptimeSeconds, 0);
      now = now.add(const Duration(milliseconds: 1500));
      // Whole seconds only: 1.5 s of uptime reads as 1.
      expect(health.uptimeSeconds, 1);
      now = now.add(const Duration(seconds: 10));
      expect(health.uptimeSeconds, 11);
    });

    test('uptime_s is clamped at zero against a non-monotonic clock', () {
      DateTime now = DateTime.utc(2026, 6, 2, 12, 0, 0);
      final health = HealthCheck(
        queueSnapshot: _snapshot,
        clock: () => now,
      );

      now = now.subtract(const Duration(seconds: 5));
      expect(health.uptimeSeconds, 0);
    });

    test('a draining coordinator flips status to "draining"', () {
      final health = HealthCheck(
        queueSnapshot: () => _snapshot(draining: true),
      );

      final Map<String, Object?> body = health.currentBody();
      expect(body['status'], HealthCheck.statusDraining);
      expect((body['queues'] as Map<String, Object?>)['draining'], true);
    });

    test('the queues payload re-reads the live snapshot on every call', () {
      var foregroundRunning = false;
      var waiting = 0;
      final health = HealthCheck(
        queueSnapshot: () => _snapshot(
          foregroundRunning: foregroundRunning,
          foregroundWaiting: waiting,
        ),
      );

      var queues = health.currentBody()['queues'] as Map<String, Object?>;
      expect((queues['foreground'] as Map<String, Object?>)['running'], false);

      // Coordinator state changes between calls; the next read reflects it.
      foregroundRunning = true;
      waiting = 3;
      queues = health.currentBody()['queues'] as Map<String, Object?>;
      expect(queues['foreground'], <String, Object?>{
        'running': true,
        'waiting': 3,
        'depth': 4,
      });
    });

    test('GET /healthz answers 200 application/json with the body', () async {
      DateTime now = DateTime.utc(2026, 6, 2, 12, 0, 0);
      final health = HealthCheck(
        queueSnapshot: () => _snapshot(backgroundRunning: true),
        clock: () => now,
      );
      now = now.add(const Duration(seconds: 7));

      final Response response = await _call(health, 'GET', HealthCheck.path);

      expect(response.statusCode, 200);
      expect(
        response.headers['content-type'],
        'application/json; charset=utf-8',
      );
      final Map<String, Object?> body = await _bodyJson(response);
      expect(body['status'], HealthCheck.statusOk);
      expect(body['uptime_s'], 7);
      expect(
        (body['queues'] as Map<String, Object?>)['background'],
        <String, Object?>{'running': true},
      );
    });

    test('any other route on the handler is a 404', () async {
      final health = HealthCheck(queueSnapshot: _snapshot);

      final Response response = await _call(health, 'GET', '/not-healthz');
      expect(response.statusCode, 404);
    });
  });
}
