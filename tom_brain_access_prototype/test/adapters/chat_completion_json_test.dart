// E.14 OpenAI chat/completions non-streaming (JSON) response contract test.
//
// Two layers (proto spec § 5.4's deliverable):
//
//   1. `ChatCompletionJsonRenderer` as a pure unit — body shape
//      (`chat.completion`, `choices[0].message.{role,content}`,
//      `finish_reason: "stop"`), chunk buffering (concatenation in order,
//      `isFinal` ignored for buffering), the `usage` block + its char/4
//      token estimate, and `forModel` id/created minting.
//   2. The same rendering black-box through the adapter handler (Q-E.5.2: a
//      synthesised `shelf.Request` passed straight to `handler`, no socket):
//      a non-streaming request with an injected chunk source → 200
//      `application/json` whose body is the buffered `chat.completion`; a
//      non-streaming request with no source → 501.
//
// The test deliberately does not anticipate E.15+ (persona, embeddings,
// models) or E.39/E.40 (backpressure). The streaming SSE path is E.13's
// test.

import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

/// A fixed renderer so body fields are deterministic across assertions.
ChatCompletionJsonRenderer _renderer() => const ChatCompletionJsonRenderer(
      id: 'chatcmpl-test',
      model: 'tom-assistant',
      created: 1700000000,
    );

/// The first `choices[0]` object of a decoded completion body.
Map<String, Object?> _choice(Map<String, Object?> body) =>
    (body['choices'] as List<Object?>).first as Map<String, Object?>;

/// The `usage` object of a decoded completion body.
Map<String, Object?> _usage(Map<String, Object?> body) =>
    body['usage'] as Map<String, Object?>;

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

/// A well-formed chat-completions body with the given [stream] flag and a
/// fixed prompt.
String _chatBody({required bool stream}) => jsonEncode(<String, Object?>{
      'model': 'tom-assistant',
      'stream': stream,
      'messages': <Object?>[
        <String, Object?>{'role': 'user', 'content': 'hello'},
      ],
    });

