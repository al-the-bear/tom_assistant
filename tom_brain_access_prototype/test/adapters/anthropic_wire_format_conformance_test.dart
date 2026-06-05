// Anthropic Messages HTTP adapter — wire-format conformance / Verify suite
// (plan item #28).
//
// The #28 *Verify* — "an Anthropic-SDK-shaped client receives a valid streamed
// message" — proven in-process. Where `anthropic_adapter_test.dart` locks the
// router / no-source / error-shape contract (the *negative* surface), this
// suite drives ONE fully-wired `AnthropicHttpAdapter` (a synthetic
// `AnthropicAnswerStream` injected, i.e. the adapter in its boot-complete
// shape, plan item #29+) black-box through its public `handler` only — a
// synthesised `shelf.Request` straight to `handler`, no socket — and proves
// the *positive* Anthropic wire contract end-to-end:
//
//   - the streaming SSE event sequence an Anthropic SDK consumes
//     (`message_start` → `content_block_start` → `content_block_delta` × N →
//     `content_block_stop` → `message_delta` → `message_stop`), named events,
//     ordered text deltas, NO `[DONE]` sentinel, content-type
//     `text/event-stream`;
//   - the non-streaming single Message object a `stream: false` client
//     receives: one `content[0]` text block carrying the FULL buffered answer,
//     content-type `application/json`;
//   - `model` → persona stamping (a known id round-trips; an unknown / absent
//     id normalises to `tom-assistant`, AC-5);
//   - that the parsed request reaches the answer seam unchanged.
//
// This mirrors the OpenAI adapter's E.18 conformance suite (the OpenAI-SSE
// analogue) and the Ollama #27 conformance suite (the NDJSON analogue); the
// three guard the same invariant in their respective wire dialects.

import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

// --- Fully-wired adapter under conformance test --------------------------

/// The answer the synthetic cognition streams back for every request: three
/// ordered increments, the last marked final.
const List<String> _answerDeltas = <String>['Hel', 'lo, ', 'world'];
const String _answerText = 'Hello, world';

/// A synthetic `AnthropicAnswerStream`: emits [_answerDeltas] in order, the
/// last chunk marked `isFinal`. Records the requests it was handed so the
/// suite can confirm the parsed request reached the seam unchanged.
class _RecordingAnswerSource {
  final List<AnthropicRequest> calls = <AnthropicRequest>[];

