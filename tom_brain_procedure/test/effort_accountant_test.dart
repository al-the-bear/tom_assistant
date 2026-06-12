// C.32 — EffortAccountant unit tests.
//
// Proves the per-primitive classification rules (definition § 7.4): which
// bridged call contributes which counter, that `llm` reads its token
// counts off the embedded `report`, and that control-flow / unrecognised
// primitives contribute nothing. Pure tests — no recorder, no memory.

import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show EffortMetrics;
import 'package:test/test.dart';

void main() {
  group('C.32 EffortAccountant', () {
    const accountant = EffortAccountant();

    group('llm', () {
      test('counts one call and reads tokens from the report', () {
        final delta = accountant.classify('llm', result: <String, Object?>{
          'text': 'an answer',
          'report': <String, Object?>{'tokensIn': 120, 'tokensOut': 80},
        });
        expect(delta.llmCalls, 1);
        expect(delta.inputTokens, 120);
        expect(delta.outputTokens, 80);
        expect(delta.estimatedTokens, 200);
        // It is not a tool call, read, or write.
        expect(delta.toolCalls, 0);
        expect(delta.memoryReads, 0);
        expect(delta.memoryWrites, 0);
        // Per-call latency is never folded into wall clock here.
        expect(delta.wallClockMs, 0);
      });

      test('counts the call but zero tokens when the report is absent', () {
        final delta = accountant.classify('llm');
        expect(delta.llmCalls, 1);
        expect(delta.inputTokens, 0);
        expect(delta.outputTokens, 0);
      });

      test('degrades malformed or negative token fields to zero', () {
        final negative = accountant.classify('llm', result: <String, Object?>{
          'report': <String, Object?>{'tokensIn': -5, 'tokensOut': 'oops'},
        });
        expect(negative.inputTokens, 0);
        expect(negative.outputTokens, 0);

        final notAMap = accountant.classify('llm',
            result: <String, Object?>{'report': 'not a map'});
        expect(notAMap.inputTokens, 0);
        expect(notAMap.outputTokens, 0);
      });

      test('truncates fractional token counts toward zero', () {
        final delta = accountant.classify('llm', result: <String, Object?>{
          'report': <String, Object?>{'tokensIn': 12.9, 'tokensOut': 4.2},
        });
        expect(delta.inputTokens, 12);
        expect(delta.outputTokens, 4);
      });
    });

    group('send (explicit-route completion, §7.4)', () {
      test('counts one llm call and reads tokens, exactly like llm', () {
        final delta = accountant.classify('send', result: <String, Object?>{
          'text': 'an answer',
          'report': <String, Object?>{'tokensIn': 30, 'tokensOut': 12},
        });
        expect(delta.llmCalls, 1);
        expect(delta.inputTokens, 30);
        expect(delta.outputTokens, 12);
        expect(delta.estimatedTokens, 42);
        // Not a tool call / read / write — it is a completion.
        expect(delta.toolCalls, 0);
        expect(delta.memoryReads, 0);
        expect(delta.memoryWrites, 0);
      });

      test('counts the call but zero tokens when the report is absent', () {
        final delta = accountant.classify('send');
        expect(delta.llmCalls, 1);
        expect(delta.inputTokens, 0);
        expect(delta.outputTokens, 0);
      });
    });

    group('substrate tool calls', () {
      for (final primitive in <String>['embed', 'search', 'fetch']) {
        test('$primitive contributes one toolCall', () {
          final delta = accountant.classify(primitive);
          expect(delta.toolCalls, 1);
          expect(delta, EffortMetrics(toolCalls: 1));
        });
      }
    });

    group('memory reads', () {
      for (final primitive in <String>[
        'recall',
        'stack.list',
        'stack.peek',
        'stackList',
        'stackPeek',
      ]) {
        test('$primitive contributes one memoryRead', () {
          final delta = accountant.classify(primitive);
          expect(delta.memoryReads, 1);
          expect(delta, EffortMetrics(memoryReads: 1));
        });
      }
    });

    group('memory writes', () {
      for (final primitive in <String>[
        'persist',
        'edge',
        'propose_node_type',
        'proposeNodeType',
        'stack.create',
        'stack.push',
        'stack.pop',
        'stack.update',
        'stack.remove',
        'stackCreate',
        'stackPush',
        'stackPop',
        'stackUpdate',
        'stackRemove',
      ]) {
        test('$primitive contributes one memoryWrite', () {
          final delta = accountant.classify(primitive);
          expect(delta.memoryWrites, 1);
          expect(delta, EffortMetrics(memoryWrites: 1));
        });
      }
    });

    group('zero-cost primitives', () {
      for (final primitive in <String>[
        'runProcedure',
        'note',
        'yield_if_foreground_waiting',
        'yieldIfForegroundWaiting',
        'totally_unknown_primitive',
      ]) {
        test('$primitive contributes nothing', () {
          expect(accountant.classify(primitive), EffortMetrics.zero);
        });
      }
    });
  });
}
