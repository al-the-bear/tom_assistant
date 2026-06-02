// E.11 OpenAI HTTP/SSE adapter — router-scaffold contract test.
//
// Drives `OpenAiHttpSseAdapter`'s shelf handler black-box (Q-E.5.2: a
// synthesised `shelf.Request` passed straight to `handler`, no socket).
// E.11 is the router + the three `/v1/` routes only, so the contract this
// test locks is:
//   - the three routes are mounted under `/v1/` and dispatch by verb+path;
//   - until their behaviour lands (E.12 – E.17) each answers with a
//     wire-shaped `501` in the OpenAI error envelope;
//   - an unknown path/verb returns the OpenAI `404` envelope, not shelf's
//     plain-text default.
// Per-route behaviour (parsing, SSE, JSON, persona, embeddings, models) is
// asserted from E.12 onward; this test deliberately does not anticipate it.

import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart';
import 'package:test/test.dart';

/// Drives [adapter] with a synthesised request and returns the response.
Future<Response> _call(
  OpenAiHttpSseAdapter adapter,
  String method,
  String path, {
  String? body,
}) async {
  final Request request = Request(
    method,
    Uri.parse('http://localhost$path'),
    body: body,
  );
  return await adapter.handler(request);
}

/// Reads the response body and decodes it as the OpenAI error envelope's
/// inner `error` object.
Future<Map<String, Object?>> _errorObject(Response response) async {
  final String raw = await response.readAsString();
  final Map<String, Object?> decoded =
      jsonDecode(raw) as Map<String, Object?>;
  return decoded['error'] as Map<String, Object?>;
}

void main() {
  group('OpenAiHttpSseAdapter router scaffold (E.11)', () {
    late OpenAiHttpSseAdapter adapter;

    setUp(() => adapter = OpenAiHttpSseAdapter());

    group('route table shape', () {
      test('every prototype route hangs under the /v1 base path', () {
        expect(OpenAiHttpSseAdapter.basePath, '/v1');
        expect(OpenAiHttpSseAdapter.chatCompletionsPath,
            '/v1/chat/completions');
        expect(OpenAiHttpSseAdapter.embeddingsPath, '/v1/embeddings');
        expect(OpenAiHttpSseAdapter.modelsPath, '/v1/models');
      });

      test('handler is a callable shelf handler', () {
        // Passing a request through proves the handler resolves; an unknown
        // route still yields a Response (the 404 envelope) rather than
        // throwing.
        expect(
          () => _call(adapter, 'GET', '/v1/anything'),
          returnsNormally,
        );
      });
    });

    group('mounted routes answer 501 until behaviour lands (E.14 – E.17)',
        () {
      test(
          'POST /v1/chat/completions with a well-formed non-streaming body '
          '→ 501 (parsing done E.12; the JSON body lands E.14)', () async {
        // E.12 parses the body and E.13 renders the *streaming* response;
        // this body omits `stream` (defaults to non-streaming), so it gets
        // past parsing and hits the not-yet-wired JSON path — still a 501.
        // (A malformed body would be a 400 — asserted in the E.12 test; a
        // streaming body is asserted in the E.13 test.)
        final Response response = await _call(
          adapter,
          'POST',
          '/v1/chat/completions',
          body: jsonEncode(<String, Object?>{
            'model': 'tom-assistant',
            'messages': <Object?>[
              <String, Object?>{'role': 'user', 'content': 'hello'},
            ],
          }),
        );
        expect(response.statusCode, 501);
        expect(response.headers['content-type'],
            contains('application/json'));
        final Map<String, Object?> error = await _errorObject(response);
        expect(error['type'], 'not_implemented');
        expect(error['code'], 'not_implemented');
      });

      test('POST /v1/embeddings → 501 not_implemented', () async {
        final Response response =
            await _call(adapter, 'POST', '/v1/embeddings', body: '{}');
        expect(response.statusCode, 501);
        final Map<String, Object?> error = await _errorObject(response);
        expect(error['type'], 'not_implemented');
      });

      test('GET /v1/models → 501 not_implemented', () async {
        final Response response = await _call(adapter, 'GET', '/v1/models');
        expect(response.statusCode, 501);
        final Map<String, Object?> error = await _errorObject(response);
        expect(error['type'], 'not_implemented');
      });
    });

    group('unmatched requests return the OpenAI 404 envelope', () {
      test('unknown path under /v1/ → 404 not_found', () async {
        final Response response = await _call(adapter, 'GET', '/v1/unknown');
        expect(response.statusCode, 404);
        expect(response.headers['content-type'],
            contains('application/json'));
        final Map<String, Object?> error = await _errorObject(response);
        expect(error['type'], 'invalid_request_error');
        expect(error['code'], 'not_found');
      });

      test('a path entirely outside /v1/ → 404 not_found', () async {
        final Response response = await _call(adapter, 'GET', '/healthz');
        expect(response.statusCode, 404);
        final Map<String, Object?> error = await _errorObject(response);
        expect(error['code'], 'not_found');
      });

      test('wrong verb on a known path is not served by its stub', () async {
        // GET on the POST-only chat route must not reach the 501 stub.
        final Response response =
            await _call(adapter, 'GET', '/v1/chat/completions');
        expect(response.statusCode, isNot(501));
        expect(response.statusCode, greaterThanOrEqualTo(400));
      });
    });
  });
}
