// PT-2.0 — the one-process, one-origin seam, proven against the *real* Flutter
// build. PT-1.5 proved the static-root contract with a stub asset dir; this
// test proves the actual `tom_brain_observatory_web/build/web` output is
// consumable by that same static root: `GET /` serves the built index, `/api`
// still routes to the JSON API, and an unknown app route falls back to the SPA
// index. The test self-skips when the web app has not been built yet so it
// never blocks `dart test` on a fresh checkout (run `flutter build web` in
// tom_brain_observatory_web to exercise it).

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:tom_brain_observatory/tom_brain_observatory.dart';
import 'package:test/test.dart';

const _fixtureHost = 'test/fixtures/trail/fixturehost';

/// The sibling web app's build output, relative to this package root.
final Directory _webBuild = Directory(p.normalize(
    p.join('..', 'tom_brain_observatory_web', 'build', 'web')));

Future<Response> _get(TrailReadApi api, String path) async =>
    await api.handler(Request('GET', Uri.parse('http://localhost/$path')));

void main() {
  final built = File(p.join(_webBuild.path, 'index.html')).existsSync();

  group('PT-2.0 — the real Flutter build is served by the static root', () {
    final api = TrailReadApi(host: TrailHost.at(_fixtureHost), webRoot: _webBuild);

    test('GET / serves the built Flutter index.html', () async {
      final res = await _get(api, '');
      expect(res.statusCode, 200);
      // The Flutter bootstrap loader is the unmistakable signature of the build.
      expect(await res.readAsString(), contains('flutter_bootstrap.js'));
    });

    test('an unknown app route falls back to the build index (SPA)', () async {
      final res = await _get(api, 'traces/some-turn-id');
      expect(res.statusCode, 200);
      expect(await res.readAsString(), contains('flutter_bootstrap.js'));
    });

    test('/api still routes to the JSON API, not the web build', () async {
      final res = await _get(api, 'api/traces');
      expect(res.headers['content-type'], contains('application/json'));
    });
  },
      skip: built
          ? false
          : 'tom_brain_observatory_web/build/web not present — run '
              '`flutter build web` to exercise the real-build serving seam');
}