  Stream<OutboundChunk> stream(AnthropicRequest request) {
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

Future<Response> _call(
  AnthropicHttpAdapter adapter,
  Object body,
) async {
  final Request request = Request(
    'POST',
    Uri.parse('http://localhost/v1/messages'),
    body: jsonEncode(body),
  );
  return await adapter.handler(request);
}

/// One decoded SSE frame: its `event:` name and its `data:` JSON object.
typedef _Frame = ({String event, Map<String, Object?> data});

/// Splits an SSE body into its `event: <name>\ndata: <json>\n\n` frames.
List<_Frame> _frames(String body) {
  final List<_Frame> frames = <_Frame>[];
  for (final String block in body.split('\n\n')) {
    if (block.trim().isEmpty) continue;
    String? event;
    String? data;
    for (final String line in block.split('\n')) {
      if (line.startsWith('event: ')) {
        event = line.substring('event: '.length);
      } else if (line.startsWith('data: ')) {
        data = line.substring('data: '.length);
      }
    }
    frames.add((
      event: event!,
      data: jsonDecode(data!) as Map<String, Object?>,
    ));
  }
  return frames;
}

void main() {
  late _RecordingAnswerSource source;
  late AnthropicHttpAdapter adapter;

  setUp(() {
    source = _RecordingAnswerSource();
    adapter = AnthropicHttpAdapter(answerStream: source.stream);
  });

  group('streaming SSE — an Anthropic SDK client receives a streamed message',
      () {
    test('POST /v1/messages streams the canonical event sequence', () async {
      final Response response = await _call(adapter, <String, Object?>{
        'model': 'tom-assistant',
        'stream': true,
        'max_tokens': 1024,
        'messages': <Object?>[
          <String, Object?>{'role': 'user', 'content': 'hello'},
        ],
      });

      expect(response.statusCode, 200);
      expect(response.headers['content-type'], contains('text/event-stream'));

      final String rawBody = await response.readAsString();
      final List<_Frame> frames = _frames(rawBody);

      expect(
        frames.map((_Frame f) => f.event).toList(),
        <String>[
          'message_start',
          'content_block_start',
          'content_block_delta',
          'content_block_delta',
          'content_block_delta',
          'content_block_stop',
          'message_delta',
          'message_stop',
        ],
      );

      // message_start stamps the resolved model + a msg_ id.
      final Map<String, Object?> message =
          frames.first.data['message'] as Map<String, Object?>;
      expect(message['model'], 'tom-assistant');
      expect(message['id'], startsWith('msg_'));

      // The content deltas ride in order and reassemble to the full answer.
      final List<_Frame> deltas = frames
          .where((_Frame f) => f.event == 'content_block_delta')
          .toList();
      final String streamed = deltas
          .map((_Frame f) =>
              (f.data['delta'] as Map<String, Object?>)['text'] as String)
          .join();
      expect(streamed, _answerText);

      // No `[DONE]` sentinel; message_stop terminates.
      expect(rawBody.contains('[DONE]'), isFalse);
      expect(frames.last.event, 'message_stop');

      // The parsed request reached the seam unchanged.
      expect(source.calls, hasLength(1));
      expect(source.calls.single.prompt, 'hello');
      expect(source.calls.single.stream, isTrue);
    });
  });

  group('non-streaming JSON — a stream:false client receives one Message', () {
    test('POST /v1/messages buffers the full answer into one Message object',
        () async {
      final Response response = await _call(adapter, <String, Object?>{
        'model': 'tom-assistant',
        'stream': false,
        'max_tokens': 1024,
        'messages': <Object?>[
          <String, Object?>{'role': 'user', 'content': 'hello'},
        ],
      });

      expect(response.statusCode, 200);
      expect(response.headers['content-type'], contains('application/json'));

      final Map<String, Object?> body =
          jsonDecode(await response.readAsString()) as Map<String, Object?>;
      expect(body['type'], 'message');
      expect(body['role'], 'assistant');
      expect(body['model'], 'tom-assistant');
      expect(body['stop_reason'], 'end_turn');
      expect(body['id'], startsWith('msg_'));
      final List<Object?> content = body['content'] as List<Object?>;
      expect(
        content.single,
        <String, Object?>{'type': 'text', 'text': _answerText},
      );
    });

    test('stream omitted ⇒ non-streaming (Anthropic default false)', () async {
      final Response response = await _call(adapter, <String, Object?>{
        'max_tokens': 16,
        'messages': <Object?>[
          <String, Object?>{'role': 'user', 'content': 'hello'},
        ],
      });
      expect(response.statusCode, 200);
      expect(response.headers['content-type'], contains('application/json'));
      expect(source.calls.single.stream, isFalse);
    });
  });

  group('model → persona stamping (AC-5)', () {
    test('a known persona-as-model id round-trips into the body', () async {
      final Response response = await _call(adapter, <String, Object?>{
        'model': 'tom-assistant:terse',
        'stream': false,
        'max_tokens': 16,
        'messages': <Object?>[
          <String, Object?>{'role': 'user', 'content': 'hello'},
        ],
      });
      final Map<String, Object?> body =
          jsonDecode(await response.readAsString()) as Map<String, Object?>;
      expect(body['model'], 'tom-assistant:terse');
    });

    test('an unknown model normalises to tom-assistant', () async {
      final Response response = await _call(adapter, <String, Object?>{
        'model': 'claude-3-opus',
        'stream': false,
        'max_tokens': 16,
        'messages': <Object?>[
          <String, Object?>{'role': 'user', 'content': 'hello'},
        ],
      });
      final Map<String, Object?> body =
          jsonDecode(await response.readAsString()) as Map<String, Object?>;
      expect(body['model'], 'tom-assistant');
    });

    test('an absent model normalises to tom-assistant', () async {
      final Response response = await _call(adapter, <String, Object?>{
        'stream': false,
        'max_tokens': 16,
        'messages': <Object?>[
          <String, Object?>{'role': 'user', 'content': 'hello'},
        ],
      });
      final Map<String, Object?> body =
          jsonDecode(await response.readAsString()) as Map<String, Object?>;
      expect(body['model'], 'tom-assistant');
    });
  });
}
