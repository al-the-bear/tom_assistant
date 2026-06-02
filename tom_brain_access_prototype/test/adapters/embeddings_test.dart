// E.16 OpenAI `/v1/embeddings` passthrough — request parsing, response
// rendering, and the adapter route wired against an injected `EmbeddingSource`
// seam.
//
// Two layers, mirroring the E.14 / E.15 tests:
//   1. Pure unit cases over `EmbeddingsRequest.parse` and
//      `EmbeddingsResponseRenderer` — no socket, no adapter.
//   2. Black-box cases through the adapter handler (Q-E.5.2: a synthesised
//      `shelf.Request` straight to `handler`, no socket), with a synthetic
//      `EmbeddingSource` injected so the rendered OpenAI list body can be
//      asserted; and a no-source adapter to assert the 501 discipline.

import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

/// Drives [adapter] with a synthesised POST and returns the response.
Future<Response> _post(
  OpenAiHttpSseAdapter adapter,
  String path, {
  required String body,
}) async {
  final Request request = Request(
    'POST',
    Uri.parse('http://localhost$path'),
    body: body,
  );
  return await adapter.handler(request);
}

/// A synthetic embedding source: returns a deterministic unit-length-ish
/// vector per input (the i-th input gets `[i+1, i+1, i+1]`), stamped with a
/// fixed model id. Records the inputs it was asked to embed.
class _RecordingEmbeddingSource {
  static const String modelId = 'nomic-embed-text';
  final List<List<String>> calls = <List<String>>[];

  Future<EmbeddingBatch> embed(List<String> inputs) async {
    calls.add(inputs);
    final List<List<double>> vectors = <List<double>>[
      for (int i = 0; i < inputs.length; i++)
        <double>[(i + 1).toDouble(), (i + 1).toDouble(), (i + 1).toDouble()],
    ];
    return EmbeddingBatch(vectors: vectors, modelId: modelId);
  }
}

