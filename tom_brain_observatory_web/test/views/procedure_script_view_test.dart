// PT-3.2 — the procedure-script inspector page (§ 4.6). It fetches the verbatim
// d4rt source for a run's procedureId and renders it read-only, with the lines
// that issue an act the run executed visibly correlated, plus an "executed in
// this run" summary. Tests drive the StubApiClient: source is shown verbatim,
// the executed acts are listed, and a not-found script degrades gracefully.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_brain_observatory_web/src/model/prompt_trace.dart';
import 'package:tom_brain_observatory_web/src/views/procedure_script_view.dart';

import '../support/stub_api_client.dart';

const _source = 'Future<void> main() async {\n'
    '  final hits = await runProcedure(\'retrieve_for_prompt_v1\', {});\n'
    '  final vector = await sub.embed(prompt);\n'
    '  final answer = await llm(hits, vector);\n'
    '  final node = await mem.persist(answer);\n'
    '}\n';

ProcedureRun _run() => ProcedureRun(
      procedureId: 'answer_with_memory_v1',
      runId: 'run-a0',
      turnId: 't0',
      status: 'accepted',
      elapsedMs: 100,
      entryCount: 4,
      nodes: <RunNode>[
        const PrimitiveCallNode(primitive: 'embed', resultId: null, recall: null),
        const LlmCallNode(
            callType: 'assistant_to_user', tokensIn: 1, tokensOut: 2, rawPath: 'x'),
        const PrimitiveCallNode(primitive: 'persist', resultId: 'n1', recall: null),
        SubRunNode(
          run: ProcedureRun(
            procedureId: 'retrieve_for_prompt_v1',
            runId: 'run-a1',
            turnId: 't0',
            status: 'accepted',
            elapsedMs: 10,
            entryCount: 0,
            nodes: const <RunNode>[],
          ),
        ),
      ],
    );

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: child));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the verbatim source and lists the executed acts',
      (tester) async {
    final client = StubApiClient(
      scripts: const <String, String>{'answer_with_memory_v1': _source},
    );
    await _pump(tester, ProcedureScriptView(client: client, run: _run()));

    // Verbatim source — the @procedure-shaped body lines are present.
    expect(find.textContaining('runProcedure'), findsWidgets);
    expect(find.textContaining('mem.persist'), findsWidgets);

    // The acts the run executed are surfaced.
    expect(find.textContaining('embed'), findsWidgets);
    expect(find.textContaining('persist'), findsWidgets);
    expect(find.textContaining('llm'), findsWidgets);
    expect(find.textContaining('retrieve_for_prompt_v1'), findsWidgets);
  });

  testWidgets('shows a not-found message when the script is unavailable',
      (tester) async {
    final client = const StubApiClient(); // no scripts
    await _pump(tester, ProcedureScriptView(client: client, run: _run()));
    expect(find.textContaining('No source'), findsOneWidget);
  });
}
