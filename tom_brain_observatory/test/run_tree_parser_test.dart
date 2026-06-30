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
      // The endpoints + relation are the §4.7 deep-link source.
      expect(edge.edge, isNotNull);
      expect(edge.edge!.from, 'n_fixture0000000000000000A1');
      expect(edge.edge!.type, 'derived_from');
      expect(edge.edge!.to, 'n_fixture0000000000000000A2');
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

  group('parseRunTree — recall returned ids (PT-7 / §3.9)', () {
    const log = 'procedure retrieve_for_prompt_v1  run r0  turn t0\n'
        '├─ recall (bm25+vector k=4 → 2: n_alpha, n_beta)\n'
        '├─ recall (bm25 k=2 → 0)\n'
        '└─ outcome accepted (entries=2, 100ms)\n';
    final run = parseRunTree(log)!;

    test('a recall line carrying ids parses them into returnedIds', () {
      final recall = run.nodes[0] as PrimitiveCallNode;
      expect(recall.primitive, 'recall');
      expect(recall.recall, isNotNull);
      expect(recall.recall!.modes, <String>['bm25', 'vector']);
      expect(recall.recall!.k, '4');
      expect(recall.recall!.returned, 2);
      expect(recall.recall!.returnedIds, <String>['n_alpha', 'n_beta']);
    });

    test('a count-only recall leaves returnedIds empty', () {
      final recall = run.nodes[1] as PrimitiveCallNode;
      expect(recall.recall!.returned, 0);
      expect(recall.recall!.returnedIds, isEmpty);
    });

    test('returnedIds round-trips through toJson (omitted when empty)', () {
      final withIds = (run.nodes[0] as PrimitiveCallNode).recall!.toJson();
      expect(withIds['returnedIds'], <String>['n_alpha', 'n_beta']);
      final empty = (run.nodes[1] as PrimitiveCallNode).recall!.toJson();
      expect(empty.containsKey('returnedIds'), isFalse);
    });
  });

  group('parseRunTree — edge endpoints (PT-7 / §3.8 / §3.9)', () {
    const log = 'procedure answer_with_memory_v1  run r0  turn t0\n'
        '├─ edge n_alpha -supports-> n_beta → e_edge1\n'
        '├─ edge → e_bare2\n'
        '└─ outcome accepted (entries=2, 100ms)\n';
    final run = parseRunTree(log)!;

    test('an edge line carrying endpoints parses into an EdgeDescriptor', () {
      final edge = run.nodes[0] as PrimitiveCallNode;
      expect(edge.primitive, 'edge');
      expect(edge.resultId, 'e_edge1'); // the edge's own id
      expect(edge.edge, isNotNull);
      expect(edge.edge!.from, 'n_alpha');
      expect(edge.edge!.type, 'supports');
      expect(edge.edge!.to, 'n_beta');
    });

    test('a bare `edge → id` line carries the id but no endpoint descriptor', () {
      final bare = run.nodes[1] as PrimitiveCallNode;
      expect(bare.primitive, 'edge');
      expect(bare.resultId, 'e_bare2');
      expect(bare.edge, isNull);
    });

    test('the edge descriptor round-trips through toJson (omitted when absent)',
        () {
      final withEdge = (run.nodes[0] as PrimitiveCallNode).toJson();
      expect(withEdge['edge'],
          <String, Object?>{'type': 'supports', 'from': 'n_alpha', 'to': 'n_beta'});
      final bare = (run.nodes[1] as PrimitiveCallNode).toJson();
      expect(bare.containsKey('edge'), isFalse);
    });
  });

  group('parseRunTree — tool.invoke nodes (§5.7.1)', () {
    const log = 'procedure tool_loop_v1  run r0  turn t0\n'
        '├─ tool file.read(path: lib/main.dart) → ok (1240 chars)\n'
        '├─ tool does.not.exist() → failed: unknown tool "does.not.exist"\n'
        '├─ tool shell.run(cmd: rm -rf /) → denied: policy denies group shell\n'
        '├─ note loop-complete: llm returned no tool call\n'
        '└─ outcome accepted (entries=4, 90ms)\n';
    final run = parseRunTree(log)!;

    test('an invoked tool parses name, arg summary and result size only', () {
      final tool = run.nodes[0] as ToolCallNode;
      expect(tool.name, 'file.read');
      expect(tool.argSummary, 'path: lib/main.dart');
      expect(tool.outcome, ToolCallOutcome.invoked);
      expect(tool.resultChars, 1240);
      expect(tool.reason, isNull);
    });

    test('a failed tool parses its reason and carries no result size', () {
      final tool = run.nodes[1] as ToolCallNode;
      expect(tool.name, 'does.not.exist');
      expect(tool.argSummary, isEmpty);
      expect(tool.outcome, ToolCallOutcome.failed);
      expect(tool.resultChars, isNull);
      expect(tool.reason, 'unknown tool "does.not.exist"');
    });

    test('a denied tool parses its policy reason', () {
      final tool = run.nodes[2] as ToolCallNode;
      expect(tool.name, 'shell.run');
      expect(tool.argSummary, 'cmd: rm -rf /');
      expect(tool.outcome, ToolCallOutcome.denied);
      expect(tool.reason, 'policy denies group shell');
    });

    test('the termination note rides through as a NoteNode', () {
      final note = run.nodes[3] as NoteNode;
      expect(note.category, 'loop-complete: llm returned no tool call');
    });

    test('tool nodes count as tools, never as memory accesses', () {
      expect(toolCallCount(run), 3);
      expect(memoryAccessCount(run), 0,
          reason: 'a tool.invoke is an effect, not a memory access');
      expect(llmCallCount(run), 0);
    });

    test('an invoked tool round-trips through toJson (size, no reason)', () {
      final json = (run.nodes[0] as ToolCallNode).toJson();
      expect(json, <String, Object?>{
        'kind': 'tool',
        'name': 'file.read',
        'argSummary': 'path: lib/main.dart',
        'outcome': 'invoked',
        'resultChars': 1240,
      });
      final failed = (run.nodes[1] as ToolCallNode).toJson();
      expect(failed.containsKey('resultChars'), isFalse);
      expect(failed['reason'], 'unknown tool "does.not.exist"');
    });
  });

  group('parseRunTree — note detail + stackPeek read (§5.7)', () {
    const log = 'procedure dream_extract_v1  run r0  turn t0\n'
        '├─ stackPeek interests (k=16 → 3 entries)\n'
        '├─ note progress — stage=extract, claims=5\n'
        '├─ note run_cancelled\n'
        '└─ outcome accepted (entries=4, 250ms)\n';
    final run = parseRunTree(log)!;

    test('a stackPeek read parses its name / k / entry count into detail', () {
      final peek = run.nodes[0] as PrimitiveCallNode;
      expect(peek.primitive, 'stackPeek');
      expect(peek.detail, 'interests (k=16 → 3 entries)');
      expect(peek.resultId, isNull);
    });

    test('a note carrying a payload splits its category from the detail tail',
        () {
      final note = run.nodes[1] as NoteNode;
      expect(note.category, 'progress');
      expect(note.detail, 'stage=extract, claims=5');
    });

    test('a payload-less note carries a null detail', () {
      final note = run.nodes[2] as NoteNode;
      expect(note.category, 'run_cancelled');
      expect(note.detail, isNull);
    });

    test('the detail round-trips through toJson (omitted when absent)', () {
      expect((run.nodes[1] as NoteNode).toJson()['detail'],
          'stage=extract, claims=5');
      expect((run.nodes[2] as NoteNode).toJson().containsKey('detail'), isFalse);
      expect((run.nodes[0] as PrimitiveCallNode).toJson()['detail'],
          'interests (k=16 → 3 entries)');
    });
  });

  group('parseRunTree — malformed input degrades, never throws', () {
    test('empty content → null', () => expect(parseRunTree(''), isNull));
    test('no header → null', () => expect(parseRunTree('not a run\n'), isNull));
  });
}
