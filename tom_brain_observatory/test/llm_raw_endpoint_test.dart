// PT-2.4 (backend) — `GET /api/llm?turn=&path=` serves the verbatim raw LLM
// dump (§ 3.7) behind a run-tree LlmCall's `rawPath` link, so the front-end can
// render the full §4.5 detail (hashes, wire body, answer). Tests cover the
// happy path (the dump is returned verbatim), the containment guard (a link
// that escapes `<root>/llm/` is refused), the not-an-llm-dump refusal, the
// missing-dump 404, the bad-request when params are absent, and OBS-1 (no
// mutation).

import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:tom_brain_observatory/tom_brain_observatory.dart';
import 'package:test/test.dart';

const _fixtureHost = 'test/fixtures/trail/fixturehost';

Future<Response> _get(TrailReadApi api, String path) async =>
    await api.handler(Request('GET', Uri.parse('http://localhost/$path')));

void main() {
  final api = TrailReadApi(host: TrailHost.at(_fixtureHost));

  // The link a run-tree LlmCall carries (relative to procedures/<proc>/).
  const turnId = '260101-120000.000001';
  const goodLink = '../../llm/assistant_to_user/260101-120000.000001__02.raw.json';

  test('serves the verbatim §3.7 raw dump for a valid link', () async {
    final res = await _get(api, 'api/llm?turn=$turnId&path=${Uri.encodeQueryComponent(goodLink)}');
    expect(res.statusCode, 200);
    expect(res.headers['content-type'], contains('application/json'));
    final dump = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
    expect(dump['callType'], 'assistant_to_user');
    expect(dump['provider'], 'local');
    expect(dump['model'], 'fixture-model');
    expect(dump['anchorHash'], startsWith('sha256:'));
    expect(dump['promptHash'], startsWith('sha256:'));
    expect((dump['wire'] as Map)['messages'], isA<List<dynamic>>());
    expect(dump['answer'], isA<String>());
  });

  test('refuses a link that escapes the llm root (containment guard)', () async {
    const escape = '../../llm/../../../secret_outside_webroot.txt';
    final res = await _get(api, 'api/llm?turn=$turnId&path=${Uri.encodeQueryComponent(escape)}');
    expect(res.statusCode, HttpStatus.forbidden);
  });

  test('refuses a non-.raw.json link under llm/', () async {
    const notDump = '../../llm/assistant_to_user/notes.txt';
    final res = await _get(api, 'api/llm?turn=$turnId&path=${Uri.encodeQueryComponent(notDump)}');
    expect(res.statusCode, HttpStatus.forbidden);
  });

  test('404 when the dump does not exist', () async {
    const missing = '../../llm/assistant_to_user/does_not_exist.raw.json';
    final res = await _get(api, 'api/llm?turn=$turnId&path=${Uri.encodeQueryComponent(missing)}');
    expect(res.statusCode, HttpStatus.notFound);
  });

  test('400 when turn or path is missing', () async {
    expect((await _get(api, 'api/llm?turn=$turnId')).statusCode, HttpStatus.badRequest);
    expect((await _get(api, 'api/llm')).statusCode, HttpStatus.badRequest);
  });

  test('OBS-1: the endpoint mutates no trail file', () async {
    final before = _mtimes(_fixtureHost);
    await _get(api, 'api/llm?turn=$turnId&path=${Uri.encodeQueryComponent(goodLink)}');
    expect(_mtimes(_fixtureHost), before);
  });
}

Map<String, DateTime> _mtimes(String root) => <String, DateTime>{
      for (final entity in Directory(root).listSync(recursive: true))
        if (entity is File) entity.path: entity.statSync().modified,
    };
