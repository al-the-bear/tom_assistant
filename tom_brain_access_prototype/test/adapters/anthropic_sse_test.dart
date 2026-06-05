// Anthropic Messages SSE streaming-response rendering (plan item #28).
//
// `AnthropicSseRenderer` maps the answer's `Stream<OutboundChunk>` onto the
// canonical Anthropic Messages streaming event sequence an Anthropic SDK
// consumes. Unlike OpenAI's single-object-per-frame SSE (one
// `chat.completion.chunk` + a terminal `data: [DONE]`), Anthropic frames a
// *named* event envelope around the whole message:
//
//   message_start → content_block_start → content_block_delta × N →
//   content_block_stop → message_delta → message_stop
//
// Each frame is `event: <name>\ndata: <json>\n\n`; there is NO `[DONE]`
// sentinel — `message_stop` closes the stream. This suite locks that
// sequence, the per-event JSON shapes, the `msg_…` id repeated across the
// envelope, and the char/4 usage estimates (`input_tokens` on
// `message_start`, `output_tokens` on `message_delta`).

import 'dart:convert';

import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

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

const List<String> _deltas = <String>['Hel', 'lo, ', 'world'];

Stream<OutboundChunk> _chunks() => Stream<OutboundChunk>.fromIterable(
      <OutboundChunk>[
        for (int i = 0; i < _deltas.length; i++)
          OutboundChunk(
            textDelta: _deltas[i],
            isFinal: i == _deltas.length - 1,
            index: i,
          ),
      ],
    );

void main() {
  late AnthropicSseRenderer renderer;

  setUp(() {
    renderer = const AnthropicSseRenderer(
      id: 'msg_TESTID',
      model: 'tom-assistant',
    );
  });

  group('AnthropicSseRenderer — canonical event sequence', () {
    test('emits message_start → content_block_start → deltas → '
        'content_block_stop → message_delta → message_stop', () async {
      final String body =
          await renderer.render(prompt: 'hello', chunks: _chunks()).join();
      final List<_Frame> frames = _frames(body);

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

      // No `[DONE]` sentinel anywhere — message_stop is the terminator.
      expect(body.contains('[DONE]'), isFalse);
    });

    test('message_start carries the message envelope + input usage', () async {
      final String body =
          await renderer.render(prompt: 'hello', chunks: _chunks()).join();
      final _Frame start = _frames(body).first;

      expect(start.data['type'], 'message_start');
      final Map<String, Object?> message =
          start.data['message'] as Map<String, Object?>;
      expect(message['id'], 'msg_TESTID');
      expect(message['type'], 'message');
      expect(message['role'], 'assistant');
      expect(message['model'], 'tom-assistant');
      expect(message['content'], isEmpty);
      expect(message['stop_reason'], isNull);
      expect(message['stop_sequence'], isNull);
      final Map<String, Object?> usage =
          message['usage'] as Map<String, Object?>;
      // char/4 estimate of 'hello' (5) → 2; output not yet known → 0.
      expect(usage['input_tokens'], 2);
      expect(usage['output_tokens'], 0);
    });

    test('content_block_start opens an empty text block at index 0', () async {
      final String body =
          await renderer.render(prompt: 'hello', chunks: _chunks()).join();
      final _Frame open = _frames(body)[1];
      expect(open.data['type'], 'content_block_start');
      expect(open.data['index'], 0);
      expect(
        open.data['content_block'],
        <String, Object?>{'type': 'text', 'text': ''},
      );
    });

    test('each content_block_delta carries an ordered text_delta', () async {
      final String body =
          await renderer.render(prompt: 'hello', chunks: _chunks()).join();
      final List<_Frame> deltas = _frames(body)
          .where((_Frame f) => f.event == 'content_block_delta')
          .toList();
      expect(deltas, hasLength(_deltas.length));
      for (int i = 0; i < _deltas.length; i++) {
        expect(deltas[i].data['type'], 'content_block_delta');
        expect(deltas[i].data['index'], 0);
        expect(
          deltas[i].data['delta'],
          <String, Object?>{'type': 'text_delta', 'text': _deltas[i]},
        );
      }
      // The reassembled answer is the full ordered text.
      final String streamed = deltas
          .map((_Frame f) =>
              (f.data['delta'] as Map<String, Object?>)['text'] as String)
          .join();
      expect(streamed, 'Hello, world');
    });

    test('content_block_stop closes index 0', () async {
      final String body =
          await renderer.render(prompt: 'hello', chunks: _chunks()).join();
      final _Frame stop = _frames(body)
          .firstWhere((_Frame f) => f.event == 'content_block_stop');
      expect(stop.data['type'], 'content_block_stop');
      expect(stop.data['index'], 0);
    });

    test('message_delta carries the stop reason + output usage', () async {
      final String body =
          await renderer.render(prompt: 'hello', chunks: _chunks()).join();
      final _Frame delta = _frames(body)
          .firstWhere((_Frame f) => f.event == 'message_delta');
      expect(delta.data['type'], 'message_delta');
      expect(
        delta.data['delta'],
        <String, Object?>{'stop_reason': 'end_turn', 'stop_sequence': null},
      );
      final Map<String, Object?> usage =
          delta.data['usage'] as Map<String, Object?>;
      // char/4 estimate of the full answer 'Hello, world' (12) → 3.
      expect(usage['output_tokens'], 3);
    });

    test('message_stop is the terminal frame', () async {
      final String body =
          await renderer.render(prompt: 'hello', chunks: _chunks()).join();
      final _Frame last = _frames(body).last;
      expect(last.event, 'message_stop');
      expect(last.data['type'], 'message_stop');
    });
  });

  group('AnthropicSseRenderer.forModel', () {
    test('mints a fresh msg_<ULID> id', () {
      final AnthropicSseRenderer r =
          AnthropicSseRenderer.forModel('tom-assistant');
      expect(r.id, startsWith('msg_'));
      expect(r.id.length, greaterThan('msg_'.length));
      expect(r.model, 'tom-assistant');
    });
  });
}
