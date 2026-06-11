// C.46 — Phase-C code-review-pass attestation suite.
//
// Plan step C.46 ("Code review pass C1: every file vs. the spec section
// that owns it. Flag divergences."). The review pass produced a divergence
// report (recorded in `prototype_implementation_details.md` § C.46); this
// suite is the *sentinel* that pins the review's structural conclusions as
// code, mirroring the substrate B.43 spec-table-attestation precedent.
//
// The motivation: each closed set the review confirmed has its own per-step
// test elsewhere (C.22 the recursion cap, C.30 the validator branches, C.43
// the log categories, C.44 the event taxonomy, C.33 the effort metrics). No
// single test crosses all of them into one "did the spec drift from the
// code?" attestation. If a future change drops a metric, renames a category,
// reorders the event sum, or alters a validator wire code, this suite fails
// before any per-step test does, with a message that names the spec section.
//
// Drives the package's public barrel only (no `lib/src/` imports), per the
// plan's "API tests" convention.

import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart' show TrailOutcomeStatus;
import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show EffortMetrics;

final DateTime _at = DateTime.utc(2026, 6, 2, 10, 30, 0);

void main() {
  // §8 / PE-4 — the run recorder persists the closed seven-metric set.
  group('C.46-1: §8/PE-4 effort-metric closed set', () {
    // Spec § 8 / PE-4: "the closed effort-metric set (wallClockMs, llmCalls,
    // inputTokens, outputTokens, toolCalls, memoryReads, memoryWrites)".
    const expected = <String>{
      'wallClockMs',
      'llmCalls',
      'inputTokens',
      'outputTokens',
      'toolCalls',
      'memoryReads',
      'memoryWrites',
    };

    test('toJson surfaces exactly the seven spec metrics (plus the derived '
        'estimatedTokens)', () {
      final keys = EffortMetrics.zero.toJson().keys.toSet();
      // The seven canonical metrics are all present.
      expect(keys.containsAll(expected), isTrue,
          reason: 'a spec § 8 effort metric is missing from EffortMetrics');
      // The only key beyond the seven is the derived `estimatedTokens`
      // (spec § 8: "primary estimation metric = inputTokens + outputTokens").
      expect(keys.difference(expected), equals(<String>{'estimatedTokens'}),
          reason: 'EffortMetrics gained a metric outside the spec § 8 set');
    });

    test('the derived estimatedTokens equals inputTokens + outputTokens', () {
      final m = EffortMetrics(inputTokens: 30, outputTokens: 12);
      expect(m.toJson()['estimatedTokens'], 42);
    });
  });

  // §13 — engine logger categories.
  group('C.46-2: §13 EngineLog category closed set', () {
    // Spec § 13: "engine — tom_brain.engine.host, …bridge, …store,
    // …recorder, …preemption".
    const expected = <String>[
      'tom_brain.engine.host',
      'tom_brain.engine.bridge',
      'tom_brain.engine.store',
      'tom_brain.engine.recorder',
      'tom_brain.engine.preemption',
    ];

    test('exactly the five spec categories, in spec order', () {
      final names =
          EngineLogCategory.values.map((c) => c.name).toList(growable: false);
      expect(names, equals(expected));
    });

    test('EngineLog.all mirrors the enum 1:1', () {
      expect(EngineLog.all.length, EngineLogCategory.values.length);
      expect(
        EngineLog.all.map((l) => l.category.name).toList(growable: false),
        equals(expected),
      );
    });
  });

  // §13 — engine event taxonomy.
  group('C.46-3: §13 EngineEvent sealed-sum closed set', () {
    // Spec § 13: "EngineEvent (InvocationStarted, PrimitiveCalled,
    // StepYielded, InvocationCompleted, InvocationFailed)".
    List<EngineEvent> oneOfEach() => <EngineEvent>[
          InvocationStarted(
              occurredAt: _at, runId: 'r', procedureId: 'p', depth: 1),
          PrimitiveCalled(
              occurredAt: _at, runId: 'r', primitive: 'recall', depth: 1),
          StepYielded(
              occurredAt: _at,
              runId: 'r',
              reason: StepYielded.foregroundWaitingReason,
              truncated: false),
          InvocationCompleted(
              occurredAt: _at,
              runId: 'r',
              procedureId: 'p',
              status: TrailOutcomeStatus.accepted),
          InvocationFailed(
              occurredAt: _at,
              runId: 'r',
              procedureId: 'p',
              failureKind: 'procedure.runtime.crash',
              message: 'boom'),
        ];

    test('the sum stays closed at five variants', () {
      // Exhaustive switch with no default: adding or removing a leaf breaks
      // compilation, and dropping one here fails the length assertion.
      for (final e in oneOfEach()) {
        final tag = switch (e) {
          InvocationStarted() => 'started',
          PrimitiveCalled() => 'primitive',
          StepYielded() => 'yielded',
          InvocationCompleted() => 'completed',
          InvocationFailed() => 'failed',
        };
        expect(tag, isNotEmpty);
      }
      expect(oneOfEach().length, 5);
    });

    test('each variant carries its canonical engine.<name> kind, all unique',
        () {
      final kinds = oneOfEach().map((e) => e.kind).toList(growable: false);
      expect(kinds, <String>[
        'engine.invocation-started',
        'engine.primitive-called',
        'engine.step-yielded',
        'engine.invocation-completed',
        'engine.invocation-failed',
      ]);
      expect(kinds.toSet().length, kinds.length, reason: 'kinds must be unique');
      expect(kinds.every((k) => k.startsWith('engine.')), isTrue);
    });
  });

  // §7 — validator failure taxonomy.
  group('C.46-4: §7 validator failure-code taxonomy', () {
    // Spec § 7 lists five checks. FOUR are surfaced as typed wire codes in
    // `lib/`; the fifth — "d4rt source parses" → procedure.parse.failed — is
    // deliberately delegated to the host's d4rt interpreter (spec § 14 row
    // attributes its detection to the "d4rt parser"), NOT to a typed validator
    // code. Q-C.46.1 resolved that delegation by surfacing the parse failure at
    // the host/engine seam (the host raises `ProcedureSourceParseException`,
    // the engine records `procedure.parse.failed`), so the parse failure IS now
    // a typed, classified outcome — it is simply not a *validator* code. This
    // group pins the four validator codes that DO exist so a future change to
    // any of them fails loudly here.
    test('the four typed validator codes match the spec strings verbatim', () {
      expect(procedureHeaderInvalidCode, 'procedure.header.invalid');
      expect(procedureSandboxViolationCode, 'procedure.sandbox.violation');
      expect(procedureContractInvalidCode, 'procedure.contract.invalid');
      expect(procedureRequiresMismatchCode, 'procedure.requires.mismatch');
    });

    test('the four codes are distinct and namespaced under procedure.', () {
      const codes = <String>{
        procedureHeaderInvalidCode,
        procedureSandboxViolationCode,
        procedureContractInvalidCode,
        procedureRequiresMismatchCode,
      };
      expect(codes.length, 4);
      expect(codes.every((c) => c.startsWith('procedure.')), isTrue);
      // procedure.parse.failed is not a *validator* code: it is surfaced at
      // the host/engine seam, not the static validator (Q-C.46.1). This guard
      // pins that boundary — the validator taxonomy stays the four static
      // checks; the parse failure lives with the d4rt parser per spec § 14.
      expect(codes.contains('procedure.parse.failed'), isFalse);
    });

    test('ProcedureNotFound carries its informative wire code (§ 14)', () {
      expect(procedureNotFoundCode, 'procedure.not_found');
    });
  });

  // PE-3 — recursion hard cap.
  group('C.46-5: PE-3 recursion hard cap', () {
    test('the default hard depth cap is 1000 (effectively unlimited)', () {
      expect(RunProcedurePrimitive.defaultHardDepthCap, 1000);
    });
  });

  // §5.2 — sugar-alias verb set.
  group('C.46-6: §5.2 sugar-alias verb set', () {
    // Spec § 5.2: think/plan/create/critique/decide are aliases over
    // runProcedure('<name>_v1', …); only think_v1 is real in the prototype.
    test('exactly the five spec verbs, each forwarding to <verb>_v1', () {
      expect(sugarAliasProcedureIds, <String, String>{
        'think': 'think_v1',
        'plan': 'plan_v1',
        'create': 'create_v1',
        'critique': 'critique_v1',
        'decide': 'decide_v1',
      });
    });
  });
}
