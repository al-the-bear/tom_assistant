// E.48 — end-to-end streaming chat-completion smoke (`stream=true`).
//
// Plan step E.48 (verbatim): "Send a `POST /v1/chat/completions` with
// `stream=true`. Verify SSE chunk ordering, `[DONE]` terminator, correct
// content-type."
//
// Where E.47 proved the non-streaming roundtrip (one buffered
// `chat.completion` body), E.48 proves the *streaming* surface: the same
// booted cognition, but the OpenAI edge replays the captured `OutboundChunk`s
// as Server-Sent-Event frames over a `text/event-stream` body. The edge buffers
// the answer (so an edge-gate rejection still maps to the right HTTP status,
// Q-E.45.2) then replays the frames; from the wire's point of view the response
// is a well-formed SSE stream.
//
// Three obligations, straight from the plan:
//
//   1. CORRECT CONTENT-TYPE — the response carries `text/event-stream`
//      (the OpenAI streaming media type), not `application/json`.
//   2. SSE CHUNK ORDERING — every `data:` frame is a `chat.completion.chunk`
//      object; the concatenation of their `choices[0].delta.content` is the
//      answer, in order; the final content chunk carries `finish_reason: stop`.
//   3. `[DONE]` TERMINATOR — the very last frame on the wire is exactly
//      `data: [DONE]`, and nothing follows it.
//
// Architecture note (logged as Q-E.48.1): the prototype's one procedure
// produces the whole answer as a single output, which the boot route delivers
// as exactly one final `OutboundChunk` (E.47). So a smoke run yields one
// content frame followed by `[DONE]` — ordering is real but short. The test
// drives a multi-fragment substrate stream to prove the fragments are
// concatenated into that single delivered answer, and asserts the frame
// ordering / terminator / content-type the plan calls for.

import 'dart:convert';
import 'dart:io';

import 'package:tom_brain_smoke_prototype/tom_brain_smoke_prototype.dart';
import 'package:test/test.dart';

/// The raw result of a streaming `POST`: status, the `content-type` header, and
/// the raw (undecoded) response body — SSE is a text wire, not JSON, so the
/// body is read verbatim and parsed into frames by the test.
typedef _StreamResult = ({int statusCode, String? contentType, String body});

/// Issues a `POST` of [body] as JSON against the bound smoke process, carrying
/// the bearer [token], and returns the status, `content-type`, and raw body.
Future<_StreamResult> _postForStream(
  int port,
  String path,
  Object body, {
  required String token,
}) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request =
        await client.postUrl(Uri.parse('http://127.0.0.1:$port$path'));
    request.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    request.add(utf8.encode(jsonEncode(body)));
    final HttpClientResponse response = await request.close();
    final String text = await response.transform(utf8.decoder).join();
    return (
      statusCode: response.statusCode,
      contentType: response.headers.value('content-type'),
      body: text,
    );
  } finally {
    client.close(force: true);
  }
}

/// Splits an SSE wire body into its ordered, non-empty `data:` frame lines.
///
/// SSE frames are separated by a blank line (`\n\n`); each frame here is a
/// single `data: …` line. The trailing empty segment after the last `\n\n` is
/// dropped.
List<String> _frames(String body) => body
    .split('\n\n')
    .map((String s) => s.trim())
    .where((String s) => s.isNotEmpty)
    .toList();

/// Decodes the JSON payload of one `data: {…}` frame, or `null` for the
/// terminal `data: [DONE]` line.
Map<String, Object?>? _payload(String frame) {
  if (!frame.startsWith('data:')) return null;
  final String data = frame.substring('data:'.length).trim();
  if (data == '[DONE]') return null;
  return jsonDecode(data) as Map<String, Object?>;
}

/// The chunked answer the stub substrate streams; the bridge concatenates the
/// fragments into the single answer the boot route delivers (E.47 / Q-E.48.1).
const List<String> _answerChunks = <String>['Back up by ', 'rsyncing nightly.'];
const String _answerText = 'Back up by rsyncing nightly.';

/// A `chat/completions` request body for [prompt] with `stream=true`.
Map<String, Object?> _streamBody(String prompt) => <String, Object?>{
      'model': 'tom-brain',
      'messages': <Object?>[
        <String, Object?>{'role': 'user', 'content': prompt},
      ],
      'stream': true,
    };

