// Ollama NDJSON streaming-response rendering (plan item #27).
//
// The Ollama streaming wire is NDJSON: one JSON object per line, each line
// terminated by a single `\n`, content-type `application/x-ndjson`. There is
// NO `[DONE]` sentinel — the stream ends with a final object carrying
// `done: true` (and `done_reason: "stop"`); every earlier object carries
// `done: false`. The per-shape content carrier differs (chat →
// `message.content`, generate → `response`), but the framing is identical.
//
// This mirrors the OpenAI SSE renderer's discipline (one frame per chunk, a
// terminal marker after the stream completes) but in Ollama's object shape.
// The terminal `done: true` line is appended once the chunk stream completes,
// regardless of which chunk was marked final — so the content deltas all ride
// `done: false` lines and the terminator is always a clean empty-content
// object, exactly as `ollama run` expects.

import 'dart:convert';

import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

/// Streams [deltas] as ordered chunks, the last marked final.
Stream<OutboundChunk> _chunks(List<String> deltas) =>
    Stream<OutboundChunk>.fromIterable(<OutboundChunk>[
      for (int i = 0; i < deltas.length; i++)
        OutboundChunk(
          textDelta: deltas[i],
          isFinal: i == deltas.length - 1,
          index: i,
        ),
    ]);

/// Splits an NDJSON body into its decoded objects (one per non-empty line).
List<Map<String, Object?>> _lines(String body) => body
    .split('\n')
    .where((String s) => s.isNotEmpty)
    .map((String s) => jsonDecode(s) as Map<String, Object?>)
    .toList();

void main() {
  group('OllamaNdjsonRenderer — chat shape', () {
    test('emits one done:false line per chunk plus a terminal done:true line',
        () async {
      final OllamaNdjsonRenderer renderer = OllamaNdjsonRenderer.forModel(
        'tom-assistant',
        OllamaApiShape.chat,
        createdAt: DateTime.utc(2026, 1, 1, 12),
      );
      final String body =
          await renderer.render(_chunks(<String>['Hel', 'lo'])).join();

      // Every line is `\n`-terminated; there is no `[DONE]` sentinel anywhere.
      expect(body.endsWith('\n'), isTrue);
      expect(body.contains('[DONE]'), isFalse);

      final List<Map<String, Object?>> objs = _lines(body);
      // Two content lines + one terminal line.
      expect(objs, hasLength(3));

      // Content lines: done:false, model stamped, no id, content carried under
      // message.content, created_at present as an ISO-8601 instant.
      for (int i = 0; i < 2; i++) {
        final Map<String, Object?> obj = objs[i];
        expect(obj['done'], isFalse);
        expect(obj['model'], 'tom-assistant');
        expect(obj.containsKey('id'), isFalse);
        expect(obj.containsKey('done_reason'), isFalse);
        expect(DateTime.parse(obj['created_at'] as String), isNotNull);
        final Map<String, Object?> message =
            obj['message'] as Map<String, Object?>;
        expect(message['role'], 'assistant');
      }
      expect((objs[0]['message'] as Map<String, Object?>)['content'], 'Hel');
      expect((objs[1]['message'] as Map<String, Object?>)['content'], 'lo');

      // Terminal line: done:true, done_reason stop, empty assistant content.
      final Map<String, Object?> last = objs.last;
      expect(last['done'], isTrue);
      expect(last['done_reason'], 'stop');
      expect((last['message'] as Map<String, Object?>)['content'], '');
    });

    test('an empty chunk stream still emits the terminal done:true line',
        () async {
      final OllamaNdjsonRenderer renderer =
          OllamaNdjsonRenderer.forModel('tom-assistant', OllamaApiShape.chat);
      final String body = await renderer
          .render(const Stream<OutboundChunk>.empty())
          .join();
      final List<Map<String, Object?>> objs = _lines(body);
      expect(objs, hasLength(1));
      expect(objs.single['done'], isTrue);
      expect(objs.single['done_reason'], 'stop');
    });
  });

  group('OllamaNdjsonRenderer — generate shape', () {
    test('carries content under response and terminates with done:true',
        () async {
      final OllamaNdjsonRenderer renderer = OllamaNdjsonRenderer.forModel(
        'tom-assistant',
        OllamaApiShape.generate,
        createdAt: DateTime.utc(2026, 1, 1, 12),
      );
      final String body =
          await renderer.render(_chunks(<String>['sky ', 'blue'])).join();
      final List<Map<String, Object?>> objs = _lines(body);
      expect(objs, hasLength(3));
      expect(objs[0]['response'], 'sky ');
      expect(objs[0]['done'], isFalse);
      expect(objs[0].containsKey('message'), isFalse);
      expect(objs[1]['response'], 'blue');
      // Terminal line: empty response, done:true.
      expect(objs.last['response'], '');
      expect(objs.last['done'], isTrue);
      expect(objs.last['done_reason'], 'stop');
    });
  });

  group('OllamaNdjsonRenderer — constants', () {
    test('content-type is application/x-ndjson and done_reason is stop', () {
      expect(OllamaNdjsonRenderer.contentType, 'application/x-ndjson');
      expect(OllamaNdjsonRenderer.doneReason, 'stop');
    });
  });
}