void main() {
  group('ChatCompletionJsonRenderer (E.14) — body shape', () {
    test('builds a chat.completion body with a single assistant message', () {
      final Map<String, Object?> body =
          _renderer().bodyMap(prompt: 'hi', content: 'Hello there');

      expect(body['id'], 'chatcmpl-test');
      expect(body['object'], 'chat.completion');
      expect(body['created'], 1700000000);
      expect(body['model'], 'tom-assistant');

      final Map<String, Object?> choice = _choice(body);
      expect(choice['index'], 0);
      expect(choice['finish_reason'], 'stop');

      final Map<String, Object?> message =
          choice['message'] as Map<String, Object?>;
      expect(message['role'], 'assistant');
      expect(message['content'], 'Hello there');
    });

    test('usage carries char/4 token estimates summing to the total', () {
      // prompt "12345678" → ceil(8/4) = 2; content "abcdefghij" → ceil(10/4) = 3.
      final Map<String, Object?> usage = _usage(
        _renderer().bodyMap(prompt: '12345678', content: 'abcdefghij'),
      );
      expect(usage['prompt_tokens'], 2);
      expect(usage['completion_tokens'], 3);
      expect(usage['total_tokens'], 5);
    });

    test('empty content yields zero completion tokens and an empty message',
        () {
      final Map<String, Object?> body =
          _renderer().bodyMap(prompt: '', content: '');
      final Map<String, Object?> usage = _usage(body);
      expect(usage['prompt_tokens'], 0);
      expect(usage['completion_tokens'], 0);
      expect(usage['total_tokens'], 0);
      expect(
        (_choice(body)['message'] as Map<String, Object?>)['content'],
        '',
      );
    });

    test('estimateTokens is ceil(length/4) with empty counting as zero', () {
      expect(ChatCompletionJsonRenderer.estimateTokens(''), 0);
      expect(ChatCompletionJsonRenderer.estimateTokens('a'), 1);
      expect(ChatCompletionJsonRenderer.estimateTokens('abcd'), 1);
      expect(ChatCompletionJsonRenderer.estimateTokens('abcde'), 2);
    });

    test('forModel mints a chatcmpl- id and epoch-seconds created', () {
      final ChatCompletionJsonRenderer renderer =
          ChatCompletionJsonRenderer.forModel(
        'tom-assistant',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      expect(renderer.id, startsWith('chatcmpl-'));
      expect(renderer.model, 'tom-assistant');
      expect(renderer.created, 1700000000);
    });
  });

  group('ChatCompletionJsonRenderer (E.14) — chunk buffering', () {
    test('concatenates chunk text in order into the message content',
        () async {
      final Stream<OutboundChunk> chunks = Stream<OutboundChunk>.fromIterable(
        <OutboundChunk>[
          OutboundChunk(textDelta: 'Hel'),
          OutboundChunk(textDelta: 'lo, '),
          OutboundChunk(textDelta: 'world', isFinal: true),
        ],
      );

      final Map<String, Object?> body = jsonDecode(
        await _renderer().render(prompt: 'hi', chunks: chunks),
      ) as Map<String, Object?>;

      expect(
        (_choice(body)['message'] as Map<String, Object?>)['content'],
        'Hello, world',
      );
      expect(_choice(body)['finish_reason'], 'stop');
    });

    test('buffers an answer with no final-marked chunk', () async {
      final Map<String, Object?> body = jsonDecode(
        await _renderer().render(
          prompt: 'hi',
          chunks: Stream<OutboundChunk>.fromIterable(
            <OutboundChunk>[OutboundChunk(textDelta: 'x')],
          ),
        ),
      ) as Map<String, Object?>;
      expect(
        (_choice(body)['message'] as Map<String, Object?>)['content'],
        'x',
      );
      expect(_choice(body)['finish_reason'], 'stop');
    });

    test('an empty chunk stream yields an empty answer', () async {
      final Map<String, Object?> body = jsonDecode(
        await _renderer()
            .render(prompt: 'hi', chunks: const Stream<OutboundChunk>.empty()),
      ) as Map<String, Object?>;
      expect(
        (_choice(body)['message'] as Map<String, Object?>)['content'],
        '',
      );
    });
  });

  group('OpenAiHttpSseAdapter non-streaming response (E.14)', () {
    test(
        'POST /v1/chat/completions with stream:false and an injected source '
        '→ 200 application/json chat.completion body', () async {
      final OpenAiHttpSseAdapter adapter = OpenAiHttpSseAdapter(
        answerStream: (ChatCompletionRequest request) =>
            Stream<OutboundChunk>.fromIterable(<OutboundChunk>[
          OutboundChunk(textDelta: 'one '),
          OutboundChunk(textDelta: 'two', isFinal: true),
        ]),
      );

      final Response response = await _call(
          adapter, 'POST', '/v1/chat/completions',
          body: _chatBody(stream: false));

      expect(response.statusCode, 200);
      expect(response.headers['content-type'], contains('application/json'));

      final Map<String, Object?> body =
          jsonDecode(await response.readAsString()) as Map<String, Object?>;
      expect(body['object'], 'chat.completion');
      expect(body['model'], 'tom-assistant');
      expect(
        (_choice(body)['message'] as Map<String, Object?>)['content'],
        'one two',
      );
      expect(_choice(body)['finish_reason'], 'stop');
      // usage present and totals add up.
      final Map<String, Object?> usage = _usage(body);
      expect(usage['total_tokens'],
          (usage['prompt_tokens'] as int) + (usage['completion_tokens'] as int));
      expect(usage['completion_tokens'], greaterThan(0));
    });

    test('non-streaming request with no injected source → 501', () async {
      final OpenAiHttpSseAdapter adapter = OpenAiHttpSseAdapter();
      final Response response = await _call(
          adapter, 'POST', '/v1/chat/completions',
          body: _chatBody(stream: false));
      expect(response.statusCode, 501);
      final Map<String, Object?> error =
          (jsonDecode(await response.readAsString())
              as Map<String, Object?>)['error'] as Map<String, Object?>;
      expect(error['code'], 'not_implemented');
    });

    test('the response model echoes the request model', () async {
      final OpenAiHttpSseAdapter adapter = OpenAiHttpSseAdapter(
        answerStream: (_) => Stream<OutboundChunk>.fromIterable(
          <OutboundChunk>[OutboundChunk(textDelta: 'hi', isFinal: true)],
        ),
      );
      final Response response = await _call(
        adapter,
        'POST',
        '/v1/chat/completions',
        body: jsonEncode(<String, Object?>{
          'model': 'tom-assistant:terse',
          'stream': false,
          'messages': <Object?>[
            <String, Object?>{'role': 'user', 'content': 'hello'},
          ],
        }),
      );
      final Map<String, Object?> body =
          jsonDecode(await response.readAsString()) as Map<String, Object?>;
      expect(body['model'], 'tom-assistant:terse');
    });
  });
}
