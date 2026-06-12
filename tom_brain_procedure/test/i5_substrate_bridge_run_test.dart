// Increment 5 (prompt_configuration.md §7.1 / §7.4) — `sub.run`: the high-level,
// ID-driven prompt entry point.
//
// `run` is the routing seam's *high* half. Where `send` issues one completion
// over a named route, `run` resolves a *registered prompt by id* to its
// inherited settings + loaded, placeholder-resolved template (via the injected
// `PromptResolver`), renders the one placeholder it owns (`${tools.catalogue}`),
// assembles the initial transcript, then **delegates the send→parse→execute→
// re-send loop** to `scripts/system/tool_loop_v1.dart` via the injected
// `ProcedureRunner`. `run` does NOT implement the loop — it owns only the
// Dart-side resolution.
//
// What this suite pins:
//
//   1. A registered prompt resolves through the `PromptResolver`, renders
//      `${tools.catalogue}` from the resolved tool set, and delegates to
//      `tool_loop_v1` with the resolved settings (transcript / route / role /
//      tools / maxToolLoops / temperature), returning `{answer,
//      toolLoopExhausted}` from the loop's result.
//   2. `temperature` is forwarded only when the resolved prompt sets it.
//   3. The `none` profile (empty tool set) renders the catalogue marker away to
//      the empty string.
//   4. An unregistered id (resolver returns `null`) throws
//      `UnregisteredPromptException`.
//   5. With no `PromptResolver` bound, `run` throws a `StateError` (a wiring
//      bug — it cannot resolve).
//   6. With no `ProcedureRunner` bound, `run` throws a `StateError` (a wiring
//      bug — it cannot delegate).

import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';
import 'package:test/test.dart';

void main() {
  late _FakeSubstrateClient client;

  setUp(() {
    client = _FakeSubstrateClient();
  });

  group('§7.4 SubstrateBridge.run — ID-driven prompt entry point', () {
    test(
        'resolves, renders the tool catalogue, and delegates to tool_loop_v1 '
        'with the resolved settings', () async {
      String? resolvedId;
      Map<String, Object?>? resolvedInputs;
      final resolved = ResolvedPrompt(
        role: 'sub_thinker',
        llmRoute: 'deep',
        templateBody: 'Question: hi\n\n\${tools.catalogue}\n\nAnswer:',
        tools: const <Object?>[
          <String, Object?>{
            'name': 'memory.search',
            'description': 'search memory',
            'input_schema': <String, Object?>{
              'properties': <String, Object?>{
                'query': <String, Object?>{'type': 'string'},
              },
              'required': <Object?>['query'],
            },
          },
        ],
        maxToolLoops: 4,
        temperature: 0.3,
      );

      String? ranProcedureId;
      ProcedureInputs? ranInputs;
      final bridge = SubstrateBridge(
        client,
        promptResolver: (id, inputs) async {
          resolvedId = id;
          resolvedInputs = inputs;
          return resolved;
        },
        runProcedure: (procedureId, inputs) async {
          ranProcedureId = procedureId;
          ranInputs = inputs;
          return ProcedureResult.succeeded(
            outputs: const <String, Object?>{
              'answer': 'the final answer',
              'toolLoopExhausted': false,
            },
          );
        },
      );

      final out = await bridge.run(
        'assist_user.answer_with_memory.assembly',
        inputs: const <String, Object?>{'prompt': 'hi'},
      );

      // The resolver was consulted with the id and the placeholder inputs.
      expect(resolvedId, 'assist_user.answer_with_memory.assembly');
      expect(resolvedInputs, <String, Object?>{'prompt': 'hi'});

      // The loop procedure was the shared tool_loop_v1.
      expect(ranProcedureId, SubstrateBridge.toolLoopProcedureId);
      expect(ranProcedureId, 'tool_loop_v1');

      // The resolved settings rode onto the loop inputs.
      final loopInputs = ranInputs!;
      expect(loopInputs.get<String>('route'), 'deep');
      expect(loopInputs.get<String>('role'), 'sub_thinker');
      expect(loopInputs.get<int>('maxToolLoops'), 4);
      expect(loopInputs.get<double>('temperature'), 0.3);
      expect(loopInputs.get<List<Object?>>('tools'), resolved.tools);

      // `${tools.catalogue}` was rendered into a "Tools available" block naming
      // the resolved tool; the marker is gone.
      final transcript = loopInputs.get<String>('transcript');
      expect(transcript, isNot(contains(r'${tools.catalogue}')));
      expect(transcript, contains('memory.search'));
      expect(transcript, contains('call:'));

      // The loop's outputs are surfaced verbatim.
      expect(out['answer'], 'the final answer');
      expect(out['toolLoopExhausted'], false);
    });

    test('forwards temperature only when the resolved prompt sets it', () async {
      ProcedureInputs? ranInputs;
      final bridge = SubstrateBridge(
        client,
        promptResolver: (_, _) async => const ResolvedPrompt(
          role: 'assistant_to_user',
          llmRoute: 'fast',
          templateBody: 'body',
          // No temperature.
        ),
        runProcedure: (_, inputs) async {
          ranInputs = inputs;
          return ProcedureResult.succeeded(
            outputs: const <String, Object?>{'answer': 'ok'},
          );
        },
      );

      await bridge.run('p');

      expect(ranInputs!.has('temperature'), isFalse);
    });

    test('renders the catalogue marker away for the none profile (no tools)',
        () async {
      ProcedureInputs? ranInputs;
      final bridge = SubstrateBridge(
        client,
        promptResolver: (_, _) async => const ResolvedPrompt(
          role: 'assistant_to_user',
          llmRoute: 'fast',
          templateBody: 'before \${tools.catalogue} after',
          tools: <Object?>[],
        ),
        runProcedure: (_, inputs) async {
          ranInputs = inputs;
          return ProcedureResult.succeeded(
            outputs: const <String, Object?>{'answer': 'ok'},
          );
        },
      );

      await bridge.run('p');

      // The empty tool set renders the marker to the empty string.
      expect(ranInputs!.get<String>('transcript'), 'before  after');
    });

    test('throws UnregisteredPromptException when the resolver returns null',
        () {
      final bridge = SubstrateBridge(
        client,
        promptResolver: (_, _) async => null,
        runProcedure: (_, _) async =>
            ProcedureResult.succeeded(outputs: const <String, Object?>{}),
      );

      expect(
        () => bridge.run('no.such.prompt'),
        throwsA(isA<UnregisteredPromptException>().having(
          (e) => e.promptId,
          'promptId',
          'no.such.prompt',
        )),
      );
    });

    test('throws StateError when no PromptResolver is bound', () {
      final bridge = SubstrateBridge(
        client,
        runProcedure: (_, _) async =>
            ProcedureResult.succeeded(outputs: const <String, Object?>{}),
      );

      expect(
        () => bridge.run('p'),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('sub.run requires a PromptResolver'),
        )),
      );
    });

    test('throws StateError when no ProcedureRunner is bound', () {
      final bridge = SubstrateBridge(
        client,
        promptResolver: (_, _) async => const ResolvedPrompt(
          role: 'assistant_to_user',
          llmRoute: 'fast',
          templateBody: 'body',
        ),
      );

      expect(
        () => bridge.run('p'),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('sub.run requires a ProcedureRunner'),
        )),
      );
    });
  });
}

/// Fake `TomBrainSubstrateClient` — `run` never issues a completion itself (it
/// delegates the loop), so the client only has to satisfy the constructor.
class _FakeSubstrateClient implements TomBrainSubstrateClient {
  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) =>
      const Stream<LlmStreamEvent>.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
