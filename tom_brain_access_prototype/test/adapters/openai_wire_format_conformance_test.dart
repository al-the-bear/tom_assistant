// E.18 OpenAI HTTP/SSE adapter — wire-format conformance suite (AC-6).
//
// Where E.13 / E.14 / E.16 / E.17 each proved one *substep's* route in
// isolation, E.18 is the consolidated **wire-format conformance** suite that
// proves AC-6 ("OpenAI wire-format fidelity") across the *whole* adapter,
// driven black-box through its public `handler` only (Q-E.5.2: a synthesised
// `shelf.Request` straight to `handler`, no socket). Per the proto spec § 13
// deliverable for E.18:
//
//   - each OpenAI route's request/response shape conforms to the OpenAI wire
//     format (the complete envelope — every required key, the right `object`
//     discriminator, the right types — not just the one or two fields the
//     owning substep happened to assert);
//   - streaming chunks arrive in order;
//   - non-streaming completes (a full buffered body, not a partial one);
//   - `[DONE]` is the last SSE line.
//
// This suite drives ONE fully-wired adapter — both the `ChatAnswerStream` and
// the `EmbeddingSource` seams injected — i.e. the adapter in its
// boot-complete shape (E.41+), so the success-path wire shapes are exercised
// the way a real client sees them. The no-source `501` discipline and the
// per-substep parse failures keep their own tests; E.18 does not re-prove
// them, it proves the *positive* wire contract holds end-to-end and uniformly.
//
// Distinct from E.53 (OpenAI conformance against the running process over a
// real `HttpClient` + captured OpenAI fixtures): E.18 is the in-process,
// handler-level contract; E.53 is the over-the-socket one. They guard the same
// invariant at two layers.

import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

// --- Fully-wired adapter under conformance test --------------------------

/// The answer the synthetic cognition streams back for every chat request:
/// three ordered increments, the last marked final. Ordering and the final
/// marker are what the SSE / JSON conformance assertions key on.
const List<String> _answerDeltas = <String>['Hel', 'lo, ', 'world'];
const String _answerText = 'Hello, world';

/// A synthetic `ChatAnswerStream`: emits [_answerDeltas] in order, the last
/// chunk marked `isFinal`. Records the requests it was handed so the suite can
/// confirm the parsed request reached the seam unchanged.
class _RecordingAnswerSource {
  final List<ChatCompletionRequest> calls = <ChatCompletionRequest>[];

  Stream<OutboundChunk> stream(ChatCompletionRequest request) {
    calls.add(request);
    return Stream<OutboundChunk>.fromIterable(<OutboundChunk>[
      for (int i = 0; i < _answerDeltas.length; i++)
        OutboundChunk(
          textDelta: _answerDeltas[i],
          isFinal: i == _answerDeltas.length - 1,
          index: i,
        ),
    ]);
  }
}

/// A synthetic `EmbeddingSource`: returns one deterministic 3-float vector per
/// input (`[i+1, i+1, i+1]`) stamped with a fixed substrate model id.
class _RecordingEmbeddingSource {
  static const String modelId = 'nomic-embed-text';
  final List<List<String>> calls = <List<String>>[];

  Future<EmbeddingBatch> embed(List<String> inputs) async {
    calls.add(inputs);
    return EmbeddingBatch(
      modelId: modelId,
      vectors: <List<double>>[
        for (int i = 0; i < inputs.length; i++)
          <double>[(i + 1).toDouble(), (i + 1).toDouble(), (i + 1).toDouble()],
      ],
    );
  }
}

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

/// A well-formed `chat/completions` body with the given [model] / [stream].
String _chatBody({String model = 'tom-assistant', required bool stream}) =>
    jsonEncode(<String, Object?>{
      'model': model,
      'stream': stream,
      'messages': <Object?>[
        <String, Object?>{'role': 'user', 'content': 'hello'},
      ],
    });

/// Decodes a JSON response body into a map.
Future<Map<String, Object?>> _jsonBody(Response response) async =>
    jsonDecode(await response.readAsString()) as Map<String, Object?>;

/// The first `choices[0]` object of a decoded chat payload.
Map<String, Object?> _firstChoice(Map<String, Object?> body) =>
    (body['choices'] as List<Object?>).first as Map<String, Object?>;

/// Splits an SSE body into its individual `data: …\n\n` frames (trailing
/// separators restored, empty trailing segment dropped).
List<String> _frames(String body) => body
    .split('\n\n')
    .where((String s) => s.isNotEmpty)
    .map((String s) => '$s\n\n')
    .toList();

