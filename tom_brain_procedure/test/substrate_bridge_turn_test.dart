// Turn-correlation stamping on SubstrateBridge (logging-spec §3 / §9 — the
// "→ substrate" end of the `turnId` thread-through).
//
// When the engine binds a per-run [TurnContext] to the bridge, every `send`
// completion stamps the turn's `turnId` and the next `callSeq` onto the
// outbound [LlmCall]. `turnId` + `callSeq` together uniquely name the call
// (§3). With no turn bound (the shared template bridge, internal / free-time /
// dream runs) the two fields stay `null`, so a non-turn call is unstamped.

import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show TurnContext, TurnId, Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';
import 'package:test/test.dart';

/// A trivial [RouteChainResolver] every `send` in this file routes over — the
/// low-level `llm` method was retired (Phase 5, step 12), so the bridge's
/// completion entry is now `send`, which selects a route by name and needs a
/// resolver bound. The recording client ignores the chain; only its presence
/// matters.
List<RouteEntry> _fastRoute(String _) =>
    const <RouteEntry>[RouteEntry(providerId: 'p', model: 'm')];

void main() {
  late _RecordingSubstrate client;

  setUp(() => client = _RecordingSubstrate());

  group('SubstrateBridge turn stamping', () {
    test('with no turn bound the LlmCall carries no turnId / callSeq', () async {
      final bridge = SubstrateBridge(client, routeChainOf: _fastRoute);
      await bridge.send('q', llmRoute: 'fast');
      expect(client.calls.single.turnId, isNull);
      expect(client.calls.single.callSeq, isNull);
    });

    test('a bound turn stamps the turnId and a monotonic callSeq per llm call',
        () async {
      final turn = TurnContext(TurnId.generate());
      final bridge =
          SubstrateBridge(client, routeChainOf: _fastRoute, turn: turn);

      await bridge.send('first', llmRoute: 'fast');
      await bridge.send('second', llmRoute: 'fast');

      expect(client.calls, hasLength(2));
      expect(client.calls[0].turnId, same(turn.turnId));
      expect(client.calls[0].callSeq, equals(1));
      expect(client.calls[1].turnId, same(turn.turnId));
      expect(client.calls[1].callSeq, equals(2));
    });

    test('only llm calls consume a callSeq — embed does not', () async {
      final turn = TurnContext(TurnId.generate());
      final bridge =
          SubstrateBridge(client, routeChainOf: _fastRoute, turn: turn);

      await bridge.send('a', llmRoute: 'fast');
      await bridge.embed('not a completion');
      await bridge.send('b', llmRoute: 'fast');

      final llmCalls = client.calls;
      expect(llmCalls, hasLength(2));
      // The embed in the middle did not advance the per-turn LLM counter.
      expect(llmCalls[0].callSeq, equals(1));
      expect(llmCalls[1].callSeq, equals(2));
    });

    // The agent-SDK § 1.5 seam: a turn carrying a tom_brain session id stamps it
    // onto the call's LlmOptions.brainSessionId; a turn without one (or no turn
    // at all) leaves it null. HTTP providers ignore the field; the agent-SDK
    // provider in `sessionMode: brain` reads it.
    test('a turn with a brainSessionId stamps it onto LlmOptions', () async {
      final turn = TurnContext(TurnId.generate(), brainSessionId: 'tb-42');
      final bridge =
          SubstrateBridge(client, routeChainOf: _fastRoute, turn: turn);

      await bridge.send('q', llmRoute: 'fast');

      expect(client.calls.single.options.brainSessionId, 'tb-42');
    });

    test('a turn without a brainSessionId leaves LlmOptions.brainSessionId null',
        () async {
      final turn = TurnContext(TurnId.generate());
      final bridge =
          SubstrateBridge(client, routeChainOf: _fastRoute, turn: turn);

      await bridge.send('q', llmRoute: 'fast');

      expect(client.calls.single.options.brainSessionId, isNull);
    });
  });
}

/// A `TomBrainSubstrateClient` that records every [LlmCall] it is handed and
/// returns a trivial one-chunk completed stream so `send` resolves cleanly.
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
