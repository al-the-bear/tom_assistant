// Ollama HTTP adapter — wire-format conformance / Verify suite (plan item #27).
//
// The #27 *Verify* — "an `ollama run`-style client receives a streamed answer"
// — proven in-process. Where `ollama_adapter_test.dart` locks the router /
// no-source / error-shape contract (the *negative* surface), this suite drives
// ONE fully-wired `OllamaHttpAdapter` (a synthetic `OllamaAnswerStream`
// injected, i.e. the adapter in its boot-complete shape, plan item #29+)
// black-box through its public `handler` only — a synthesised `shelf.Request`
// straight to `handler`, no socket — and proves the *positive* Ollama wire
// contract end-to-end:
//
//   - the NDJSON streaming body an `ollama run` client receives: one JSON
//     object per `\n`-terminated line, content deltas in order on `done: false`
//     lines, a terminal `done: true` line carrying `done_reason: "stop"`, NO
//     `[DONE]` sentinel, content-type `application/x-ndjson`;
//   - the non-streaming single-object body a `stream: false` client receives:
//     one JSON object carrying the FULL buffered answer + `done: true`;
//   - both endpoints (`/api/chat` → `message.content`, `/api/generate` →
//     `response`);
//   - `model` → persona stamping (a known id round-trips; an unknown / absent
//     id normalises to `tom-assistant`, AC-5);
//   - that the parsed request reaches the answer seam unchanged.
//
// This mirrors the OpenAI adapter's E.18 conformance suite (the SSE analogue);
// the two guard the same invariant in their respective wire dialects.

import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

// --- Fully-wired adapter under conformance test --------------------------

/// The answer the synthetic cognition streams back for every request: three
/// ordered increments, the last marked final. Ordering and the final marker
/// are what the NDJSON / JSON conformance assertions key on.
const List<String> _answerDeltas = <String>['Hel', 'lo, ', 'world'];
const String _answerText = 'Hello, world';

/// A synthetic `OllamaAnswerStream`: emits [_answerDeltas] in order, the last
/// chunk marked `isFinal`. Records the requests it was handed so the suite can
/// confirm the parsed request reached the seam unchanged.
class _RecordingAnswerSource {
  final List<OllamaRequest> calls = <OllamaRequest>[];

