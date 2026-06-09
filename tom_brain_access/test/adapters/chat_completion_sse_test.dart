// E.13 OpenAI chat/completions SSE streaming-response contract test.
//
// Two layers (proto spec § 5.3's deliverable):
//
//   1. `ChatCompletionSseRenderer` as a pure unit — frame shape
//      (`chat.completion.chunk`, `choices[0].delta.content`, `finish_reason`),
//      frame framing (`data: …\n\n`), the terminal `data: [DONE]\n\n`, and
//      stream ordering.
//   2. The same rendering black-box through the adapter handler (Q-E.5.2: a
//      synthesised `shelf.Request` passed straight to `handler`, no socket):
//      a streaming request with an injected chunk source → a
//      `text/event-stream` body whose frames arrive in order and end with
//      `[DONE]`; a streaming request with no source → 501.
//
// The non-streaming JSON body is E.14's concern, asserted in its own test;
// this test deliberately does not anticipate E.14+ (JSON body, persona,
// embeddings, models) or E.39/E.40 (backpressure).

import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

/// A fixed renderer so frame fields are deterministic across assertions.
ChatCompletionSseRenderer _renderer() => const ChatCompletionSseRenderer(
      id: 'chatcmpl-test',
      model: 'tom-assistant',
      created: 1700000000,
    );

/// Decodes a single `data: {…}` frame's JSON payload.
Map<String, Object?> _payload(String frame) {
  final String data = frame.substring('data: '.length).trim();
  return jsonDecode(data) as Map<String, Object?>;
}

/// The first `choices[0]` object of a decoded chunk payload.
Map<String, Object?> _choice(Map<String, Object?> payload) =>
    (payload['choices'] as List<Object?>).first as Map<String, Object?>;

/// Splits an SSE body into its individual `data: …\n\n` frames, with the
/// trailing separators stripped. A `[DONE]` line is kept verbatim.
List<String> _frames(String body) => body
    .split('\n\n')
    .where((String s) => s.isNotEmpty)
    .map((String s) => '$s\n\n')
    .toList();

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

/// A well-formed chat-completions body with the given [stream] flag.
String _chatBody({required bool stream}) => jsonEncode(<String, Object?>{
      'model': 'tom-assistant',
      'stream': stream,
      'messages': <Object?>[
        <String, Object?>{'role': 'user', 'content': 'hello'},
      ],
    });

