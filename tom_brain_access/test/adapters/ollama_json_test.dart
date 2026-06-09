// Ollama non-streaming (single-object) response rendering (plan item #27).
//
// When a client sets `stream: false`, Ollama answers with ONE JSON object
// (content-type `application/json`) carrying the whole answer text and
// `done: true` / `done_reason: "stop"` — the buffered analogue of the NDJSON
// terminator. The per-shape content carrier is the same as the streaming
// renderer (chat → `message.content`, generate → `response`); only the
// framing (one object, not many lines) differs.

import 'dart:convert';

import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

Stream<OutboundChunk> _chunks(List<String> deltas) =>
    Stream<OutboundChunk>.fromIterable(<OutboundChunk>[
      for (int i = 0; i < deltas.length; i++)
        OutboundChunk(
          textDelta: deltas[i],
          isFinal: i == deltas.length - 1,
          index: i,
        ),
    ]);

void main() {
  group('OllamaJsonRenderer — chat shape', () {
    test('buffers all chunks into one done:true object', () async {
      final OllamaJsonRenderer renderer = OllamaJsonRenderer.forModel(
        'tom-assistant',
        OllamaApiShape.chat,
        createdAt: DateTime.utc(2026, 1, 1, 12),
      );
      final Map<String, Object?> body = jsonDecode(
        await renderer.render(_chunks(<String>['Hel', 'lo, ', 'world'])),
      ) as Map<String, Object?>;

      expect(body['model'], 'tom-assistant');
      expect(body['done'], isTrue);
      expect(body['done_reason'], 'stop');
      expect(body.containsKey('id'), isFalse);
      expect(DateTime.parse(body['created_at'] as String), isNotNull);

      final Map<String, Object?> message =
          body['message'] as Map<String, Object?>;
      expect(message['role'], 'assistant');
      // Non-streaming completes: the buffered content is the FULL answer.
      expect(message['content'], 'Hello, world');
    });
  });

  group('OllamaJsonRenderer — generate shape', () {
    test('carries the full answer under response', () async {
      final OllamaJsonRenderer renderer = OllamaJsonRenderer.forModel(
        'tom-assistant',
        OllamaApiShape.generate,
      );
      final Map<String, Object?> body = jsonDecode(
        await renderer.render(_chunks(<String>['the ', 'answer'])),
      ) as Map<String, Object?>;
      expect(body['response'], 'the answer');
      expect(body.containsKey('message'), isFalse);
      expect(body['done'], isTrue);
      expect(body['done_reason'], 'stop');
    });
  });

  group('OllamaJsonRenderer — constants', () {
    test('content-type is application/json and done_reason is stop', () {
      expect(OllamaJsonRenderer.contentType, 'application/json; charset=utf-8');
      expect(OllamaJsonRenderer.doneReason, 'stop');
    });
  });
}
