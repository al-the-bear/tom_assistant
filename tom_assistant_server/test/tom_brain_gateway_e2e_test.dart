// TomBrainClient ↔ Tom Brain gateway — end-to-end (UB6).
//
// This is UB6's done-when: "Tom Assistant runs end-to-end against a stood-up
// Tom Brain via the OpenAI gateway." It stands up a REAL brain process — the
// smoke assembly (`standUpSmokeProcess` + `SmokeSubstrate`): the real OpenAI
// edge (`tom_brain_access`) bound on an ephemeral port over the real dispatcher
// (routing to `answer_with_memory_v1`) and an in-isolate memory double, with a
// stub LLM producing a canned answer. No live model, no Ollama, no packaged
// vec0 binary, so the exchange is reproducible everywhere.
//
// The assistant-side [TomBrainClient] is the thing under test: it points at the
// bound gateway port and drives a buffered completion, a streamed completion,
// and the auth gate — proving the product-side consumer speaks the gateway's
// OpenAI wire contract against a running brain.

import 'package:tom_assistant_server/tom_assistant_server.dart';
import 'package:tom_brain_smoke_prototype/tom_brain_smoke_prototype.dart';
import 'package:test/test.dart';

void main() {
  group('Tom Assistant → stood-up Tom Brain gateway (UB6)', () {
    // The chunked answer the stub substrate streams; its concatenation is the
    // answer the client must reconstruct on both the buffered and SSE paths.
    const List<String> answerChunks = <String>['Back up by ', 'rsyncing nightly.'];
    const String answerText = 'Back up by rsyncing nightly.';

    late SmokeProcess smoke;
    late TomBrainClient client;

    setUp(() async {
      smoke = await standUpSmokeProcess(
        substrate: SmokeSubstrate()..answerChunks = List<String>.of(answerChunks),
      );
      client = TomBrainClient(
        baseUrl: Uri.parse('http://127.0.0.1:${smoke.port}'),
        bearerToken: smokeBearerToken,
        model: 'tom-assistant',
      );
    });

    tearDown(() async {
      client.close();
      await smoke.stop();
    });

    test('ask() round-trips a buffered completion through the gateway',
        () async {
      final completion = await client.ask('how do I automate backups?');

      // The answer is the concatenation of the substrate's chunks — proof the
      // request reached the dispatcher, ran the procedure, and the edge
      // reconstructed the OpenAI body the client parsed.
      expect(completion.content, answerText);
      expect(completion.finishReason, 'stop');
      expect(completion.id, isNotNull);
      expect(completion.id!.startsWith('chatcmpl-'), isTrue);
      expect(completion.model, isNotNull);
    });

    test('askStream() reconstructs the answer from SSE deltas', () async {
      final deltas = await client.askStream('how do I automate backups?').toList();

      expect(deltas, isNotEmpty);
      expect(deltas.join(), answerText);
    });

    test('an unbound bearer token surfaces as a TomBrainClientException(401)',
        () async {
      final rejected = TomBrainClient(
        baseUrl: Uri.parse('http://127.0.0.1:${smoke.port}'),
        bearerToken: 'not-the-smoke-token',
      );
      addTearDown(rejected.close);

      await expectLater(
        rejected.ask('how do I automate backups?'),
        throwsA(isA<TomBrainClientException>()
            .having((e) => e.statusCode, 'statusCode', 401)
            .having((e) => e.body, 'body', contains('identity_unresolved'))),
      );
    });
  });
}
