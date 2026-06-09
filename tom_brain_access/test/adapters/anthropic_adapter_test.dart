// Anthropic Messages HTTP adapter — router + no-source / error-shape contract
// (plan item #28).
//
// Drives `AnthropicHttpAdapter`'s shelf handler black-box (a synthesised
// `shelf.Request` straight to `handler`, no socket), mirroring the OpenAI /
// Ollama adapter scaffold tests. The contract locked here:
//
//   - the single route (`POST /v1/messages`) dispatches by verb+path;
//   - until a cognition is wired (plan item #29 / boot) a well-formed request
//     answers a wire-shaped `501` in Anthropic's nested
//     `{"type":"error","error":{"type":"api_error","message":…}}` envelope
//     (NOT the OpenAI `{"error":{...,"code"}}` shape, NOT Ollama's bare
//     `{"error":<msg>}`);
//   - a malformed JSON body is a `400` `invalid_request_error`;
//   - a parse-invalid body (missing messages) is a `400` invalid_request_error;
//   - an unknown path/verb returns the Anthropic `404` not_found_error.
//
// The success-path wire shapes (SSE event sequence, non-streaming Message
// object, model→persona) are proven by
// `anthropic_wire_format_conformance_test.dart`, which injects an answer
// source.

import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:test/test.dart';

Future<Response> _call(
  AnthropicHttpAdapter adapter,
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

/// Reads the Anthropic error object off a response body
/// (`{"type":"error","error":{"type":…,"message":…}}`).
Future<Map<String, Object?>> _error(Response response) async {
  final Map<String, Object?> body =
      jsonDecode(await response.readAsString()) as Map<String, Object?>;
  expect(body['type'], 'error', reason: 'Anthropic errors carry type:error');
  return body['error'] as Map<String, Object?>;
}

String _messagesBody({String? model, bool? stream}) =>
    jsonEncode(<String, Object?>{
      'model': ?model,
      'stream': ?stream,
      'max_tokens': 1024,
      'messages': <Object?>[
        <String, Object?>{'role': 'user', 'content': 'hello'},
      ],
    });

void main() {
  group('AnthropicHttpAdapter route table', () {
    test('the messages route carries its Anthropic path', () {
      expect(AnthropicHttpAdapter.messagesPath, '/v1/messages');
    });

    test('handler resolves an unknown route without throwing', () {
      final AnthropicHttpAdapter adapter = AnthropicHttpAdapter();
      expect(() => _call(adapter, 'GET', '/v1/anything'), returnsNormally);
    });
  });

  group('messages answers 501 until a source is wired', () {
    late AnthropicHttpAdapter adapter;
    setUp(() => adapter = AnthropicHttpAdapter());

    test('POST /v1/messages well-formed, no source → 501 api_error', () async {
      final Response response = await _call(adapter, 'POST', '/v1/messages',
          body: _messagesBody(model: 'tom-assistant', stream: false));
      expect(response.statusCode, 501);
      expect(response.headers['content-type'], contains('application/json'));
      final Map<String, Object?> error = await _error(response);
      expect(error['type'], 'api_error');
      expect(error['message'], isA<String>());
    });
  });

  group('malformed / unknown requests use the Anthropic error shape', () {
    late AnthropicHttpAdapter adapter;
    setUp(() => adapter = AnthropicHttpAdapter());

    test('a non-JSON body → 400 invalid_request_error', () async {
      final Response response =
          await _call(adapter, 'POST', '/v1/messages', body: '{not json');
      expect(response.statusCode, 400);
      final Map<String, Object?> error = await _error(response);
      expect(error['type'], 'invalid_request_error');
      expect(error['message'], isA<String>());
    });

    test('a parse-invalid body (missing messages) → 400 '
        'invalid_request_error', () async {
      final Response response = await _call(adapter, 'POST', '/v1/messages',
          body: jsonEncode(<String, Object?>{'model': 'tom-assistant'}));
      expect(response.statusCode, 400);
      expect((await _error(response))['type'], 'invalid_request_error');
    });

    test('an unknown path → 404 not_found_error', () async {
      final Response response = await _call(adapter, 'GET', '/v1/unknown');
      expect(response.statusCode, 404);
      expect((await _error(response))['type'], 'not_found_error');
    });

    test('wrong verb on a known path is not served by its handler', () async {
      final Response response = await _call(adapter, 'GET', '/v1/messages');
      expect(response.statusCode, isNot(501));
      expect(response.statusCode, greaterThanOrEqualTo(400));
    });
  });
}