void main() {
  group('ChatCompletionSseRenderer (E.13) — frame shape', () {
    test('a content chunk renders a chat.completion.chunk data frame', () {
      final String frame =
          _renderer().frameFor(OutboundChunk(textDelta: 'Hello'));

      expect(frame, startsWith('data: '));
      expect(frame, endsWith('\n\n'));

      final Map<String, Object?> payload = _payload(frame);
      expect(payload['id'], 'chatcmpl-test');
      expect(payload['object'], 'chat.completion.chunk');
      expect(payload['created'], 1700000000);
      expect(payload['model'], 'tom-assistant');

      final Map<String, Object?> choice = _choice(payload);
      expect(choice['index'], 0);
      expect(choice['finish_reason'], isNull);
      expect((choice['delta'] as Map<String, Object?>)['content'], 'Hello');
    });

    test('a final chunk sets finish_reason to "stop"', () {
      final Map<String, Object?> choice = _choice(_payload(
          _renderer().frameFor(OutboundChunk(textDelta: '!', isFinal: true))));
      expect(choice['finish_reason'], 'stop');
      expect((choice['delta'] as Map<String, Object?>)['content'], '!');
    });

    test('an empty final chunk renders an empty delta object', () {
      final Map<String, Object?> choice = _choice(_payload(_renderer()
          .frameFor(OutboundChunk(textDelta: '', isFinal: true))));
      expect(choice['delta'], isEmpty);
      expect(choice['finish_reason'], 'stop');
    });

    test('forModel mints a chatcmpl- id and epoch-seconds created', () {
      final ChatCompletionSseRenderer renderer =
          ChatCompletionSseRenderer.forModel(
        'tom-assistant',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      expect(renderer.id, startsWith('chatcmpl-'));
      expect(renderer.model, 'tom-assistant');
      expect(renderer.created, 1700000000);
    });
  });

  group('ChatCompletionSseRenderer (E.13) — stream rendering', () {
    test('emits one frame per chunk in order, then [DONE] last', () async {
      final Stream<OutboundChunk> chunks = Stream<OutboundChunk>.fromIterable(
        <OutboundChunk>[
          OutboundChunk(textDelta: 'Hel'),
          OutboundChunk(textDelta: 'lo'),
          OutboundChunk(textDelta: '!', isFinal: true),
        ],
      );

      final List<String> frames = await _renderer().render(chunks).toList();

      expect(frames, hasLength(4)); // 3 chunks + [DONE]
      expect(frames.last, ChatCompletionSseRenderer.doneFrame);
      expect(frames.last, 'data: [DONE]\n\n');

      final List<String?> contents = frames
          .take(3)
          .map((String f) =>
              (_choice(_payload(f))['delta'] as Map<String, Object?>)['content']
                  as String?)
          .toList();
      expect(contents, <String>['Hel', 'lo', '!']);
    });

    test('terminates with [DONE] even without a final-marked chunk',
        () async {
      final List<String> frames = await _renderer()
          .render(Stream<OutboundChunk>.fromIterable(
            <OutboundChunk>[OutboundChunk(textDelta: 'x')],
          ))
          .toList();
      expect(frames, hasLength(2));
      expect(frames.last, ChatCompletionSseRenderer.doneFrame);
    });
  });

  group('ChatCompletionSseRenderer — first-chunk delta.role (Q-E.51.2)', () {
    test('frameFor stamps role:"assistant" on the delta only when firstChunk',
        () {
      final Map<String, Object?> first = _choice(_payload(
          _renderer().frameFor(OutboundChunk(textDelta: 'Hi'),
              firstChunk: true)))['delta'] as Map<String, Object?>;
      expect(first['role'], 'assistant');
      expect(first['content'], 'Hi');

      final Map<String, Object?> later = _choice(_payload(
          _renderer().frameFor(OutboundChunk(textDelta: 'Hi'))))['delta']
          as Map<String, Object?>;
      expect(later.containsKey('role'), isFalse);
      expect(later['content'], 'Hi');
    });

    test('a first chunk that is also final carries both role and finish_reason',
        () {
      final Map<String, Object?> choice = _choice(_payload(_renderer()
          .frameFor(OutboundChunk(textDelta: 'only', isFinal: true),
              firstChunk: true)));
      expect((choice['delta'] as Map<String, Object?>)['role'], 'assistant');
      expect(choice['finish_reason'], 'stop');
    });

    test('render stamps role on the first frame only', () async {
      final List<String> frames = await _renderer()
          .render(Stream<OutboundChunk>.fromIterable(<OutboundChunk>[
            OutboundChunk(textDelta: 'Hel'),
            OutboundChunk(textDelta: 'lo'),
            OutboundChunk(textDelta: '!', isFinal: true),
          ]))
          .toList();

      final List<bool> hasRole = frames
          .where((String f) => f != ChatCompletionSseRenderer.doneFrame)
          .map((String f) => (_choice(_payload(f))['delta']
              as Map<String, Object?>)
              .containsKey('role'))
          .toList();
      expect(hasRole, <bool>[true, false, false]);
    });
  });

  group('OpenAiHttpSseAdapter streaming response (E.13)', () {
    test(
        'POST /v1/chat/completions with stream:true and an injected source '
        '→ 200 text/event-stream, ordered frames, [DONE] last', () async {
      final OpenAiHttpSseAdapter adapter = OpenAiHttpSseAdapter(
        answerStream: (ChatCompletionRequest request) =>
            Stream<OutboundChunk>.fromIterable(<OutboundChunk>[
          OutboundChunk(textDelta: 'one '),
          OutboundChunk(textDelta: 'two', isFinal: true),
        ]),
      );

      final Response response =
          await _call(adapter, 'POST', '/v1/chat/completions',
              body: _chatBody(stream: true));

      expect(response.statusCode, 200);
      expect(response.headers['content-type'], contains('text/event-stream'));

      final List<String> frames = _frames(await response.readAsString());
      expect(frames.last, 'data: [DONE]\n\n');

      final List<String?> contents = frames
          .where((String f) => f != 'data: [DONE]\n\n')
          .map((String f) =>
              (_choice(_payload(f))['delta'] as Map<String, Object?>)['content']
                  as String?)
          .toList();
      expect(contents, <String>['one ', 'two']);
    });

    test('streaming request with no injected source → 501', () async {
      final OpenAiHttpSseAdapter adapter = OpenAiHttpSseAdapter();
      final Response response = await _call(
          adapter, 'POST', '/v1/chat/completions',
          body: _chatBody(stream: true));
      expect(response.statusCode, 501);
      final Map<String, Object?> error =
          (jsonDecode(await response.readAsString())
              as Map<String, Object?>)['error'] as Map<String, Object?>;
      expect(error['code'], 'not_implemented');
    });
  });
}
