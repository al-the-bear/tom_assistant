// PT-1.2 — recursive RunTree assembly. Proves the parser turns the rendered
// §5.7 `.log` into the nested `ProcedureRun`/`SubRun` tree to full depth, with
// every node kind correctly discriminated, and that the renderer's documented
// losses surface as `null`s (the fidelity note in `run_tree.dart`).

import 'dart:io';

import 'package:tom_brain_observatory/tom_brain_observatory.dart';
import 'package:test/test.dart';

const _fixtureRoot = 'test/fixtures/trail/fixturehost';

String _readLog(String turnRun) => File(
      '$_fixtureRoot/procedures/answer_with_memory_v1/$turnRun.log',
    ).readAsStringSync();

void main() {
  group('parseRunTree — deep accepted fixture (a0)', () {
    final run = parseRunTree(_readLog('260101-120000.000001__run-fixture-a0'))!;

    test('top-level run header + outcome', () {
      expect(run.procedureId, 'answer_with_memory_v1');
      expect(run.runId, 'run-fixture-a0');
      expect(run.turnId, '260101-120000.000001');
      expect(run.status, 'accepted');
      expect(run.elapsedMs, 2100); // "2.1s" → 2100
      expect(run.entryCount, 6);
    });

    test('top-level nodes in trail order, by kind', () {
      expect(run.nodes, hasLength(5));
      expect(run.nodes[0], isA<SubRunNode>());
      expect(run.nodes[1], isA<LlmCallNode>());
      expect(run.nodes[2], isA<PrimitiveCallNode>()); // embed
      expect(run.nodes[3], isA<PrimitiveCallNode>()); // persist → id
      expect(run.nodes[4], isA<PrimitiveCallNode>()); // edge → id
    });

    test('top-level llm call decoded', () {
      final llm = run.nodes[1] as LlmCallNode;
      expect(llm.callType, 'assistant_to_user');
      expect(llm.tokensIn, 88);
      expect(llm.tokensOut, 40);
      expect(
        llm.rawPath,
        '../../llm/assistant_to_user/260101-120000.000001__02.raw.json',
      );
    });

    test('id-returning primitives carry their result id', () {
      final persist = run.nodes[3] as PrimitiveCallNode;
      expect(persist.primitive, 'persist');
      expect(persist.resultId, 'n_fixture0000000000000000A1');

      final edge = run.nodes[4] as PrimitiveCallNode;
      expect(edge.primitive, 'edge');
      expect(edge.resultId, 'e_fixture0000000000000000A1');
    });

    test('recurses to full depth: a0 → a1 → a2', () {
      final a1 = (run.nodes[0] as SubRunNode).run;
      expect(a1.procedureId, 'retrieve_for_prompt_v1');
      expect(a1.runId, 'run-fixture-a1');
      expect(a1.status, 'accepted');
      // Renderer loss: a sub-run has no outcome line → no elapsed/entries.
      expect(a1.elapsedMs, isNull);
      expect(a1.entryCount, isNull);
      expect(a1.turnId, isNull);
      expect(a1.nodes, hasLength(2));
      expect(a1.nodes[1], isA<PrimitiveCallNode>()); // recallMulti

      final a2 = (a1.nodes[0] as SubRunNode).run;
      expect(a2.procedureId, 'recall_semantic_v1');
      expect(a2.runId, 'run-fixture-a2');
      expect(a2.nodes, hasLength(2));
      expect((a2.nodes[0] as PrimitiveCallNode).primitive, 'embed');

      final recallLlm = a2.nodes[1] as LlmCallNode;
      expect(recallLlm.callType, 'recall_planner');
      expect(recallLlm.tokensIn, 64);
      expect(recallLlm.tokensOut, 24);
    });

    test('walk helpers count across the whole tree', () {
      expect(llmCallCount(run), 2); // recall_planner + assistant_to_user
      expect(memoryAccessCount(run), 5); // 2×embed + recallMulti + persist + edge
    });
  });

  group('parseRunTree — error fixture (b0)', () {
    final run = parseRunTree(_readLog('260101-120100.000002__run-fixture-b0'))!;

    test('errored outcome with elapsed in seconds', () {
      expect(run.status, 'errored');
      expect(run.elapsedMs, 8300); // "8.3s"
      expect(run.entryCount, 2);
    });

    test('typed error node decoded', () {
      final error = run.nodes.whereType<ErrorNode>().single;
      expect(error.errorKind, 'substrateTimeout');
      expect(error.message, 'assistant_to_user call timed out after 8000ms');
    });
  });

  group('parseRunTree — malformed input degrades, never throws', () {
    test('empty content → null', () => expect(parseRunTree(''), isNull));
    test('no header → null', () => expect(parseRunTree('not a run\n'), isNull));
  });
}