void main() {
  group('EmbeddingsRequest.parse (E.16 — pure)', () {
    test('a bare string input becomes a single-element input list', () {
      final result = EmbeddingsRequest.parse(<String, Object?>{
        'input': 'hello world',
        'model': 'text-embedding-3-small',
      });
      final EmbeddingsRequest request =
          (result as Ok<EmbeddingsRequest, EmbeddingsParseError>).value;
      expect(request.inputs, <String>['hello world']);
      expect(request.model, 'text-embedding-3-small');
    });

    test('an array of strings is preserved in order', () {
      final result = EmbeddingsRequest.parse(<String, Object?>{
        'input': <Object?>['a', 'b', 'c'],
      });
      final EmbeddingsRequest request =
          (result as Ok<EmbeddingsRequest, EmbeddingsParseError>).value;
      expect(request.inputs, <String>['a', 'b', 'c']);
      expect(request.model, isNull);
    });

    test('encoding_format: float is accepted', () {
      final result = EmbeddingsRequest.parse(<String, Object?>{
        'input': 'x',
        'encoding_format': 'float',
      });
      expect(result, isA<Ok<EmbeddingsRequest, EmbeddingsParseError>>());
    });

    test('a non-object body → invalid_body', () {
      final result = EmbeddingsRequest.parse(<Object?>['not', 'an', 'object']);
      final EmbeddingsParseError error =
          (result as Err<EmbeddingsRequest, EmbeddingsParseError>).error;
      expect(error.code, 'invalid_body');
    });

    test('a missing input → missing_input', () {
      final result =
          EmbeddingsRequest.parse(<String, Object?>{'model': 'x'});
      final EmbeddingsParseError error =
          (result as Err<EmbeddingsRequest, EmbeddingsParseError>).error;
      expect(error.code, 'missing_input');
      expect(error.param, 'input');
    });

    test('an empty string input → invalid_input', () {
      final result =
          EmbeddingsRequest.parse(<String, Object?>{'input': '   '});
      final EmbeddingsParseError error =
          (result as Err<EmbeddingsRequest, EmbeddingsParseError>).error;
      expect(error.code, 'invalid_input');
      expect(error.param, 'input');
    });

    test('an empty array input → invalid_input', () {
      final result =
          EmbeddingsRequest.parse(<String, Object?>{'input': <Object?>[]});
      final EmbeddingsParseError error =
          (result as Err<EmbeddingsRequest, EmbeddingsParseError>).error;
      expect(error.code, 'invalid_input');
    });

    test('token-id (integer-array) input is rejected → invalid_input', () {
      final result = EmbeddingsRequest.parse(<String, Object?>{
        'input': <Object?>[1, 2, 3],
      });
      final EmbeddingsParseError error =
          (result as Err<EmbeddingsRequest, EmbeddingsParseError>).error;
      expect(error.code, 'invalid_input');
    });

    test('a non-string model → invalid_model', () {
      final result = EmbeddingsRequest.parse(<String, Object?>{
        'input': 'x',
        'model': 42,
      });
      final EmbeddingsParseError error =
          (result as Err<EmbeddingsRequest, EmbeddingsParseError>).error;
      expect(error.code, 'invalid_model');
      expect(error.param, 'model');
    });

    test('encoding_format: base64 is rejected → invalid_encoding_format', () {
      final result = EmbeddingsRequest.parse(<String, Object?>{
        'input': 'x',
        'encoding_format': 'base64',
      });
      final EmbeddingsParseError error =
          (result as Err<EmbeddingsRequest, EmbeddingsParseError>).error;
      expect(error.code, 'invalid_encoding_format');
      expect(error.param, 'encoding_format');
    });
  });

  group('EmbeddingsResponseRenderer (E.16 — pure)', () {
    test('renders the OpenAI list shape with one item per input', () {
      const renderer = EmbeddingsResponseRenderer();
      final Map<String, Object?> body = renderer.bodyMap(
        inputs: <String>['aaaa', 'bbbb'],
        batch: const EmbeddingBatch(
          vectors: <List<double>>[
            <double>[0.1, 0.2],
            <double>[0.3, 0.4],
          ],
          modelId: 'nomic-embed-text',
        ),
      );
      expect(body['object'], 'list');
      expect(body['model'], 'nomic-embed-text');
      final List<Object?> data = body['data'] as List<Object?>;
      expect(data.length, 2);
      final Map<String, Object?> first = data[0] as Map<String, Object?>;
      expect(first['object'], 'embedding');
      expect(first['index'], 0);
      expect(first['embedding'], <double>[0.1, 0.2]);
      expect((data[1] as Map<String, Object?>)['index'], 1);
      final Map<String, Object?> usage = body['usage'] as Map<String, Object?>;
      // char/4 of 'aaaa' + 'bbbb' = 1 + 1 = 2; total == prompt (no completion).
      expect(usage['prompt_tokens'], 2);
      expect(usage['total_tokens'], 2);
      expect(usage.containsKey('completion_tokens'), isFalse);
    });

    test('a vector-count mismatch is a programming error → ArgumentError', () {
      const renderer = EmbeddingsResponseRenderer();
      expect(
        () => renderer.bodyMap(
          inputs: <String>['only one'],
          batch: const EmbeddingBatch(
            vectors: <List<double>>[
              <double>[1],
              <double>[2],
            ],
            modelId: 'm',
          ),
        ),
        throwsArgumentError,
      );
    });
  });

  group('OpenAiHttpSseAdapter /v1/embeddings (E.16 — black-box)', () {
    test('a well-formed request with an injected source renders the body',
        () async {
      final _RecordingEmbeddingSource source = _RecordingEmbeddingSource();
      final OpenAiHttpSseAdapter adapter =
          OpenAiHttpSseAdapter(embeddingSource: source.embed);

      final Response response = await _post(
        adapter,
        '/v1/embeddings',
        body: jsonEncode(<String, Object?>{
          'input': <Object?>['first', 'second'],
          'model': 'text-embedding-3-small',
        }),
      );

      expect(response.statusCode, 200);
      expect(response.headers['content-type'], contains('application/json'));
      final Map<String, Object?> body =
          jsonDecode(await response.readAsString()) as Map<String, Object?>;
      expect(body['object'], 'list');
      // Response model echoes the SUBSTRATE model identity, not the request's.
      expect(body['model'], 'nomic-embed-text');
      final List<Object?> data = body['data'] as List<Object?>;
      expect(data.length, 2);
      expect((data[0] as Map<String, Object?>)['embedding'],
          <double>[1, 1, 1]);
      expect((data[1] as Map<String, Object?>)['index'], 1);
      // The source saw the parsed inputs, in order.
      expect(source.calls, <List<String>>[
        <String>['first', 'second'],
      ]);
    });

    test('a malformed body → 400 invalid_request_error (source untouched)',
        () async {
      final _RecordingEmbeddingSource source = _RecordingEmbeddingSource();
      final OpenAiHttpSseAdapter adapter =
          OpenAiHttpSseAdapter(embeddingSource: source.embed);

      final Response response = await _post(
        adapter,
        '/v1/embeddings',
        body: jsonEncode(<String, Object?>{'model': 'x'}), // no input
      );

      expect(response.statusCode, 400);
      final Map<String, Object?> error =
          (jsonDecode(await response.readAsString())
              as Map<String, Object?>)['error'] as Map<String, Object?>;
      expect(error['type'], 'invalid_request_error');
      expect(error['code'], 'missing_input');
      expect(source.calls, isEmpty);
    });

    test('a well-formed request with no source wired → 501', () async {
      final OpenAiHttpSseAdapter adapter = OpenAiHttpSseAdapter();
      final Response response = await _post(
        adapter,
        '/v1/embeddings',
        body: jsonEncode(<String, Object?>{'input': 'hello'}),
      );
      expect(response.statusCode, 501);
      final Map<String, Object?> error =
          (jsonDecode(await response.readAsString())
              as Map<String, Object?>)['error'] as Map<String, Object?>;
      expect(error['type'], 'not_implemented');
      expect(error['code'], 'not_implemented');
    });
  });
}
