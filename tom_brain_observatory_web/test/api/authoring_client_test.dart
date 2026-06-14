// Slice 4 web data layer — the source-authoring writes over [HttpTraceApiClient]
// (§ 6.3, AUTH-1…AUTH-5). A `MockClient` stands in for the network: the tests
// pin the URL/method/body each call marshals to, that a `200` is a clean save,
// that a `422` decodes into the brain's validator findings (procedure) or a
// single normalised finding (prompt), and that a `403`/`404` throws — those are
// misconfigurations, never an editable outcome the editor should swallow.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tom_brain_observatory_web/src/api/trace_api_client.dart';

void main() {
  final origin = Uri.parse('http://localhost:8787/');

  HttpTraceApiClient clientThat(
    List<http.Request> seen,
    http.Response Function(http.Request) responder,
  ) =>
      HttpTraceApiClient(
        origin: origin,
        httpClient: MockClient((req) async {
          seen.add(req);
          return responder(req);
        }),
      );

  http.Response json(int status, Object body) => http.Response(
        jsonEncode(body),
        status,
        headers: const <String, String>{'content-type': 'application/json'},
      );

  group('writeProcedureScript', () {
    test('PUTs the verbatim source to /api/procedures/<id> and is saved on 200',
        () async {
      final seen = <http.Request>[];
      final client =
          clientThat(seen, (_) => json(200, <String, Object?>{'ok': true}));

      final result = await client.writeProcedureScript('answer_v1', 'SOURCE');

      expect(result.ok, isTrue);
      final req = seen.single;
      expect(req.method, 'PUT');
      expect(req.url.path, '/api/procedures/answer_v1');
      expect(req.body, 'SOURCE');
    });

    test('decodes a 422 into the validator findings (file untouched server-side)',
        () async {
      final client = clientThat(<http.Request>[], (_) => json(422,
          <String, Object?>{
            'error': 'procedure validation failed',
            'findings': <Object?>[
              <String, Object?>{
                'code': 'procedure.header.invalid',
                'message': 'missing @procedure header',
                'field': 'header',
              },
            ],
          }));

      final result = await client.writeProcedureScript('answer_v1', 'bad');

      expect(result.ok, isFalse);
      expect(result.findings, hasLength(1));
      expect(result.findings.single.code, 'procedure.header.invalid');
      expect(result.findings.single.field, 'header');
    });

    test('a 403 containment refusal throws — not an editable outcome', () async {
      final client = clientThat(<http.Request>[],
          (_) => json(403, <String, Object?>{'error': 'not a procedure script'}));
      expect(() => client.writeProcedureScript('../escape', 'x'),
          throwsA(isA<http.ClientException>()));
    });
  });

  group('readPromptFile', () {
    test('GETs /api/prompts/<roleId>/<part> and returns the verbatim prose',
        () async {
      final seen = <http.Request>[];
      final client = clientThat(
          seen, (_) => http.Response('persona prose', 200));

      final prose = await client.readPromptFile('analyser', 'persona');

      expect(prose, 'persona prose');
      expect(seen.single.url.path, '/api/prompts/analyser/persona');
    });

    test('returns null on 404 — the "create override" start', () async {
      final client = clientThat(<http.Request>[],
          (_) => json(404, <String, Object?>{'error': 'no override'}));
      expect(await client.readPromptFile('analyser', 'objective'), isNull);
    });
  });

  group('writePromptFile', () {
    test('PUTs the prose to /api/prompts/<roleId>/<part> and is saved on 200',
        () async {
      final seen = <http.Request>[];
      final client = clientThat(
          seen, (_) => json(200, <String, Object?>{'ok': true}));

      final result =
          await client.writePromptFile('analyser', 'persona', 'new prose');

      expect(result.ok, isTrue);
      final req = seen.single;
      expect(req.method, 'PUT');
      expect(req.url.path, '/api/prompts/analyser/persona');
      expect(req.body, 'new prose');
    });

    test('normalises a 422 error into a single finding', () async {
      final client = clientThat(<http.Request>[], (_) => json(422,
          <String, Object?>{'error': 'prompt prose must be non-empty'}));

      final result = await client.writePromptFile('analyser', 'persona', '  ');

      expect(result.ok, isFalse);
      expect(result.findings.single.message, 'prompt prose must be non-empty');
    });
  });
}
