// PT-3.1 (backend) — `GET /api/procedures/<procedureId>` serves the d4rt source
// of a running brain's procedure script (`scripts/system/<id>.dart`) read-only,
// so the Module-1 inspector can show what actually ran (§ 4.6, § 8.3(5)). Tests
// cover the happy path (the source is returned verbatim as text/plain), the
// containment guard (a procedureId that escapes the script root via path
// segments is refused), the missing-script 404, the unconfigured-script-root
// 404, and OBS-1 (no mutation of the script tree).

import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:tom_brain_observatory/tom_brain_observatory.dart';
import 'package:test/test.dart';

const _fixtureHost = 'test/fixtures/trail/fixturehost';
const _fixtureScripts = 'test/fixtures/scripts';

Future<Response> _get(TrailReadApi api, String path) async =>
    await api.handler(Request('GET', Uri.parse('http://localhost/$path')));

void main() {
  final api = TrailReadApi(
    host: TrailHost.at(_fixtureHost),
    scriptRoot: Directory(_fixtureScripts),
  );

  test('serves the verbatim d4rt source as text/plain', () async {
    final res = await _get(api, 'api/procedures/answer_with_memory_v1');
    expect(res.statusCode, 200);
    expect(res.headers['content-type'], contains('text/plain'));
    final body = await res.readAsString();
    final onDisk =
        File('$_fixtureScripts/answer_with_memory_v1.dart').readAsStringSync();
    expect(body, onDisk);
    expect(body, contains('@procedure'));
  });

  test('refuses a procedureId that escapes the script root', () async {
    // `..%2f..%2fpubspec` would resolve outside the script dir; the guard must
    // refuse it before any read.
    final res = await _get(
      api,
      'api/procedures/${Uri.encodeComponent('../../pubspec')}',
    );
    expect(res.statusCode, anyOf(HttpStatus.forbidden, HttpStatus.notFound));
  });

  test('404 when the named script does not exist', () async {
    final res = await _get(api, 'api/procedures/does_not_exist_v9');
    expect(res.statusCode, HttpStatus.notFound);
  });

  test('404 when the script root is unconfigured', () async {
    final unconfigured = TrailReadApi(host: TrailHost.at(_fixtureHost));
    final res = await _get(unconfigured, 'api/procedures/answer_with_memory_v1');
    expect(res.statusCode, HttpStatus.notFound);
  });

  test('OBS-1: the endpoint mutates no script file', () async {
    final before = _mtimes(_fixtureScripts);
    await _get(api, 'api/procedures/answer_with_memory_v1');
    expect(_mtimes(_fixtureScripts), before);
  });
}

Map<String, DateTime> _mtimes(String root) => <String, DateTime>{
      for (final entity in Directory(root).listSync(recursive: true))
        if (entity is File) entity.path: entity.statSync().modified,
    };