void main() {
  group('E.48 streaming chat-completion roundtrip', () {
    late SmokeProcess smoke;

    setUp(() async {
      smoke = await standUpSmokeProcess(
        substrate: SmokeSubstrate()
          ..answerChunks = List<String>.of(_answerChunks),
      );
    });

    tearDown(() async {
      await smoke.stop();
    });

    test('the response carries the text/event-stream content-type', () async {
      final _StreamResult result = await _postForStream(
        smoke.port,
        '/v1/chat/completions',
        _streamBody('how do I automate backups?'),
        token: smokeBearerToken,
      );

      expect(result.statusCode, 200);
      // The streaming media type, not application/json — proof the edge took
      // the SSE replay branch (request.stream == true).
      expect(result.contentType, isNotNull);
      expect(result.contentType!.startsWith('text/event-stream'), isTrue);
    });

    test('every data frame is a chat.completion.chunk in order', () async {
      final _StreamResult result = await _postForStream(
        smoke.port,
        '/v1/chat/completions',
        _streamBody('how do I automate backups?'),
        token: smokeBearerToken,
      );

      final List<String> frames = _frames(result.body);
      // At least one content frame plus the terminal [DONE] line.
      expect(frames.length, greaterThanOrEqualTo(2));

      // Every non-terminal frame is a well-formed chat.completion.chunk that
      // repeats one stable chatcmpl- id and a non-empty model.
      final List<Map<String, Object?>> chunks = <Map<String, Object?>>[];
      for (final String frame in frames) {
        final Map<String, Object?>? payload = _payload(frame);
        if (payload == null) continue;
        chunks.add(payload);
        expect(payload['object'], 'chat.completion.chunk');
        expect((payload['id'] as String).startsWith('chatcmpl-'), isTrue);
        expect((payload['model'] as String).isNotEmpty, isTrue);
      }
      expect(chunks, isNotEmpty);

      // All content frames repeat the same id (one completion, many chunks).
      final Set<String> ids =
          chunks.map((Map<String, Object?> c) => c['id'] as String).toSet();
      expect(ids, hasLength(1));

      // Concatenating the deltas in arrival order reconstructs the answer —
      // this is the SSE chunk-ordering guarantee the plan asks for.
      final StringBuffer content = StringBuffer();
      for (final Map<String, Object?> chunk in chunks) {
        final List<Object?> choices = chunk['choices'] as List<Object?>;
        final Map<String, Object?> first =
            choices.first as Map<String, Object?>;
        final Map<String, Object?> delta = first['delta'] as Map<String, Object?>;
        if (delta['content'] is String) {
          content.write(delta['content'] as String);
        }
      }
      expect(content.toString(), _answerText);

      // The final content chunk closes the completion with finish_reason: stop;
      // no earlier chunk does.
      final Map<String, Object?> lastChoice =
          (chunks.last['choices'] as List<Object?>).first
              as Map<String, Object?>;
      expect(lastChoice['finish_reason'], 'stop');
      for (final Map<String, Object?> chunk
          in chunks.take(chunks.length - 1)) {
        final Map<String, Object?> choice =
            (chunk['choices'] as List<Object?>).first as Map<String, Object?>;
        expect(choice['finish_reason'], isNull);
      }
    });

    test('the wire is terminated by a final data: [DONE] line', () async {
      final _StreamResult result = await _postForStream(
        smoke.port,
        '/v1/chat/completions',
        _streamBody('how do I automate backups?'),
        token: smokeBearerToken,
      );

      final List<String> frames = _frames(result.body);
      // [DONE] is the very last frame on the wire and appears exactly once.
      expect(frames.last, 'data: [DONE]');
      expect(
        frames.where((String f) => f == 'data: [DONE]'),
        hasLength(1),
      );
      // The raw body ends with the SSE-terminated [DONE] frame (trailing blank
      // line), so nothing follows the terminator.
      expect(result.body.trimRight().endsWith('data: [DONE]'), isTrue);
    });
  });

  group('E.48 streaming auth gate', () {
    late SmokeProcess smoke;

    setUp(() async {
      smoke = await standUpSmokeProcess(
        substrate: SmokeSubstrate()
          ..answerChunks = List<String>.of(_answerChunks),
      );
    });

    tearDown(() async {
      await smoke.stop();
    });

    test('an unbound bearer token is a 401 JSON error, not an SSE stream',
        () async {
      final _StreamResult result = await _postForStream(
        smoke.port,
        '/v1/chat/completions',
        _streamBody('how do I automate backups?'),
        token: 'not-the-smoke-token',
      );

      expect(result.statusCode, 401);
      // A rejected request is the OpenAI JSON error envelope — the edge gates
      // run before any SSE byte is sent, so the stream branch is never taken.
      expect(result.contentType, isNotNull);
      expect(result.contentType!.startsWith('application/json'), isTrue);
      final Map<String, Object?> body =
          jsonDecode(result.body) as Map<String, Object?>;
      final Map<String, Object?> error = body['error'] as Map<String, Object?>;
      expect(error['code'], 'identity_unresolved');
    });
  });
}
