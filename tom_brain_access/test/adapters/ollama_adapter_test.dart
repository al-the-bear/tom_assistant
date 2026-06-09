// Ollama HTTP adapter — router + no-source / error-shape contract (plan
// item #27).
//
// Drives `OllamaHttpAdapter`'s shelf handler black-box (a synthesised
// `shelf.Request` straight to `handler`, no socket), mirroring the OpenAI
// adapter's E.11 scaffold test. The contract locked here:
//
//   - the two routes (`POST /api/chat`, `POST /api/generate`) dispatch by
//     verb+path;
//   - until a cognition is wired (plan item #29 / boot) a well-formed request
//     answers a wire-shaped `501` in Ollama's bare `{"error": …}` envelope
//     (NOT the OpenAI nested `{"error":{...}}` shape);
//   - a malformed JSON body is a `400` in the same Ollama error shape;
//   - an unknown path/verb returns the Ollama `404` error object.
//
// The success-path wire shapes (NDJSON streaming, non-streaming JSON,
// model→persona) are proven by `ollama_wire_format_conformance_test.dart`,
// which injects an answer source.

import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:test/test.dart';

Future<Response> _call(
  OllamaHttpAdapter adapter,
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

/// Reads the Ollama error string off a response body (`{"error": <message>}`).
Future<Object?> _error(Response response) async =>
    (jsonDecode(await response.readAsString()) as Map<String, Object?>)['error'];

String _chatBody({String? model, bool? stream}) =>
    jsonEncode(<String, Object?>{
      'model': ?model,
      'stream': ?stream,
      'messages': <Object?>[
        <String, Object?>{'role': 'user', 'content': 'hello'},
      ],
    });

void main() {
  group('OllamaHttpAdapter route table', () {
    test('the two routes carry their Ollama paths', () {
      expect(OllamaHttpAdapter.chatPath, '/api/chat');
      expect(OllamaHttpAdapter.generatePath, '/api/generate');
    });

    test('handler resolves an unknown route without throwing', () {
      final OllamaHttpAdapter adapter = OllamaHttpAdapter();
      expect(() => _call(adapter, 'GET', '/api/anything'), returnsNormally);
    });
  });

  group('chat / generate answer 501 until a source is wired', () {
    late OllamaHttpAdapter adapter;
    setUp(() => adapter = OllamaHttpAdapter());

    test('POST /api/chat well-formed, no source → 501 bare-error', () async {
      final Response response = await _call(adapter, 'POST', '/api/chat',
          body: _chatBody(model: 'tom-assistant', stream: false));
      expect(response.statusCode, 501);
      expect(response.headers['content-type'], contains('application/json'));
      // Ollama's error is a bare string, not the OpenAI nested object.
      expect(await _error(response), isA<String>());
    });

    test('POST /api/generate well-formed, no source → 501 bare-error',
        () async {
      final Response response = await _call(adapter, 'POST', '/api/generate',
          body: jsonEncode(<String, Object?>{'prompt': 'hi', 'stream': false}));
      expect(response.statusCode, 501);
      expect(await _error(response), isA<String>());
    });
  });

  group('malformed / unknown requests use the Ollama error shape', () {
    late OllamaHttpAdapter adapter;
    setUp(() => adapter = OllamaHttpAdapter());

    test('a non-JSON chat body → 400 bare-error', () async {
      final Response response =
          await _call(adapter, 'POST', '/api/chat', body: '{not json');
      expect(response.statusCode, 400);
      expect(await _error(response), isA<String>());
    });

    test('a parse-invalid generate body → 400 bare-error', () async {
      // Valid JSON, but missing the required prompt — a parse failure whose
      // message reaches the wire as Ollama's `error` string.
      final Response response = await _call(adapter, 'POST', '/api/generate',
          body: jsonEncode(<String, Object?>{'model': 'tom-assistant'}));
      expect(response.statusCode, 400);
      expect(await _error(response), isA<String>());
    });

    test('an unknown path → 404 bare-error', () async {
      final Response response = await _call(adapter, 'GET', '/api/unknown');
      expect(response.statusCode, 404);
      expect(await _error(response), isA<String>());
    });

    test('wrong verb on a known path is not served by its handler', () async {
      final Response response = await _call(adapter, 'GET', '/api/chat');
      expect(response.statusCode, isNot(501));
      expect(response.statusCode, greaterThanOrEqualTo(400));
    });
  });
}
