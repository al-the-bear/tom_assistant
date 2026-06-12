// BudgetView — the d4rt-bridged read-only budget window
// (`tom_brain_procedure_specification.md` § 5.4.2).
//
// The [BudgetLedger] *enforces* token / tool-call caps and the run's wall
// clock *enforces* time; a procedure that wants to *adapt* reads them through
// the `budget` global. These tests pin the read contract:
//
//   - the three limit getters echo the procedure-header caps verbatim;
//   - the three remaining getters start at the cap and shrink as the same
//     ledger the fatal gate reads is charged (token/tool) or the elapsed clock
//     advances (time);
//   - remaining clamps at `0` — the token gate lets an overshoot complete, so
//     consumed can exceed the cap, but "how much is left" is never negative;
//   - an uncapped dimension reports `null` for *both* limit and remaining, so
//     a script tells "no budget set" (`null`) from "budget exhausted" (`0`).

import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:test/test.dart';

void main() {
  ProcedureBudget budget(Map<String, int> caps) => ProcedureBudget(caps);

  // A controllable elapsed clock so the time dimension is deterministic.
  Duration elapsed = Duration.zero;
  Duration Function() clock = () => elapsed;

  setUp(() {
    elapsed = Duration.zero;
    clock = () => elapsed;
  });

  BudgetView viewOver(BudgetLedger ledger) =>
      BudgetView(ledger: ledger, elapsed: clock);

  group('§ 5.4.2 limits echo the header caps', () {
    test('each *Budget getter equals the header cap', () {
      final view = viewOver(BudgetLedger(budget(<String, int>{
        'tokenSpend': 1000,
        'wallClockMs': 60000,
        'toolCalls': 5,
      })));
      expect(view.tokenBudget, 1000);
      expect(view.timeBudget, 60000);
      expect(view.toolCallBudget, 5);
    });
  });

  group('§ 5.4.2 remaining starts at the cap and shrinks', () {
    test('before any consumption, remaining equals the limit', () {
      final view = viewOver(BudgetLedger(budget(<String, int>{
        'tokenSpend': 1000,
        'wallClockMs': 60000,
        'toolCalls': 5,
      })));
      expect(view.remainingTokenBudget, 1000);
      expect(view.remainingTimeBudget, 60000);
      expect(view.remainingToolCallBudget, 5);
    });

    test('charging the ledger shrinks token and tool-call remaining', () {
      final ledger = BudgetLedger(budget(<String, int>{
        'tokenSpend': 1000,
        'toolCalls': 5,
      }));
      final view = viewOver(ledger);

      // An llm call debits tokensIn + tokensOut against the token dimension.
      ledger.charge('llm', result: <String, Object?>{
        'report': <String, Object?>{'tokensIn': 120, 'tokensOut': 80},
      });
      // A tool primitive debits one tool call.
      ledger.charge('search');

      expect(view.remainingTokenBudget, 1000 - 200);
      expect(view.remainingToolCallBudget, 5 - 1);
      // Limits are unmoved by consumption.
      expect(view.tokenBudget, 1000);
      expect(view.toolCallBudget, 5);
    });

    test('advancing the elapsed clock shrinks time remaining', () {
      final view = viewOver(BudgetLedger(budget(<String, int>{
        'wallClockMs': 60000,
      })));
      expect(view.remainingTimeBudget, 60000);
      elapsed = const Duration(milliseconds: 25000);
      expect(view.remainingTimeBudget, 35000);
      // The limit never moves.
      expect(view.timeBudget, 60000);
    });
  });

  group('§ 5.4.2 remaining clamps at zero', () {
    test('an overshooting token spend reports 0, never negative', () {
      final ledger = BudgetLedger(budget(<String, int>{'tokenSpend': 100}));
      final view = viewOver(ledger);
      // The token gate lets an overshoot complete, so consumed > cap is real.
      ledger.charge('llm', result: <String, Object?>{
        'report': <String, Object?>{'tokensIn': 90, 'tokensOut': 90},
      });
      expect(ledger.consumed.estimatedTokens, 180);
      expect(view.remainingTokenBudget, 0);
    });

    test('elapsed past the wall-clock cap reports 0', () {
      final view = viewOver(BudgetLedger(budget(<String, int>{
        'wallClockMs': 10000,
      })));
      elapsed = const Duration(milliseconds: 25000);
      expect(view.remainingTimeBudget, 0);
    });
  });

  group('§ 5.4.2 an uncapped dimension is null on both getters', () {
    test('a dimension the header omits reports null for limit and remaining',
        () {
      // Only token is capped; time and tool-call are left unset.
      final view = viewOver(BudgetLedger(budget(<String, int>{
        'tokenSpend': 500,
      })));
      expect(view.tokenBudget, 500);
      expect(view.remainingTokenBudget, 500);

      expect(view.timeBudget, isNull);
      expect(view.remainingTimeBudget, isNull);
      expect(view.toolCallBudget, isNull);
      expect(view.remainingToolCallBudget, isNull);
    });

    test('an entirely empty budget is null on every getter', () {
      final view = viewOver(BudgetLedger(budget(<String, int>{})));
      expect(view.tokenBudget, isNull);
      expect(view.remainingTokenBudget, isNull);
      expect(view.timeBudget, isNull);
      expect(view.remainingTimeBudget, isNull);
      expect(view.toolCallBudget, isNull);
      expect(view.remainingToolCallBudget, isNull);
    });
  });
}
