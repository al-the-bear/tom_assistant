// Q-C.51.1 — BudgetLedger unit tests.
//
// PE-8 makes a bridged call that would exceed an applicable budget refuse
// with a typed `procedure.budget.exceeded`. The `BudgetLedger` is the
// per-run bookkeeper that enforces the three non-wall-clock dimensions of a
// procedure-header budget (§ 4.4 / § 5.4): `tokenSpend`, `toolCalls`,
// `memoryWrites`. Wall-clock is owned by the `StepDeadline`, never the
// ledger.
//
// The ledger reuses the `EffortAccountant` so its accounting and the run
// recorder's effort tally are the same classification, never two rules that
// can drift. These tests pin the enforcement model:
//
//   - count dimensions (`toolCalls`, `memoryWrites`) are refused *before*
//     the side effect — the call's unit is known from its name;
//   - `tokenSpend` can only be refused once the budget is *already* spent —
//     an `llm` call's token cost is unknowable before it runs, so the
//     honest gate is "refuse the next call once we are at/over the cap";
//   - `defaultFallbackClassifier` never steps the version chain on a
//     budget refusal (a refusal is a deliberate stop, not a crash).

import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show EffortMetrics;
import 'package:test/test.dart';

void main() {
  ProcedureBudget budget(Map<String, int> caps) => ProcedureBudget(caps);

  group('Q-C.51.1 BudgetLedger.enforces', () {
    test('a budget with only wallClockMs enforces nothing', () {
      final ledger = BudgetLedger(budget(<String, int>{'wallClockMs': 60000}));
      expect(ledger.enforces, isFalse);
      // check is a no-op for every primitive when nothing is enforced.
      expect(() => ledger.check('embed'), returnsNormally);
      expect(() => ledger.check('persist'), returnsNormally);
      expect(() => ledger.check('llm'), returnsNormally);
    });

    test('a budget with any of the three caps enforces', () {
      expect(BudgetLedger(budget(<String, int>{'toolCalls': 1})).enforces, isTrue);
      expect(
          BudgetLedger(budget(<String, int>{'memoryWrites': 1})).enforces, isTrue);
      expect(
          BudgetLedger(budget(<String, int>{'tokenSpend': 1})).enforces, isTrue);
    });
  });

  group('Q-C.51.1 toolCalls budget', () {
    test('allows exactly the cap, refuses the call that would exceed it', () {
      final ledger = BudgetLedger(budget(<String, int>{'toolCalls': 2}));

      // Two tool calls fit: check passes, charge folds each in.
      ledger.check('embed');
      ledger.charge('embed');
      ledger.check('search');
      ledger.charge('search');
      expect(ledger.consumed.toolCalls, 2);

      // The third would exceed — refused before the side effect.
      expect(
        () => ledger.check('fetch'),
        throwsA(
          isA<ProcedureBudgetExceeded>()
              .having((e) => e.dimension, 'dimension', BudgetDimension.toolCalls)
              .having((e) => e.limit, 'limit', 2)
              .having((e) => e.consumed, 'consumed', 2)
              .having((e) => e.primitive, 'primitive', 'fetch'),
        ),
      );
    });

    test('a non-tool primitive never trips the toolCalls cap', () {
      final ledger = BudgetLedger(budget(<String, int>{'toolCalls': 0}));
      // recall is a read, persist a write, note free — none is a tool call,
      // so a zero tool budget does not refuse them.
      expect(() => ledger.check('recall'), returnsNormally);
      expect(() => ledger.check('persist'), returnsNormally);
      expect(() => ledger.check('note'), returnsNormally);
      // But a tool call is refused immediately at a zero cap.
      expect(() => ledger.check('embed'),
          throwsA(isA<ProcedureBudgetExceeded>()));
    });
  });

  group('Q-C.51.1 memoryWrites budget', () {
    test('allows exactly the cap, refuses the write that would exceed it', () {
      final ledger = BudgetLedger(budget(<String, int>{'memoryWrites': 1}));

      ledger.check('persist');
      ledger.charge('persist');
      expect(ledger.consumed.memoryWrites, 1);

      expect(
        () => ledger.check('edge'),
        throwsA(
          isA<ProcedureBudgetExceeded>()
              .having(
                  (e) => e.dimension, 'dimension', BudgetDimension.memoryWrites)
              .having((e) => e.limit, 'limit', 1)
              .having((e) => e.consumed, 'consumed', 1)
              .having((e) => e.primitive, 'primitive', 'edge'),
        ),
      );
    });

    test('a read does not count against the write cap', () {
      final ledger = BudgetLedger(budget(<String, int>{'memoryWrites': 0}));
      expect(() => ledger.check('recall'), returnsNormally);
      expect(() => ledger.check('stackPeek'), returnsNormally);
      expect(() => ledger.check('persist'),
          throwsA(isA<ProcedureBudgetExceeded>()));
    });
  });

  group('Q-C.51.1 tokenSpend budget', () {
    test('the first llm call is allowed even when it overshoots', () {
      // Token cost is unknowable before the call, so the gate cannot pre-empt
      // an overshoot: the first call runs, and only the *next* one is refused
      // once the budget is spent.
      final ledger = BudgetLedger(budget(<String, int>{'tokenSpend': 100}));

      ledger.check('llm'); // consumed 0 < 100 → allowed
      ledger.charge('llm', result: <String, Object?>{
        'report': <String, Object?>{'tokensIn': 80, 'tokensOut': 80},
      });
      expect(ledger.consumed.estimatedTokens, 160);

      expect(
        () => ledger.check('llm'),
        throwsA(
          isA<ProcedureBudgetExceeded>()
              .having((e) => e.dimension, 'dimension', BudgetDimension.tokenSpend)
              .having((e) => e.limit, 'limit', 100)
              .having((e) => e.consumed, 'consumed', 160)
              .having((e) => e.primitive, 'primitive', 'llm'),
        ),
      );
    });

    test('a call that stays under the cap leaves the next call allowed', () {
      final ledger = BudgetLedger(budget(<String, int>{'tokenSpend': 1000}));
      ledger.check('llm');
      ledger.charge('llm', result: <String, Object?>{
        'report': <String, Object?>{'tokensIn': 100, 'tokensOut': 100},
      });
      expect(() => ledger.check('llm'), returnsNormally);
    });

    test('a non-llm primitive never trips the token cap', () {
      final ledger = BudgetLedger(budget(<String, int>{'tokenSpend': 0}));
      expect(() => ledger.check('embed'), returnsNormally);
      expect(() => ledger.check('recall'), returnsNormally);
      // An llm call is refused at a zero token cap (already at the limit).
      expect(() => ledger.check('llm'),
          throwsA(isA<ProcedureBudgetExceeded>()));
    });
  });

  group('Q-C.51.1 independent dimensions', () {
    test('each cap is enforced against its own counter only', () {
      final ledger = BudgetLedger(budget(<String, int>{
        'toolCalls': 1,
        'memoryWrites': 1,
      }));
      // One tool + one write both fit.
      ledger.check('embed');
      ledger.charge('embed');
      ledger.check('persist');
      ledger.charge('persist');
      // The second tool trips toolCalls; the write counter is untouched.
      expect(
        () => ledger.check('search'),
        throwsA(isA<ProcedureBudgetExceeded>()
            .having((e) => e.dimension, 'dimension', BudgetDimension.toolCalls)),
      );
      // The second write trips memoryWrites independently.
      expect(
        () => ledger.check('edge'),
        throwsA(isA<ProcedureBudgetExceeded>().having(
            (e) => e.dimension, 'dimension', BudgetDimension.memoryWrites)),
      );
    });

    test('consumed starts at zero', () {
      final ledger = BudgetLedger(budget(<String, int>{'toolCalls': 5}));
      expect(ledger.consumed, EffortMetrics.zero);
    });
  });

  group('Q-C.51.1 ProcedureBudgetExceeded shape', () {
    test('is a catchable Exception carrying the typed error kind', () {
      final error = ProcedureBudgetExceeded(
        dimension: BudgetDimension.toolCalls,
        limit: 3,
        consumed: 3,
        primitive: 'search',
      );
      expect(error, isA<Exception>());
      expect(ProcedureBudgetExceeded.errorKind, 'procedure.budget.exceeded');
      expect(error.toString(), contains('toolCalls'));
      expect(error.toString(), contains('search'));
    });
  });

  group('Q-C.51.1 budget refusal never steps the version chain', () {
    test('defaultFallbackClassifier returns null for a budget refusal', () {
      final error = ProcedureBudgetExceeded(
        dimension: BudgetDimension.memoryWrites,
        limit: 2,
        consumed: 2,
        primitive: 'persist',
      );
      // A refusal is a deliberate stop, not a crash: an older procedure
      // version would just hit the same cap, so the chain must not be stepped.
      expect(defaultFallbackClassifier(error), isNull);
    });
  });
}
