// C.22 — consolidated acceptance suite for the three engine-native
// primitives (Plan step C.22;
// `tom_brain_procedure_specification.md` § 5.1, § 8, § 9;
// `tom_brain_definition.md` § 7.3, PE-3 / PE-5).
//
// Plan step C.22 (verbatim): "Tests: depth cap honoured (11th level errors
// with `RecursionLimitExceeded`); note appears in the trail with the right
// category; yield returns immediately when no foreground is waiting and
// suspends when one is."
//
// C.19–C.21 each shipped their own unit + d4rt-wiring tests. This file is
// the *consolidation* step the plan asks for: it drives all three
// primitives **end-to-end through the `D4rtDcliHost`** (the surface a real
// procedure script sees), pins the three headline facts named in the plan
// against the real production constants (the hard cap of 10, the
// `automation_candidate` category, the live `PreemptionState`), and proves
// the three primitives coexist in one host running one script.
//
// The "trail" `note` writes into is modelled here by a list-backed
// `TrailSink` — the exact seam the `RunRecorder` (C.31) fills with the
// run's open trail. C.22 stops at the seam (the recorder is a later step),
// so a collecting sink standing in for the trail is the correct depth of
// test at this point.

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show PreemptionState;

void main() {
  late MemoryBridge memoryBridge;
  late SubstrateBridge substrateBridge;

  setUp(() {
    memoryBridge = MemoryBridge(_StubMemoryClient(_StubStackApi()));
    substrateBridge = SubstrateBridge(_StubSubstrateClient());
  });

  // Boots a host whose engine-native seam is filled by the three given
  // primitives. Any primitive omitted gets an inert default (a never-firing
  // runProcedure executor, a discarding note sink, an idle preemption
  // state) so a test only has to construct the primitive it exercises.
  D4rtDcliHost hostWith({
    RunProcedurePrimitive? runProcedure,
    NotePrimitive? note,
    YieldPrimitive? yieldPrimitive,
    EmitPrimitive? emit,
  }) =>
      D4rtDcliHost(
        memoryBridge: memoryBridge,
        substrateBridge: substrateBridge,
        installNativePrimitives: nativePrimitivesInstaller(
          runProcedurePrimitive: runProcedure ??
              RunProcedurePrimitive(
                executor: (call) async => ProcedureResult.succeeded(),
              ),
          notePrimitive: note ?? NotePrimitive(sink: (_) {}),
          yieldPrimitive:
              yieldPrimitive ?? YieldPrimitive(state: PreemptionState()),
          emitPrimitive: emit ?? EmitPrimitive(),
        ),
      );

  // ── Clause 1: depth cap honoured (11th level errors) ────────────────
  //
  // PE-3, against the real production cap of 10. A script calls
  // `runProcedure`; the injected executor models a procedure that
  // re-enters itself on the same primitive, so the chain deepens one level
  // per frame. Depths 2..10 execute (the top-level frame the host invokes
  // is depth 1); the call that would run at depth 11 — "the 11th level" —
  // is refused with `RecursionLimitExceeded`, which surfaces out of the
  // script call.
  group('C.22 — depth cap honoured (PE-3)', () {
    test('a self-re-entering chain reaches depth 10 then the 11th level '
        'errors with RecursionLimitExceeded, surfaced out of the script',
        () async {
      late RunProcedurePrimitive primitive;
      var deepestExecuted = 0;
      primitive = RunProcedurePrimitive(
        executor: (call) async {
          deepestExecuted = call.depth;
          // Re-enter on the same primitive until the cap stops the chain.
          return primitive.runProcedure(call.id, call.inputs);
        },
      );
      final host = hostWith(runProcedure: primitive);

      await expectLater(
        host.run(
          '''
import '$engineNativeLibrary';

run(inputs) async {
  return await runProcedure('recurse_v1', inputs);
}
''',
          inputs: <Object?>[ProcedureInputs.empty()],
        ),
        throwsA(isA<RecursionLimitExceeded>()),
      );

      // The deepest frame that actually ran is the cap itself (10); the
      // 11th was refused before the executor saw it.
      expect(deepestExecuted, 10);
      expect(deepestExecuted, RunProcedurePrimitive.defaultHardDepthCap);
    });

    test('the refused 11th-level call carries the attempted depth (11), the '
        'cap (10), and the target id', () async {
      // startDepth pinned at the cap → the script's first call is already
      // over the line, so the error fields are deterministic.
      final primitive = RunProcedurePrimitive(
        executor: (call) async => ProcedureResult.succeeded(),
        startDepth: RunProcedurePrimitive.defaultHardDepthCap,
      );
      final host = hostWith(runProcedure: primitive);

      try {
        await host.run(
          '''
import '$engineNativeLibrary';

run(inputs) async {
  return await runProcedure('over_cap_v1', inputs);
}
''',
          inputs: <Object?>[ProcedureInputs.empty()],
        );
        fail('expected RecursionLimitExceeded to surface out of the script');
      } on RecursionLimitExceeded catch (e) {
        expect(e.attemptedDepth, 11);
        expect(e.hardDepthCap, RunProcedurePrimitive.defaultHardDepthCap);
        expect(e.procedureId, 'over_cap_v1');
        expect(e.toString(), contains('over_cap_v1'));
      }
    });
  });

  // ── Clause 2: note appears in the trail with the right category ─────
  //
  // The `TrailSink` is bound to a list standing in for the run's open
  // trail (the recorder's seam, C.31). A script calls `note`; the note must
  // appear in the trail, carrying its category — including the well-known
  // `automation_candidate` category by which a script surfaces an
  // automation idea to the dispatcher's harvester.
  group('C.22 — note appears in the trail with the right category', () {
    test('a note from a script lands in the trail with the '
        'automation_candidate category and its payload', () async {
      final trail = <TrailNote>[];
      final host = hostWith(note: NotePrimitive(sink: trail.add));

      await host.run(
        '''
import '$engineNativeLibrary';

run(inputs) {
  note('automation_candidate', {'why': 'repeated prompt', 'count': 3});
}
''',
        inputs: <Object?>[ProcedureInputs.empty()],
      );

      expect(trail, hasLength(1));
      expect(trail.single.category, automationCandidateCategory);
      expect(trail.single.payload['why'], 'repeated prompt');
      expect(trail.single.payload['count'], 3);
    });

    test('a free-form category is preserved verbatim in the trail', () async {
      final trail = <TrailNote>[];
      final host = hostWith(note: NotePrimitive(sink: trail.add));

      await host.run(
        '''
import '$engineNativeLibrary';

run(inputs) {
  note('observation', {'k': 'v'});
}
''',
        inputs: <Object?>[ProcedureInputs.empty()],
      );

      expect(trail.single.category, 'observation');
    });

    test('multiple notes land in the trail in call order', () async {
      final trail = <TrailNote>[];
      final host = hostWith(note: NotePrimitive(sink: trail.add));

      await host.run(
        '''
import '$engineNativeLibrary';

run(inputs) {
  note('first', {'n': 1});
  note('second', {'n': 2});
  note('third', {'n': 3});
}
''',
        inputs: <Object?>[ProcedureInputs.empty()],
      );

      expect(
        trail.map((n) => n.category).toList(),
        <String>['first', 'second', 'third'],
      );
      expect(trail.map((n) => n.payload['n']).toList(), <int>[1, 2, 3]);
    });
  });

  // ── Clause 3: yield returns immediately / suspends as required ──────
  //
  // Both branches end-to-end through the host, against the live
  // `PreemptionState` the coordinator (C.34) will drive.
  group('C.22 — yield_if_foreground_waiting', () {
    test('returns immediately when no foreground is waiting — the script '
        'runs straight past the checkpoint', () async {
      final state = PreemptionState();
      final host = hostWith(yieldPrimitive: YieldPrimitive(state: state));

      final result = await host.run(
        '''
import '$engineNativeLibrary';

run(inputs) async {
  await yield_if_foreground_waiting();
  return 'past the checkpoint';
}
''',
        inputs: <Object?>[ProcedureInputs.empty()],
      );

      expect(result, 'past the checkpoint');
    });

    test('suspends at the checkpoint while a foreground is waiting and '
        'resumes only after the coordinator signals resume', () async {
      final state = PreemptionState()..requestForegroundPreemption();
      final host = hostWith(yieldPrimitive: YieldPrimitive(state: state));

      var completed = false;
      final running = host.run(
        '''
import '$engineNativeLibrary';

run(inputs) async {
  await yield_if_foreground_waiting();
  return 'resumed';
}
''',
        inputs: <Object?>[ProcedureInputs.empty()],
      ).then((value) {
        completed = true;
        return value;
      });

      // Let the script reach and park on the checkpoint; it must not
      // complete while the foreground run is still waiting.
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse,
          reason: 'the script must suspend at the checkpoint');

      // The coordinator finishes the foreground run → the parked script
      // resumes and completes.
      state.signalResume();
      expect(await running, 'resumed');
      expect(completed, isTrue);
    });
  });

  // ── The three primitives coexist in one host running one script ─────
  //
  // The consolidation the plan asks for: a single procedure script uses
  // `note`, `yield_if_foreground_waiting`, and `runProcedure` together on
  // one host. Proves the installer wires all three side by side, that a
  // note taken before a (no-op) yield checkpoint reaches the trail, and
  // that a depth-respecting runProcedure call returns its result — all in
  // one run.
  group('C.22 — the three primitives in one script', () {
    test('note + yield + runProcedure run together on one host', () async {
      final trail = <TrailNote>[];
      ProcedureCall? delegated;
      final runProcedure = RunProcedurePrimitive(
        executor: (call) async {
          delegated = call;
          return ProcedureResult.succeeded(
            outputs: <String, Object?>{'answer': '42'},
          );
        },
      );
      final host = hostWith(
        runProcedure: runProcedure,
        note: NotePrimitive(sink: trail.add),
        yieldPrimitive: YieldPrimitive(state: PreemptionState()),
      );

      final result = await host.run(
        '''
import '$engineNativeLibrary';

run(inputs) async {
  note('automation_candidate', {'why': 'all three together'});
  await yield_if_foreground_waiting();
  return await runProcedure('think_v1', inputs);
}
''',
        inputs: <Object?>[ProcedureInputs.empty()],
      );

      // note reached the trail with the right category.
      expect(trail, hasLength(1));
      expect(trail.single.category, automationCandidateCategory);

      // yield did not block (idle state) and runProcedure ran at depth 2.
      expect(delegated!.id, 'think_v1');
      expect(delegated!.depth, 2);

      // The runProcedure result flowed back out of the script.
      expect(result, isA<ProcedureResult>());
      expect((result! as ProcedureResult).output<String>('answer'), '42');
    });
  });
}

// ── Bridge doubles (only to satisfy the host constructor) ────────────
//
// The C.22 scripts call the engine-native primitives, never `mem` / `sub`,
// so these doubles only need to exist; their methods fall through to
// `noSuchMethod`.

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
