// Anthropic Messages non-streaming (JSON) response rendering (plan item #28).
//
// `AnthropicJsonRenderer` buffers the answer's `Stream<OutboundChunk>` into
// one Anthropic Message object — the single body a `stream: false` client
// receives. Where `AnthropicSseRenderer` frames the answer as a named-event
// envelope, this renderer collapses it to one JSON object:
//
//   {id:"msg_…", type:"message", role:"assistant", model,
//    content:[{type:"text", text:"<full answer>"}],
//    stop_reason:"end_turn", stop_sequence:null,
//    usage:{input_tokens, output_tokens}}
//
// This suite locks that shape, the buffered (full-answer) content, the
// `msg_…` id, and the char/4 usage estimates.

import 'dart:convert';

import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

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
  late AnthropicJsonRenderer renderer;

  setUp(() {
    renderer = const AnthropicJsonRenderer(
      id: 'msg_TESTID',
      model: 'tom-assistant',
    );
  });

  group('AnthropicJsonRenderer — buffered Message object', () {
    test('buffers every chunk into one text block carrying the full answer',
        () async {
      final Map<String, Object?> body = jsonDecode(
        await renderer.render(prompt: 'hello', chunks: _chunks()),
      ) as Map<String, Object?>;

      expect(body['id'], 'msg_TESTID');
      expect(body['type'], 'message');
      expect(body['role'], 'assistant');
      expect(body['model'], 'tom-assistant');
      expect(body['stop_reason'], 'end_turn');
      expect(body['stop_sequence'], isNull);

      final List<Object?> content = body['content'] as List<Object?>;
      expect(content, hasLength(1));
      expect(
        content.single,
        <String, Object?>{'type': 'text', 'text': 'Hello, world'},
      );
    });

    test('usage carries char/4 input + output token estimates', () async {
      final Map<String, Object?> body = jsonDecode(
        await renderer.render(prompt: 'hello', chunks: _chunks()),
      ) as Map<String, Object?>;
      final Map<String, Object?> usage = body['usage'] as Map<String, Object?>;
      // 'hello' (5) → 2; 'Hello, world' (12) → 3.
      expect(usage['input_tokens'], 2);
      expect(usage['output_tokens'], 3);
    });

    test('an empty answer yields a single empty text block', () async {
      final Map<String, Object?> body = jsonDecode(
        await renderer.render(
          prompt: 'hello',
          chunks: const Stream<OutboundChunk>.empty(),
        ),
      ) as Map<String, Object?>;
      final List<Object?> content = body['content'] as List<Object?>;
      expect(
        content.single,
        <String, Object?>{'type': 'text', 'text': ''},
      );
      expect((body['usage'] as Map<String, Object?>)['output_tokens'], 0);
    });
  });

  group('AnthropicJsonRenderer.forModel', () {
    test('mints a fresh msg_<ULID> id', () {
      final AnthropicJsonRenderer r =
          AnthropicJsonRenderer.forModel('tom-assistant');
      expect(r.id, startsWith('msg_'));
      expect(r.id.length, greaterThan('msg_'.length));
      expect(r.model, 'tom-assistant');
    });
  });
}