  Stream<OutboundChunk> stream(OllamaRequest request) {
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
  OllamaHttpAdapter adapter,
  String path,
  Object body,
) async {
  final Request request = Request(
    'POST',
    Uri.parse('http://localhost$path'),
    body: jsonEncode(body),
  );
  return await adapter.handler(request);
}

/// Splits an NDJSON body into its decoded line objects (one JSON object per
/// `\n`-terminated line, trailing blank dropped).
List<Map<String, Object?>> _ndjsonLines(String body) => <Map<String, Object?>>[
      for (final String line in body.split('\n'))
        if (line.trim().isNotEmpty)
          jsonDecode(line) as Map<String, Object?>,
    ];

void main() {
  late _RecordingAnswerSource source;
  late OllamaHttpAdapter adapter;

  setUp(() {
    source = _RecordingAnswerSource();
    adapter = OllamaHttpAdapter(answerStream: source.stream);
  });

  group('streaming NDJSON — an `ollama run` client receives a streamed answer',
      () {
    test('POST /api/chat streams ordered done:false lines + terminal done:true',
        () async {
      final Response response = await _call(adapter, '/api/chat', <String, Object?>{
        'model': 'tom-assistant',
        'stream': true,
        'messages': <Object?>[
          <String, Object?>{'role': 'user', 'content': 'hello'},
        ],
      });

      expect(response.statusCode, 200);
      expect(response.headers['content-type'], contains('application/x-ndjson'));

      final List<Map<String, Object?>> lines =
          _ndjsonLines(await response.readAsString());

      // One content line per delta, plus the terminal line.
      expect(lines.length, _answerDeltas.length + 1);

      // Content deltas ride done:false lines, in order, under message.content.
      for (int i = 0; i < _answerDeltas.length; i++) {
        final Map<String, Object?> line = lines[i];
        expect(line['done'], isFalse, reason: 'content line $i is not terminal');
        expect(line['model'], 'tom-assistant');
        expect(line.containsKey('id'), isFalse, reason: 'Ollama has no id');
        expect(DateTime.parse(line['created_at'] as String), isNotNull);
        final Map<String, Object?> message =
            line['message'] as Map<String, Object?>;
        expect(message['role'], 'assistant');
        expect(message['content'], _answerDeltas[i]);
      }

      // The terminal line: done:true, done_reason stop, empty content, NO
      // `[DONE]` sentinel anywhere.
      final Map<String, Object?> terminal = lines.last;
      expect(terminal['done'], isTrue);
      expect(terminal['done_reason'], 'stop');
      expect(
        (terminal['message'] as Map<String, Object?>)['content'],
        '',
      );

      // The reassembled answer is the full ordered text.
      final String streamed = <String>[
        for (int i = 0; i < _answerDeltas.length; i++)
          (lines[i]['message'] as Map<String, Object?>)['content'] as String,
      ].join();
      expect(streamed, _answerText);

      // The parsed request reached the seam unchanged.
      expect(source.calls, hasLength(1));
      expect(source.calls.single.prompt, 'hello');
      expect(source.calls.single.shape, OllamaApiShape.chat);
      expect(source.calls.single.stream, isTrue);
    });

    test('POST /api/generate streams under the response carrier', () async {
      final Response response =
          await _call(adapter, '/api/generate', <String, Object?>{
        'model': 'tom-assistant',
        'stream': true,
        'prompt': 'hello',
      });

      expect(response.statusCode, 200);
      expect(response.headers['content-type'], contains('application/x-ndjson'));

      final List<Map<String, Object?>> lines =
          _ndjsonLines(await response.readAsString());
      expect(lines.length, _answerDeltas.length + 1);

      for (int i = 0; i < _answerDeltas.length; i++) {
        expect(lines[i]['done'], isFalse);
        expect(lines[i]['response'], _answerDeltas[i]);
        expect(lines[i].containsKey('message'), isFalse);
      }
      expect(lines.last['done'], isTrue);
      expect(lines.last['done_reason'], 'stop');
      expect(lines.last['response'], '');

      expect(source.calls.single.shape, OllamaApiShape.generate);
    });

    test('Ollama streams by default — stream omitted ⇒ NDJSON', () async {
      final Response response =
          await _call(adapter, '/api/generate', <String, Object?>{
        'prompt': 'hello',
      });
      expect(response.statusCode, 200);
      expect(response.headers['content-type'], contains('application/x-ndjson'));
      expect(source.calls.single.stream, isTrue);
    });
  });

  group('non-streaming JSON — a `stream: false` client receives one object',
      () {
    test('POST /api/chat buffers the full answer into one done:true object',
        () async {
      final Response response =
          await _call(adapter, '/api/chat', <String, Object?>{
        'model': 'tom-assistant',
        'stream': false,
        'messages': <Object?>[
          <String, Object?>{'role': 'user', 'content': 'hello'},
        ],
      });

      expect(response.statusCode, 200);
      expect(response.headers['content-type'], contains('application/json'));

      final Map<String, Object?> body =
          jsonDecode(await response.readAsString()) as Map<String, Object?>;
      expect(body['model'], 'tom-assistant');
      expect(body['done'], isTrue);
      expect(body['done_reason'], 'stop');
      expect(body.containsKey('id'), isFalse);
      // Non-streaming completes: the buffered content is the FULL answer.
      expect(
        (body['message'] as Map<String, Object?>)['content'],
        _answerText,
      );
    });

    test('POST /api/generate buffers under the response carrier', () async {
      final Response response =
          await _call(adapter, '/api/generate', <String, Object?>{
        'stream': false,
        'prompt': 'hello',
      });
      final Map<String, Object?> body =
          jsonDecode(await response.readAsString()) as Map<String, Object?>;
      expect(body['response'], _answerText);
      expect(body.containsKey('message'), isFalse);
      expect(body['done'], isTrue);
    });
  });

  group('model → persona stamping (AC-5)', () {
    test('a known persona-as-model id round-trips into the body', () async {
      final Response response =
          await _call(adapter, '/api/generate', <String, Object?>{
        'model': 'tom-assistant:terse',
        'stream': false,
        'prompt': 'hello',
      });
      final Map<String, Object?> body =
          jsonDecode(await response.readAsString()) as Map<String, Object?>;
      expect(body['model'], 'tom-assistant:terse');
    });

    test('an unknown model normalises to tom-assistant', () async {
      final Response response =
          await _call(adapter, '/api/generate', <String, Object?>{
        'model': 'gpt-9-ultra',
        'stream': false,
        'prompt': 'hello',
      });
      final Map<String, Object?> body =
          jsonDecode(await response.readAsString()) as Map<String, Object?>;
      expect(body['model'], 'tom-assistant');
    });

    test('an absent model normalises to tom-assistant', () async {
      final Response response =
          await _call(adapter, '/api/generate', <String, Object?>{
        'stream': false,
        'prompt': 'hello',
      });
      final Map<String, Object?> body =
          jsonDecode(await response.readAsString()) as Map<String, Object?>;
      expect(body['model'], 'tom-assistant');
    });
  });
}
