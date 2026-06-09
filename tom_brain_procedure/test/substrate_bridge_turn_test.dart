// Turn-correlation stamping on SubstrateBridge (logging-spec §3 / §9 — the
// "→ substrate" end of the `turnId` thread-through).
//
// When the engine binds a per-run [TurnContext] to the bridge, every `llm`
// completion stamps the turn's `turnId` and the next `callSeq` onto the
// outbound [LlmCall]. `turnId` + `callSeq` together uniquely name the call
// (§3). With no turn bound (the shared template bridge, internal / free-time /
// dream runs) the two fields stay `null`, so a non-turn call is unstamped.

import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show TurnContext, TurnId, Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';
import 'package:test/test.dart';

void main() {
  late _RecordingSubstrate client;

  setUp(() => client = _RecordingSubstrate());

  group('SubstrateBridge turn stamping', () {
    test('with no turn bound the LlmCall carries no turnId / callSeq', () async {
      final bridge = SubstrateBridge(client);
      await bridge.llm('q');
      expect(client.calls.single.turnId, isNull);
      expect(client.calls.single.callSeq, isNull);
    });

    test('a bound turn stamps the turnId and a monotonic callSeq per llm call',
        () async {
      final turn = TurnContext(TurnId.generate());
      final bridge = SubstrateBridge(client, turn: turn);

      await bridge.llm('first');
      await bridge.llm('second');

      expect(client.calls, hasLength(2));
      expect(client.calls[0].turnId, same(turn.turnId));
      expect(client.calls[0].callSeq, equals(1));
      expect(client.calls[1].turnId, same(turn.turnId));
      expect(client.calls[1].callSeq, equals(2));
    });

    test('only llm calls consume a callSeq — embed does not', () async {
      final turn = TurnContext(TurnId.generate());
      final bridge = SubstrateBridge(client, turn: turn);

      await bridge.llm('a');
      await bridge.embed('not a completion');
      await bridge.llm('b');

      final llmCalls = client.calls;
      expect(llmCalls, hasLength(2));
      // The embed in the middle did not advance the per-turn LLM counter.
      expect(llmCalls[0].callSeq, equals(1));
      expect(llmCalls[1].callSeq, equals(2));
    });
  });
}

/// A `TomBrainSubstrateClient` that records every [LlmCall] it is handed and
/// returns a trivial one-chunk completed stream so `llm` resolves cleanly.
class _RecordingSubstrate implements TomBrainSubstrateClient {
  final List<LlmCall> calls = <LlmCall>[];

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) {
    calls.add(call);
    return Stream<LlmStreamEvent>.fromIterable(<LlmStreamEvent>[
      const LlmStreamChunk(callId: 'c', text: 'ok'),
      const LlmStreamCompleted(
        callId: 'c',
        report: LlmCallReport(
          providerId: 'p',
          modelId: 'm',
          anchorHash: 'a',
          promptHash: 'pr',
          tokensIn: 1,
          tokensOut: 1,
          retries: 0,
          wallClockMs: 1,
        ),
      ),
    ]);
  }

  @override
  Future<EmbeddingResult> embed(String text) async => EmbeddingResult(
        vec: Vec.zero(1),
        modelIdentity: const EmbeddingModelIdentity(
          providerId: 'p',
          modelId: 'm',
          dims: 1,
          normalized: true,
        ),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
