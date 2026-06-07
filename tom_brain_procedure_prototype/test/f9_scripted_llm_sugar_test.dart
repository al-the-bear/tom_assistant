// Extension F step 9 — the `sub.llm` engine-native sugar primitive
// (`tom_brain_procedure_prototype_specification.md` § 21.1, § 5.1;
// `prototype_tools_mcp_extension_plan.md` step 9).
//
// `sub.llm` is the high-level scripted-LLM call. It is **exactly**
// `runProcedure(procedure ?? 'call_llm_v1', {prompt, role, tools,
// mcpServers, model, budget}, depthDelta: 1)` — an implicit nested
// procedure call (§ 21.1). It re-implements nothing: the depth cap (PE-3),
// run recording (PE-4), and effort roll-up all fall out of the shared
// `RunProcedurePrimitive` it delegates to.
//
// ── Why the script spells it `subLlm`, not `sub.llm` ────────────────
//
// `sub` is the substrate-bridge global (`D4rtDcliHost.substrateGlobal`), so
// `sub.llm(...)` in a script parses as a *method call on the substrate
// bridge* — today's low-level completion. The high-level sugar must
// therefore be a distinct identifier, and d4rt registers engine-native
// primitives as bare top-level functions. So the sugar is bound as the
// camelCase token `subLlm` — which is exactly the dotted→camel call-token
// the catalog derives for the canonical `requires` name `sub.llm`
// (`callTokensFor('sub.llm') == {'sub.llm', 'subLlm'}`). The validator
// accepts either spelling as a call to the one primitive; the runtime
// routes `subLlm(...)` to this sugar and `sub.llm(...)` to the bridge
// method. The full rename (making `sub.llm` route to the sugar while the
// low-level moves to a bare `llm`) is steps 10–11; step 9 only adds the
// sugar, its catalog entry, and the validator wiring.
//
// What this suite locks:
//
//   F.9-1 — the catalog knows `sub.llm` with the dotted→camel call tokens.
//   F.9-2 — `subLlm(prompt, …)` from a script invokes `call_llm_v1` (the
//           default) with the merged inputs; a caller-supplied `procedure`
//           overrides the target id; omitted optional args are absent from
//           the inputs (so the template's defaults win downstream).
//   F.9-3 — `subLlm` from a frame already at the depth cap errors with
//           `RecursionLimitExceeded` (the cap is inherited, not re-checked).
//   F.9-4 — `subLlm` advances the chain exactly one level (depthDelta = 1),
//           so the nested run is recorded under — and its effort rolls up
//           to — the caller.
//   F.9-5 — a procedure declaring `requires: [sub.llm]` and calling
//           `subLlm(...)` passes the requires contract; an undeclared call
//           and an unused declaration are both rejected.

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show PreemptionState;

