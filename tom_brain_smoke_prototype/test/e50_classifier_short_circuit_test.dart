// E.50 — end-to-end classifier short-circuit smoke.
//
// Plan step E.50 (verbatim): "Drive a second prompt with identical text and
// verify the kind-hint cache + the centroid classifier short-circuit the LLM
// classifier path."
//
// Where E.47 / E.48 / E.49 proved the channels end-to-end, E.50 proves the
// *cheap classifier* in front of the dispatcher. The smoke wires the kind-hint
// classifier (E.33) — a counting embedder behind the E.34 in-process cache, and
// a confident centroid classifier — plus a spy for the dispatcher's no-hint
// fallback (`classify_inbound_v1`, the prototype's stand-in for the LLM
// classifier path). Two identical prompts then drive the whole booted cognition.
//
// Two short-circuits are asserted, both over a *repeated, identical* prompt:
//
//   1. THE EMBEDDING CACHE (E.34) — the counting embedder is called exactly
//      once across both requests. The first prompt is a cache miss (embed); the
//      second is a live cache hit on the exact text, so the embed call is saved.
//   2. THE CENTROID CLASSIFIER (E.33) → THE LLM CLASSIFIER PATH — the centroid
//      classifier runs each request and returns a confident match, so the access
//      edge attaches `Access.envelope.kindHint`. The dispatcher accepts that
//      hint verbatim and never calls its `classify_inbound_v1` fallback: the spy
//      fallback's call count stays zero across both requests.
//
// Both requests still complete end-to-end (the OpenAI body carries the answer)
// and persist (two `Event`s + two `Conclusion`s), proving the hinted path is the
// *same* answer path — the classifier only changes how the kind is decided, not
// whether the run happens.

import 'dart:convert';
import 'dart:io';

import 'package:tom_brain_access/tom_brain_access.dart'
    show KindHintClassification, KindHintDecision;
import 'package:tom_brain_memory/tom_brain_memory.dart' show MemoryStats;
import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show SystemProcedures;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show Access, InboundKinds;
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
/// answer the body must carry.
const List<String> _answerChunks = <String>['Back up by ', 'rsyncing nightly.'];
const String _answerText = 'Back up by rsyncing nightly.';

/// The identical prompt driven twice — the repetition the two short-circuits key
/// on. The exact-text embedding cache hits only because both requests carry this
/// byte-for-byte string.
const String _prompt = 'how do I automate backups?';

/// A `chat/completions` request body for [prompt] with `stream=false`.
Map<String, Object?> _chatBody(String prompt) => <String, Object?>{
      'model': 'tom-brain',
      'messages': <Object?>[
        <String, Object?>{'role': 'user', 'content': prompt},
      ],
      'stream': false,
    };

void main() {
  group('E.50 classifier short-circuit', () {
    late SmokeProcess smoke;

    // The counters the short-circuit assertions read. Reset per test.
    late int embedCalls;
    late int classifyCalls;
    late int fallbackCalls;

    setUp(() async {
      embedCalls = 0;
      classifyCalls = 0;
      fallbackCalls = 0;

      smoke = await standUpSmokeProcess(
        substrate: SmokeSubstrate()
          ..answerChunks = List<String>.of(_answerChunks),
        // E.34: the substrate embed seam the access boot wraps in the in-process
        // cache. Counting it counts *real* embed calls (cache misses); a live
        // cache hit returns without reaching this closure.
        kindHintEmbedder: (String text) async {
          embedCalls++;
          return const <double>[0.0];
        },
        // E.33: the centroid classifier seam (memory's
        // `classify(embedding, ClassificationTarget.procedure)`). It returns a
        // confident match naming the *procedure id* `answer_with_memory_v1`
        // (Q-E.50.1: the centroid hint keys on a procedure id, not an inbound
        // kind), so the edge attaches a kind-hint the dispatcher resolves
        // directly to that procedure — bypassing the kind → procedure map.
        kindHintClassifier: (List<double> embedding) async {
          classifyCalls++;
          return const KindHintClassification(
            decision: KindHintDecision.confident,
            procedureId: SystemProcedures.answerWithMemoryV1,
          );
        },
        // The dispatcher's no-hint fallback (the prototype's LLM-classifier
        // stand-in). A confident kind-hint must short-circuit it, so this spy
        // must never run. It still returns a routable kind so a *wrong* call
        // would be caught by the count assertion, not by a routing crash.
        classifyFallback: (Access access) {
          fallbackCalls++;
          return InboundKinds.userPrompt;
        },
      );
    });

    tearDown(() async {
      await smoke.stop();
    });

    test(
        'a repeated identical prompt: cache saves the embed call and the '
        'confident hint short-circuits the fallback', () async {
      // ── First prompt: cache miss (embed), confident classify, hinted route. ──
      final first = await _postJson(
        smoke.port,
        '/v1/chat/completions',
        _chatBody(_prompt),
        token: smokeBearerToken,
      );
      expect(first.statusCode, 200);
      final firstBody = first.body as Map<String, Object?>;
      final firstChoice = (firstBody['choices'] as List<Object?>).single
          as Map<String, Object?>;
      final firstMessage = firstChoice['message'] as Map<String, Object?>;
      expect(firstMessage['content'], _answerText);

      // ── Second prompt, byte-for-byte identical: cache HIT (no embed). ──
      final second = await _postJson(
        smoke.port,
        '/v1/chat/completions',
        _chatBody(_prompt),
        token: smokeBearerToken,
      );
      expect(second.statusCode, 200);
      final secondBody = second.body as Map<String, Object?>;
      final secondChoice = (secondBody['choices'] as List<Object?>).single
          as Map<String, Object?>;
      final secondMessage = secondChoice['message'] as Map<String, Object?>;
      expect(secondMessage['content'], _answerText);

      // E.34 — the embedding cache short-circuit: two identical prompts, ONE
      // embed call (the first; the second hit the cache).
      expect(embedCalls, 1, reason: 'second identical prompt must hit the cache');

      // E.33 — the centroid classifier ran on *both* requests (it sits behind
      // the cache, not in front of it): the cache saves the embed, not the
      // classify.
      expect(classifyCalls, 2);

      // E.33 → the LLM-classifier path: the confident hint was accepted verbatim
      // by the dispatcher on both requests, so `classify_inbound_v1` (the spy)
      // never ran.
      expect(fallbackCalls, 0,
          reason: 'a confident kind-hint must short-circuit the fallback');
    });

    test('both hinted runs persist their exchange (Event + Conclusion)',
        () async {
      await _postJson(smoke.port, '/v1/chat/completions', _chatBody(_prompt),
          token: smokeBearerToken);
      await _postJson(smoke.port, '/v1/chat/completions', _chatBody(_prompt),
          token: smokeBearerToken);

      final MemoryStats stats = await smoke.memory.stats();
      // Two runs, each persisting one Event + one Conclusion — the hinted path
      // is the same answer path as the un-hinted one (E.47), just decided
      // cheaply at the edge.
      expect(stats.nodeCountByType['Event'], 2);
      expect(stats.nodeCountByType['Conclusion'], 2);
      expect(stats.trailCount, greaterThanOrEqualTo(2));

      // The fallback never decided the kind for either run.
      expect(fallbackCalls, 0);
    });
  });
}