/// Decodes a single `data: {…}` frame's JSON payload.
Map<String, Object?> _framePayload(String frame) =>
    jsonDecode(frame.substring('data: '.length).trim())
        as Map<String, Object?>;

void main() {
  late _RecordingAnswerSource answerSource;
  late _RecordingEmbeddingSource embeddingSource;
  late OpenAiHttpSseAdapter adapter;

  setUp(() {
    answerSource = _RecordingAnswerSource();
    embeddingSource = _RecordingEmbeddingSource();
    adapter = OpenAiHttpSseAdapter(
      answerStream: answerSource.stream,
      embeddingSource: embeddingSource.embed,
    );
  });

  group('E.18 wire-format conformance — POST /v1/chat/completions '
      '(non-streaming)', () {
    test('the full chat.completion envelope conforms to the OpenAI shape',
        () async {
      final Response response = await _call(
        adapter,
        'POST',
        '/v1/chat/completions',
        body: _chatBody(stream: false),
      );

      expect(response.statusCode, 200);
      expect(response.headers['content-type'], contains('application/json'));

      final Map<String, Object?> body = await _jsonBody(response);
      // Top-level required keys + discriminators.
      expect(body['id'], isA<String>());
      expect(body['id'] as String, startsWith('chatcmpl-'));
      expect(body['object'], 'chat.completion');
      expect(body['created'], isA<int>());
      expect(body['model'], 'tom-assistant');

      // choices[] — exactly one buffered choice.
      final List<Object?> choices = body['choices'] as List<Object?>;
      expect(choices, hasLength(1));
      final Map<String, Object?> choice = _firstChoice(body);
      expect(choice['index'], 0);
      expect(choice['finish_reason'], 'stop');

      // The single assistant message carries the WHOLE answer (non-streaming
      // completes — the buffered body is the full text, not a partial).
      final Map<String, Object?> message =
          choice['message'] as Map<String, Object?>;
      expect(message['role'], 'assistant');
      expect(message['content'], _answerText);

      // usage block present with the three OpenAI token fields.
      final Map<String, Object?> usage = body['usage'] as Map<String, Object?>;
      expect(usage['prompt_tokens'], isA<int>());
      expect(usage['completion_tokens'], isA<int>());
      expect(usage['total_tokens'],
          (usage['prompt_tokens'] as int) + (usage['completion_tokens'] as int));
    });

    test('the parsed request reaches the answer seam unchanged', () async {
      await _call(adapter, 'POST', '/v1/chat/completions',
          body: _chatBody(stream: false));
      expect(answerSource.calls, hasLength(1));
      expect(answerSource.calls.single.prompt, 'hello');
      expect(answerSource.calls.single.stream, isFalse);
    });
  });

  group('E.18 wire-format conformance — POST /v1/chat/completions '
      '(streaming)', () {
    test(
        'streaming chunks arrive in order, each a chat.completion.chunk, and '
        '[DONE] is the last SSE line', () async {
      final Response response = await _call(
        adapter,
        'POST',
        '/v1/chat/completions',
        body: _chatBody(stream: true),
      );

      expect(response.statusCode, 200);
      expect(response.headers['content-type'], contains('text/event-stream'));

      final List<String> frames = _frames(await response.readAsString());

      // [DONE] is the final line on the wire, always last.
      expect(frames.last, 'data: [DONE]\n\n');

      // Every non-terminal frame is a well-shaped chat.completion.chunk; the
      // content deltas arrive in the exact order the cognition emitted them.
      final List<String> dataFrames =
          frames.where((String f) => f != 'data: [DONE]\n\n').toList();
      expect(dataFrames, hasLength(_answerDeltas.length));

      final List<String?> contents = <String?>[];
      String? sharedId;
      for (int i = 0; i < dataFrames.length; i++) {
        final Map<String, Object?> payload = _framePayload(dataFrames[i]);
        expect(payload['object'], 'chat.completion.chunk');
        expect(payload['model'], 'tom-assistant');
        expect(payload['id'], isA<String>());
        // The id is repeated identically across every chunk of one completion.
        sharedId ??= payload['id'] as String;
        expect(payload['id'], sharedId);

        final Map<String, Object?> choice =
            (payload['choices'] as List<Object?>).first as Map<String, Object?>;
        expect(choice['index'], 0);
        // Only the final chunk carries finish_reason: "stop".
        expect(choice['finish_reason'], i == dataFrames.length - 1 ? 'stop' : null);
        contents.add(
            (choice['delta'] as Map<String, Object?>)['content'] as String?);
      }
      expect(contents, _answerDeltas);
    });

    test('cache-control: no-cache accompanies the event stream', () async {
      final Response response = await _call(
        adapter,
        'POST',
        '/v1/chat/completions',
        body: _chatBody(stream: true),
      );
      expect(response.headers['cache-control'], 'no-cache');
    });
  });

  group('E.18 wire-format conformance — POST /v1/embeddings', () {
    test('the full embeddings list envelope conforms to the OpenAI shape',
        () async {
      final Response response = await _call(
        adapter,
        'POST',
        '/v1/embeddings',
        body: jsonEncode(<String, Object?>{
          'input': <Object?>['alpha', 'beta'],
          'model': 'text-embedding-3-small',
        }),
      );

      expect(response.statusCode, 200);
      expect(response.headers['content-type'], contains('application/json'));

      final Map<String, Object?> body = await _jsonBody(response);
      expect(body['object'], 'list');
      // The response model echoes the SUBSTRATE model identity, not the
      // request's informational `model` string (proto spec § 5.6).
      expect(body['model'], _RecordingEmbeddingSource.modelId);

      final List<Object?> data = body['data'] as List<Object?>;
      expect(data, hasLength(2));
      for (int i = 0; i < data.length; i++) {
        final Map<String, Object?> item = data[i] as Map<String, Object?>;
        expect(item['object'], 'embedding');
        expect(item['index'], i);
        expect(item['embedding'], isA<List<Object?>>());
      }

      final Map<String, Object?> usage = body['usage'] as Map<String, Object?>;
      expect(usage['prompt_tokens'], isA<int>());
      expect(usage['total_tokens'], usage['prompt_tokens']);
    });
  });

  group('E.18 wire-format conformance — GET /v1/models', () {
    test('the full models-list envelope conforms to the OpenAI shape',
        () async {
      final Response response = await _call(adapter, 'GET', '/v1/models');

      expect(response.statusCode, 200);
      expect(response.headers['content-type'], contains('application/json'));

      final Map<String, Object?> body = await _jsonBody(response);
      expect(body['object'], 'list');

      final List<Object?> data = body['data'] as List<Object?>;
      // Exactly the persona vocabulary, in order.
      expect(
        data.map((Object? e) => (e as Map<String, Object?>)['id']).toList(),
        OpenAiPersonaMapping.knownModels,
      );
      for (final Object? entry in data) {
        final Map<String, Object?> item = entry as Map<String, Object?>;
        expect(item['object'], 'model');
        expect(item['created'], isA<int>());
        expect(item['owned_by'], isA<String>());
      }
    });
  });

  group('E.18 wire-format conformance — cross-route invariants', () {
    test('every JSON route answers application/json; the SSE route answers '
        'text/event-stream', () async {
      final Response chatJson = await _call(adapter, 'POST',
          '/v1/chat/completions', body: _chatBody(stream: false));
      final Response chatSse = await _call(adapter, 'POST',
          '/v1/chat/completions', body: _chatBody(stream: true));
      final Response embeddings = await _call(adapter, 'POST', '/v1/embeddings',
          body: jsonEncode(<String, Object?>{'input': 'x'}));
      final Response models = await _call(adapter, 'GET', '/v1/models');

      expect(chatJson.headers['content-type'], contains('application/json'));
      expect(chatSse.headers['content-type'], contains('text/event-stream'));
      expect(embeddings.headers['content-type'], contains('application/json'));
      expect(models.headers['content-type'], contains('application/json'));
    });

    test('a malformed chat body conforms to the OpenAI 400 error envelope',
        () async {
      final Response response = await _call(
        adapter,
        'POST',
        '/v1/chat/completions',
        body: jsonEncode(<String, Object?>{'model': 'tom-assistant'}),
      );
      expect(response.statusCode, 400);
      final Map<String, Object?> body = await _jsonBody(response);
      final Map<String, Object?> error = body['error'] as Map<String, Object?>;
      // The OpenAI error envelope carries exactly message/type/param/code.
      expect(error.keys.toSet(),
          <String>{'message', 'type', 'param', 'code'});
      expect(error['type'], 'invalid_request_error');
      expect(error['message'], isA<String>());
    });

    test('an unknown route conforms to the OpenAI 404 error envelope',
        () async {
      final Response response = await _call(adapter, 'GET', '/v1/unknown');
      expect(response.statusCode, 404);
      expect(response.headers['content-type'], contains('application/json'));
      final Map<String, Object?> error =
          (await _jsonBody(response))['error'] as Map<String, Object?>;
      expect(error.keys.toSet(),
          <String>{'message', 'type', 'param', 'code'});
      expect(error['type'], 'invalid_request_error');
      expect(error['code'], 'not_found');
      // A non-parameter error carries an explicit null `param`, matching the
      // OpenAI shape.
      expect(error['param'], isNull);
    });
  });
}
