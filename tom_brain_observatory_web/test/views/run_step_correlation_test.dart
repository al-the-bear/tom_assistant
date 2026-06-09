// PT-3.2 — the pure run-step correlation helpers (§ 4.6). `executedActs` collects
// the act tokens a run issued from its *immediate* nodes (sub-runs contribute
// their dispatched procedureId, not their inner acts); `correlateLines` maps
// those tokens onto the source lines that mention them. Correlation is
// best-effort by contract: the trail carries no source line numbers, so a hit
// means "this line issues an act the run executed", not an authoritative 1:1 map.

import 'package:flutter_test/flutter_test.dart';
import 'package:tom_brain_observatory_web/src/model/prompt_trace.dart';
import 'package:tom_brain_observatory_web/src/views/run_step_correlation.dart';

ProcedureRun _run(List<RunNode> nodes) => ProcedureRun(
      procedureId: 'answer_with_memory_v1',
      runId: 'r0',
      turnId: 't0',
      status: 'accepted',
      elapsedMs: 100,
      entryCount: nodes.length,
      nodes: nodes,
    );

void main() {
  group('executedActs', () {
    test('collects primitive names, an llm token, and sub-run procedureIds', () {
      final run = _run(<RunNode>[
        const PrimitiveCallNode(primitive: 'embed', resultId: null, recall: null),
        const LlmCallNode(
            callType: 'assistant_to_user', tokensIn: 1, tokensOut: 2, rawPath: 'x'),
        const PrimitiveCallNode(primitive: 'persist', resultId: 'n1', recall: null),
        SubRunNode(run: _run2('retrieve_for_prompt_v1')),
      ]);
      expect(
        executedActs(run),
        <String>{'embed', 'llm', 'persist', 'retrieve_for_prompt_v1'},
      );
    });

    test('a sub-run contributes only its procedureId, not its inner acts', () {
      final inner = ProcedureRun(
        procedureId: 'retrieve_for_prompt_v1',
        runId: 'r1',
        turnId: 't0',
        status: 'accepted',
        elapsedMs: 10,
        entryCount: 1,
        nodes: const <RunNode>[
          PrimitiveCallNode(primitive: 'recallMulti', resultId: null, recall: null),
        ],
      );
      final run = _run(<RunNode>[SubRunNode(run: inner)]);
      // The parent's inspected source never mentions the *inner* act.
      expect(executedActs(run), <String>{'retrieve_for_prompt_v1'});
      expect(executedActs(run), isNot(contains('recallMulti')));
    });

    test('notes and errors are not source acts', () {
      final run = _run(const <RunNode>[
        NoteNode(category: 'analysis'),
        ErrorNode(errorKind: 'substrateTimeout', message: 'timed out'),
      ]);
      expect(executedActs(run), isEmpty);
    });
  });

  group('correlateLines', () {
    const source = 'Future<void> main() async {\n'
        '  final hits = await runProcedure(\'retrieve_for_prompt_v1\', {});\n'
        '  final vector = await sub.embed(prompt);\n'
        '  final answer = await llm(hits, vector);\n'
        '  final node = await mem.persist(answer);\n'
        '}\n';

    test('matches act tokens even when prefixed by a receiver dot', () {
      final hits = correlateLines(source, <String>{'embed', 'persist'});
      // line 2 (0-based) = `sub.embed`, line 4 = `mem.persist`.
      expect(hits, <int>{2, 4});
    });

    test('matches an llm act and a dispatched sub-procedure literal', () {
      final hits = correlateLines(source, <String>{'llm', 'retrieve_for_prompt_v1'});
      expect(hits, <int>{1, 3});
    });

    test('does not match a token that is only a substring of an identifier', () {
      // `embed` must not light up a line that only contains `embedder`.
      const s = 'final e = embedder();\n';
      expect(correlateLines(s, <String>{'embed'}), isEmpty);
    });

    test('empty act set correlates nothing', () {
      expect(correlateLines(source, const <String>{}), isEmpty);
    });
  });
}

ProcedureRun _run2(String id) => ProcedureRun(
      procedureId: id,
      runId: 'r-$id',
      turnId: 't0',
      status: 'accepted',
      elapsedMs: 5,
      entryCount: 0,
      nodes: const <RunNode>[],
    );
