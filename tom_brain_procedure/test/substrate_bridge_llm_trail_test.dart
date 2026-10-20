// Raw-LLM-trail observation on SubstrateBridge (`tom_brain_logging.md` §5.2 /
// §10 step #4 — the "→ writer" end of the seam).
//
// The §5.2 raw trail needs the **wire body** the provider saw plus the answer
// and the report. Those three only coexist inside `SubstrateBridge.send`, which
// drains the substrate stream. When the engine binds an `onLlmTrail` observer,
// the bridge fires exactly one [LlmCallObservation] per completed `send` call,
// carrying the captured wire, the concatenated answer, the report, and the
// turn-correlation stamp. With no observer bound the bridge stays silent and
// the wire never escapes (PE-1 — it is also never on the d4rt-facing result).

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
List<RouteEntry> _fastRoute(String _) => const <RouteEntry>[
  RouteEntry(providerId: 'p', model: 'm'),
];

void main() {
  late _RecordingSubstrate client;

  setUp(() => client = _RecordingSubstrate());

  group('SubstrateBridge raw-LLM-trail observation (§5.2 / §10 step #4)', () {
    test(
      'with no observer bound the bridge fires nothing and answers cleanly',
      () async {
        final bridge = SubstrateBridge(client, routeChainOf: _fastRoute);
        final result = await bridge.send('q', llmRoute: 'fast');
        // The completion still works; the wire body is not on the d4rt result.
        expect(result['text'], 'hello world');
        expect(
          result.containsKey('wire'),
          isFalse,
          reason: 'PE-1: the wire scaffold never enters procedure scope',
        );
      },
    );

    test(
      'a bound observer receives one observation carrying wire + answer',
      () async {
        final observed = <LlmCallObservation>[];
        final turn = TurnContext(TurnId.generate());
        final bridge = SubstrateBridge(
          client,
          routeChainOf: _fastRoute,
          turn: turn,
          onLlmTrail: observed.add,
        );

        await bridge.send('q', llmRoute: 'fast', role: 'assistant_to_user');

        expect(observed, hasLength(1));
        final obs = observed.single;
        expect(obs.callType, 'assistant_to_user');
        expect(obs.answer, 'hello world');
        // The wire the bridge saw is the facade-captured scaffold the provider
        // received — its provenance must match the report (anchor invariant).
        expect(obs.wire, isNotNull);
        expect(obs.wire!.body, 'ANCHOR\n\nq');
        expect(obs.wire!.roleId, 'assistant_to_user');
        expect(obs.wire!.anchorHash, obs.report.anchorHash);
        expect(obs.report.providerId, 'p');
        // Turn-correlation stamp travels onto the observation (§3).
        expect(obs.turnId, turn.turnId.value);
        expect(obs.callSeq, 1);
        expect(obs.callId, 'c');
      },
    );

    test(
      'a bound observer fires once per llm call, advancing callSeq',
      () async {
        final observed = <LlmCallObservation>[];
        final turn = TurnContext(TurnId.generate());
        final bridge = SubstrateBridge(
          client,
          routeChainOf: _fastRoute,
          turn: turn,
          onLlmTrail: observed.add,
        );

        await bridge.send('first', llmRoute: 'fast');
        await bridge.embed('not a completion');
        await bridge.send('second', llmRoute: 'fast');

        expect(
          observed,
          hasLength(2),
          reason: 'embed does not produce an llm observation',
        );
        expect(observed[0].callSeq, 1);
        expect(observed[1].callSeq, 2);
      },
    );

    test(
      'a throwing observer never breaks the completion (best-effort, §9)',
      () async {
        final bridge = SubstrateBridge(
          client,
          routeChainOf: _fastRoute,
          onLlmTrail: (_) => throw StateError('writer blew up'),
        );

        final result = await bridge.send('q', llmRoute: 'fast');
        expect(result['text'], 'hello world');
      },
    );
  });
}

/// A `TomBrainSubstrateClient` whose stream mirrors the facade contract: two
/// chunks then a terminal [LlmRunCompleted] carrying a [CapturedWirePrompt]
/// (the wire body the provider saw, anchor-prefixed) whose `anchorHash`
/// matches the report's.
class _RecordingSubstrate implements TomBrainSubstrateClient {
  final List<LlmCall> calls = <LlmCall>[];

  @override
  Stream<LlmEvent> completeStream(LlmCall call) {
    calls.add(call);
    final prompt = call.inputs['prompt'] as String;
    const anchorHash = 'sha256:anchor';
    return Stream<LlmEvent>.fromIterable(<LlmEvent>[
      const LlmTextDelta('hello '),
      const LlmTextDelta('world'),
      LlmRunCompleted(
        callId: 'c',
        wire: CapturedWirePrompt(
          body: 'ANCHOR\n\n$prompt',
          anchorHash: anchorHash,
          roleId: call.roleId,
        ),
        report: const LlmCallReport(
          providerId: 'p',
          modelId: 'm',
          anchorHash: anchorHash,
          promptHash: 'pr',
          tokensIn: 1,
          tokensOut: 2,
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
