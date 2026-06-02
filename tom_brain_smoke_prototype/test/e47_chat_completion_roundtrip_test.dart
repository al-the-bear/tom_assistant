// E.47 — end-to-end chat-completion roundtrip smoke.
//
// Plan step E.47 (verbatim): "Send a `POST /v1/chat/completions` with
// `stream=false`. Verify the answer body conforms to the OpenAI shape and that
// memory contains the expected `Event` + `Conclusion` + edges."
//
// Where E.46 proved the process *stands up* (a bound port + liveness +
// models), E.47 proves it *answers*. It drives a real, auth-gated
// `POST /v1/chat/completions` (`stream=false`) through the whole booted
// cognition: the OpenAI edge admits the request, the dispatcher routes it to
// `answer_with_memory_v1`, the stub [SmokeSubstrate] produces a canned chunked
// answer, the boot route hands that answer back through `Access.deliver`, and
// the edge reconstructs the non-streaming `chat.completion` body.
//
// Two obligations:
//
//   1. THE OPENAI BODY SHAPE — `object: "chat.completion"`, a `chatcmpl-` id, a
//      non-empty model, and `choices[0].message` carrying the assistant answer
//      (the concatenation of the substrate's chunks) with `finish_reason:
//      "stop"`.
//   2. THE PERSISTED GRAPH — the in-isolate memory holds the exchange the
//      procedure wrote: one `Event` (the inbound prompt), one `Conclusion` (the
//      answer), the recorder's `produced_by` edge, and — because a fresh memory
//      recalls nothing — the cold-path `InterestItem` + its `interests` stack
//      push. Read back through [SmokeProcess.memory] (the marshalling client),
//      since the store runs in the worker isolate.

import 'dart:convert';
import 'dart:io';

import 'package:tom_brain_memory/tom_brain_memory.dart' show MemoryStats;
import 'package:tom_brain_smoke_prototype/tom_brain_smoke_prototype.dart';
import 'package:test/test.dart';

/// Issues a `POST` of [body] as JSON against the bound smoke process, carrying
/// the bearer [token], and returns the status code and decoded JSON body.
Future<({int statusCode, Object? body})> _postJson(
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
    final Object? decoded = text.isEmpty ? null : jsonDecode(text);
    return (statusCode: response.statusCode, body: decoded);
  } finally {
    client.close(force: true);
  }
}

/// The chunked answer the stub substrate streams; its concatenation is the
/// answer text the body must carry and the `Conclusion` must record.
const List<String> _answerChunks = <String>['Back up by ', 'rsyncing nightly.'];
const String _answerText = 'Back up by rsyncing nightly.';

/// A `chat/completions` request body for [prompt] with `stream=false`.
Map<String, Object?> _chatBody(String prompt) => <String, Object?>{
      'model': 'tom-brain',
      'messages': <Object?>[
        <String, Object?>{'role': 'user', 'content': prompt},
      ],
      'stream': false,
    };

void main() {
  group('E.47 chat-completion roundtrip', () {
    late SmokeProcess smoke;

    setUp(() async {
      smoke = await standUpSmokeProcess(
        substrate: SmokeSubstrate()..answerChunks = List<String>.of(_answerChunks),
      );
    });

    tearDown(() async {
      await smoke.stop();
    });

    test('POST /v1/chat/completions (stream=false) returns the OpenAI body',
        () async {
      final result = await _postJson(
        smoke.port,
        '/v1/chat/completions',
        _chatBody('how do I automate backups?'),
        token: smokeBearerToken,
      );

      expect(result.statusCode, 200);
      final body = result.body as Map<String, Object?>;

      expect(body['object'], 'chat.completion');
      expect(body['id'], isA<String>());
      expect((body['id'] as String).startsWith('chatcmpl-'), isTrue);
      expect(body['model'], isA<String>());
      expect((body['model'] as String).isNotEmpty, isTrue);
      expect(body['created'], isA<int>());

      final choices = body['choices'] as List<Object?>;
      expect(choices, hasLength(1));
      final first = choices.first as Map<String, Object?>;
      expect(first['index'], 0);
      expect(first['finish_reason'], 'stop');

      final message = first['message'] as Map<String, Object?>;
      expect(message['role'], 'assistant');
      // The answer is the concatenation of the substrate's chunks — proof the
      // run reached the substrate and the boot route delivered the result back
      // through `Access.deliver`.
      expect(message['content'], _answerText);
    });

    test('the run persists an Event + a Conclusion + a produced_by edge',
        () async {
      await _postJson(
        smoke.port,
        '/v1/chat/completions',
        _chatBody('how do I automate backups?'),
        token: smokeBearerToken,
      );

      final MemoryStats stats = await smoke.memory.stats();

      // The exchange: one Event (the inbound prompt) + one Conclusion (the
      // answer). The procedure persists exactly one of each per run.
      expect(stats.nodeCountByType['Event'], 1);
      expect(stats.nodeCountByType['Conclusion'], 1);

      // The recorder draws a `produced_by` edge from the Conclusion to the
      // authoritative final ProcedureRun node.
      expect(stats.edgeCountByType['produced_by'], greaterThanOrEqualTo(1));

      // Recall was empty on a fresh memory, so the Conclusion cited nothing —
      // no `derived_from` edges were drawn.
      expect(stats.edgeCountByType['derived_from'] ?? 0, 0);

      // The run opened (and closed) a trail.
      expect(stats.trailCount, greaterThanOrEqualTo(1));
    });

    test('a fresh memory takes the cold path — InterestItem + interests push',
        () async {
      await _postJson(
        smoke.port,
        '/v1/chat/completions',
        _chatBody('a topic memory has never seen'),
        token: smokeBearerToken,
      );

      final MemoryStats stats = await smoke.memory.stats();

      // The four-mode recall surfaced nothing, so the body recorded the prompt
      // as an InterestItem and pushed it onto the `interests` bootstrap stack
      // (the cold-classification path, D.40).
      expect(stats.nodeCountByType['InterestItem'], 1);
      expect(stats.stackSizes['interests'], 1);
    });
  });

  group('E.47 auth gate', () {
    late SmokeProcess smoke;

    setUp(() async {
      smoke = await standUpSmokeProcess(
        substrate: SmokeSubstrate()..answerChunks = List<String>.of(_answerChunks),
      );
    });

    tearDown(() async {
      await smoke.stop();
    });

    test('an unbound bearer token is a 401 and writes nothing', () async {
      final result = await _postJson(
        smoke.port,
        '/v1/chat/completions',
        _chatBody('how do I automate backups?'),
        token: 'not-the-smoke-token',
      );

      expect(result.statusCode, 401);
      final body = result.body as Map<String, Object?>;
      final error = body['error'] as Map<String, Object?>;
      expect(error['code'], 'identity_unresolved');

      // A rejected request never reached the dispatcher, so no node was written.
      final MemoryStats stats = await smoke.memory.stats();
      expect(stats.nodeCountByType['Event'] ?? 0, 0);
      expect(stats.nodeCountByType['Conclusion'] ?? 0, 0);
    });
  });
}