void main() {
  late MemoryBridge memoryBridge;
  late SubstrateBridge substrateBridge;

  setUp(() {
    memoryBridge = MemoryBridge(_StubMemoryClient(_StubStackApi()));
    substrateBridge = SubstrateBridge(_StubSubstrateClient());
  });

  // Boots a host whose native-primitive seam is filled by [primitive] (the
  // sugar shares this very `RunProcedurePrimitive`), plus inert note / yield
  // / emit primitives the installer also requires.
  D4rtDcliHost hostFor(RunProcedurePrimitive primitive) => D4rtDcliHost(
        memoryBridge: memoryBridge,
        substrateBridge: substrateBridge,
        installNativePrimitives: nativePrimitivesInstaller(
          runProcedurePrimitive: primitive,
          notePrimitive: NotePrimitive(sink: (_) {}),
          yieldPrimitive: YieldPrimitive(state: PreemptionState()),
          emitPrimitive: EmitPrimitive(),
        ),
      );

  /// A primitive that captures the single [ProcedureCall] the sugar makes
  /// and returns a succeeded result tagging the procedure it ran.
  ({RunProcedurePrimitive primitive, List<ProcedureCall> calls}) capturing({
    int startDepth = 1,
  }) {
    final calls = <ProcedureCall>[];
    final primitive = RunProcedurePrimitive(
      executor: (call) async {
        calls.add(call);
        return ProcedureResult.succeeded(
          outputs: <String, Object?>{'ran': call.id},
        );
      },
      startDepth: startDepth,
    );
    return (primitive: primitive, calls: calls);
  }

  group('F.9-1 catalog membership', () {
    test('sub.llm is a recognised primitive in the catalog', () {
      expect(BridgedPrimitiveCatalog.isKnown('sub.llm'), isTrue);
      expect(BridgedPrimitiveCatalog.all, contains('sub.llm'));
    });

    test('the dotted call token carries its camelCase spelling', () {
      expect(BridgedPrimitiveCatalog.callTokensFor('sub.llm'),
          <String>{'sub.llm', 'subLlm'});
    });

    test('the sugar is bound to the subLlm global / call_llm_v1 default', () {
      // The implementation constants the script + validator agree on.
      expect(scriptedLlmSugarName, 'subLlm');
      expect(defaultScriptedLlmProcedureId, 'call_llm_v1');
      expect(defaultScriptedLlmRole, 'assistant_to_user');
    });
  });

  group('F.9-2 subLlm invokes the named procedure with merged inputs', () {
    test('a bare subLlm(prompt) runs call_llm_v1 with prompt + default role',
        () async {
      final captured = capturing();
      final host = hostFor(captured.primitive);

      final result = await host.run(
        '''
import '$engineNativeLibrary';

run(inputs) async {
  return await $scriptedLlmSugarName('what is the time?');
}
''',
        inputs: <Object?>[ProcedureInputs.empty()],
      );

      expect(captured.calls, hasLength(1));
      final call = captured.calls.single;
      expect(call.id, 'call_llm_v1');
      // The merged inputs carry the prompt and the defaulted role; nothing
      // the caller did not supply.
      expect(call.inputs.get<String>('prompt'), 'what is the time?');
      expect(call.inputs.get<String>('role'), 'assistant_to_user');
      expect(call.inputs.has('tools'), isFalse);
      expect(call.inputs.has('mcpServers'), isFalse);
      expect(call.inputs.has('model'), isFalse);
      expect(call.inputs.has('budget'), isFalse);
      expect(call.inputs.has('procedure'), isFalse);

      // The executor's ProcedureResult threads back to the caller.
      expect(result, isA<ProcedureResult>());
      expect((result! as ProcedureResult).output<String>('ran'), 'call_llm_v1');
    });

    test('all named arguments merge into the inputs', () async {
      final captured = capturing();
      final host = hostFor(captured.primitive);

      await host.run(
        '''
import '$engineNativeLibrary';

run(inputs) async {
  return await $scriptedLlmSugarName(
    'summarise this',
    role: 'researcher',
    tools: ['web.search', 'web.fetch'],
    mcpServers: ['memory'],
    model: 'gemma3-27b',
    budget: {'toolCalls': 5, 'tokenSpend': 1000},
  );
}
''',
        inputs: <Object?>[ProcedureInputs.empty()],
      );

      final call = captured.calls.single;
      expect(call.id, 'call_llm_v1');
      expect(call.inputs.get<String>('prompt'), 'summarise this');
      expect(call.inputs.get<String>('role'), 'researcher');
      expect(call.inputs.get<List<String>>('tools'),
          <String>['web.search', 'web.fetch']);
      expect(call.inputs.get<List<String>>('mcpServers'), <String>['memory']);
      expect(call.inputs.get<String>('model'), 'gemma3-27b');
      expect(call.inputs.get<Map<String, Object?>>('budget'),
          <String, Object?>{'toolCalls': 5, 'tokenSpend': 1000});
    });

    test('a caller-supplied procedure overrides the call_llm_v1 default',
        () async {
      final captured = capturing();
      final host = hostFor(captured.primitive);

      await host.run(
        '''
import '$engineNativeLibrary';

run(inputs) async {
  return await $scriptedLlmSugarName(
    'plan a trip',
    procedure: 'plan_with_tools_v1',
  );
}
''',
        inputs: <Object?>[ProcedureInputs.empty()],
      );

      final call = captured.calls.single;
      expect(call.id, 'plan_with_tools_v1');
      // `procedure` selects the target — it is not itself an input.
      expect(call.inputs.has('procedure'), isFalse);
      expect(call.inputs.get<String>('prompt'), 'plan a trip');
    });

    test('a non-String prompt throws out of the script call', () async {
      final captured = capturing();
      final host = hostFor(captured.primitive);

      await expectLater(
        host.run(
          '''
import '$engineNativeLibrary';

run(inputs) async {
  return await $scriptedLlmSugarName(42);
}
''',
          inputs: <Object?>[ProcedureInputs.empty()],
        ),
        throwsA(
          predicate<Object>(
            (e) => e.toString().contains('prompt must be a String'),
          ),
        ),
      );
      expect(captured.calls, isEmpty);
    });
  });

  group('F.9-3 depth cap is inherited (PE-3)', () {
    test('subLlm from a frame at the cap errors RecursionLimitExceeded',
        () async {
      // startDepth at the hard cap → the sugar's depthDelta-1 call is over
      // the line, exactly as a direct runProcedure would be.
      final captured =
          capturing(startDepth: RunProcedurePrimitive.defaultHardDepthCap);
      final host = hostFor(captured.primitive);

      await expectLater(
        host.run(
          '''
import '$engineNativeLibrary';

run(inputs) async {
  return await $scriptedLlmSugarName('over the cap');
}
''',
          inputs: <Object?>[ProcedureInputs.empty()],
        ),
        throwsA(isA<RecursionLimitExceeded>()),
      );
      // The cap is checked before the executor runs — no call was made.
      expect(captured.calls, isEmpty);
    });
  });

  group('F.9-4 the nested run rolls up to the caller (PE-4)', () {
    test('subLlm advances the chain exactly one level (depthDelta = 1)',
        () async {
      // Caller runs at depth 1; the sugar must target depth 2 — a single
      // nested frame under the caller, which is what makes its effort roll
      // up to the caller's run rather than start a new top-level frame.
      final captured = capturing();
      final host = hostFor(captured.primitive);

      await host.run(
        '''
import '$engineNativeLibrary';

run(inputs) async {
  return await $scriptedLlmSugarName('one level deeper');
}
''',
        inputs: <Object?>[ProcedureInputs.empty()],
      );

      expect(captured.calls.single.depth, 2);
    });
  });

  group('F.9-5 the requires contract accepts sub.llm', () {
    const validator = ContractValidator.shared;

    ProcedureHeader header(List<String> requires) => ProcedureHeader(
          id: 'caller_v1',
          version: 1,
          summary: 'summary',
          successCriterion: 'criterion',
          budget: ProcedureBudget(const {'wallClockMs': 60000}),
          requires: requires,
        );

    const body = '''
Future<ProcedureResult> run(ProcedureInputs inputs) async {
  return await subLlm('go', role: 'assistant_to_user');
}
''';

    test('requires: [sub.llm] matches a subLlm(...) call', () {
      expect(
        () => validator.validateRequires(header(const ['sub.llm']), body),
        returnsNormally,
      );
    });

    test('calling subLlm without declaring sub.llm is an undeclared call', () {
      expect(
        () => validator.validateRequires(header(const <String>[]), body),
        throwsA(isA<ProcedureRequiresMismatch>()
            .having((e) => e.kind, 'kind',
                RequiresMismatchKind.undeclaredCall)
            .having((e) => e.offender, 'offender', 'sub.llm')),
      );
    });

    test('declaring sub.llm without calling it is an unused require', () {
      const noCall = '''
Future<ProcedureResult> run(ProcedureInputs inputs) async {
  return ProcedureResult.succeeded();
}
''';
      expect(
        () => validator.validateRequires(header(const ['sub.llm']), noCall),
        throwsA(isA<ProcedureRequiresMismatch>()
            .having((e) => e.kind, 'kind', RequiresMismatchKind.unusedRequire)
            .having((e) => e.offender, 'offender', 'sub.llm')),
      );
    });
  });
}

// ── Bridge doubles (only to satisfy the host constructor) ────────────
//
// The sugar scripts call `subLlm`, never `mem` / `sub`, so the doubles fall
// through to `noSuchMethod`.

class _StubMemoryClient implements TomBrainMemoryClient {
  _StubMemoryClient(this._stacks);
  final _StubStackApi _stacks;

  @override
  StackApi get stacks => _stacks;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _StubStackApi implements StackApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _StubSubstrateClient implements TomBrainSubstrateClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
