// PT-1.4 + PT-1.5 — the Trail Read API surface. Route-level tests over the
// fixture trail tree: the `/api` JSON endpoints (list + single trace), the
// static root at `/` with SPA fallback and traversal refusal, and the read-only
// invariant (OBS-1) that no request mutates a single trail file.

import 'dart:convert';
import 'dart:io';

import 'package:tom_brain_observatory/tom_brain_observatory.dart';
import 'package:test/test.dart';

import 'support/obs_harness.dart';

void main() {
  final host = TrailHost.at(fixtureHostPath);

  group('PT-1.4 — /api JSON endpoints', () {
    final api = TrailReadApi(host: host);

    test('GET /api/traces → newest-first prompt list', () async {
      final res = await obsGet(api, 'api/traces');
      expect(res.statusCode, 200);
      final rows = jsonDecode(await res.readAsString()) as List;
      expect(rows.map((r) => (r as Map)['turnId']), <String>[
        '260101-120200.000003',
        '260101-120100.000002',
        '260101-120000.000001',
      ]);
    });

    test('GET /api/traces?limit=1 caps the window', () async {
      final res = await obsGet(api, 'api/traces?limit=1');
      final rows = jsonDecode(await res.readAsString()) as List;
      expect(rows, hasLength(1));
      expect((rows.single as Map)['turnId'], '260101-120200.000003');
    });

    test('GET /api/traces/{turnId} → the PromptTrace', () async {
      final res = await obsGet(api, 'api/traces/260101-120000.000001');
      expect(res.statusCode, 200);
      final trace = jsonDecode(await res.readAsString()) as Map;
      expect(trace['turnId'], '260101-120000.000001');
      expect((trace['runTree'] as Map)['procedureId'], 'answer_with_memory_v1');
      expect((trace['reply'] as Map)['outcomeStatus'], 'accepted');
    });

    test('GET /api/traces/{unknown} → 404, not an SPA fallthrough', () async {
      final res = await obsGet(api, 'api/traces/991231-235959.999999');
      expect(res.statusCode, 404);
    });

    // The read-only invariant (OBS-1) across every endpoint is proven
    // comprehensively in `obs_conformance_test.dart` (Phase 8).
  });

  group('PT-1.5 — static root at /', () {
    final api = TrailReadApi(host: host, webRoot: Directory(fixtureWebRootPath));

    test('GET / serves the build index', () async {
      final res = await obsGet(api, '');
      expect(res.statusCode, 200);
      expect(await res.readAsString(), contains('OBSERVATORY_INDEX'));
    });

    test('GET /assets/main.dart.js serves the static asset', () async {
      final res = await obsGet(api, 'assets/main.dart.js');
      expect(res.statusCode, 200);
      expect(await res.readAsString(), contains('ASSET_MAIN_DART_JS'));
    });

    test('unknown app route falls back to index.html (SPA)', () async {
      final res = await obsGet(api, 'traces/some-spa-route');
      expect(res.statusCode, 200);
      expect(await res.readAsString(), contains('OBSERVATORY_INDEX'));
    });

    test('/api still routes to the JSON API, not the static root', () async {
      final res = await obsGet(api, 'api/traces');
      expect(res.headers['content-type'], contains('application/json'));
    });

    test('path-traversal never serves a file outside the web root', () async {
      final res = await obsGet(api, '..%2Fsecret_outside_webroot.txt');
      final body = await res.readAsString();
      expect(body, isNot(contains('SECRET_OUTSIDE_WEBROOT')));
    });
  });
}
