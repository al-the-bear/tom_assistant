// PT-2.3 (widget) — the recursive run-tree view. Asserts the lazy-expansion
// contract on a deep fixture: a collapsed run shows its summary but does NOT
// build its child rows; expanding it builds its immediate children; a deeper
// sub-run stays collapsed until itself expanded — there is no fixed depth
// limit. Also asserts render-by-kind (LlmCall one-liner, primitive, note,
// error) and that tapping an LlmCall invokes `onOpenLlmCall`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_brain_observatory_web/src/model/prompt_trace.dart';
import 'package:tom_brain_observatory_web/src/views/collapsed_row.dart';
import 'package:tom_brain_observatory_web/src/views/run_tree_view.dart';

/// A three-deep run: root → llm + subRun(level1) → subRun(level2) → llm.
ProcedureRun _deepRun() => const ProcedureRun(
      procedureId: 'answer_with_memory_v1',
      runId: 'run-root',
      turnId: '260101-120000.000001',
      status: 'accepted',
      elapsedMs: 2100,
      entryCount: 2,
      nodes: <RunNode>[
        LlmCallNode(
          callType: 'analyze',
          tokensIn: 100,
          tokensOut: 20,
          rawPath: '../../llm/analyze/260101-120000.000001__01.raw.json',
        ),
        SubRunNode(
          run: ProcedureRun(
            procedureId: 'recall_v1',
            runId: 'run-level1',
            turnId: null,
            status: 'accepted',
            elapsedMs: 300,
            entryCount: 1,
            nodes: <RunNode>[
              PrimitiveCallNode(
                primitive: 'recall',
                resultId: null,
                recall: RecallDescriptor(modes: 'bm25+vector', k: 8, returned: 5),
              ),
              SubRunNode(
                run: ProcedureRun(
                  procedureId: 'synthesize_v1',
                  runId: 'run-level2',
                  turnId: null,
                  status: 'accepted',
                  elapsedMs: 80,
                  entryCount: 1,
                  nodes: <RunNode>[
                    LlmCallNode(
                      callType: 'synthesize',
                      tokensIn: 50,
                      tokensOut: 10,
                      rawPath:
                          '../../llm/synthesize/260101-120000.000001__03.raw.json',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('collapsed run shows summary but does not build children',
      (tester) async {
    await _pump(tester, RunTreeView(run: _deepRun()));

    // Root summary visible…
    expect(find.textContaining('answer_with_memory_v1'), findsOneWidget);
    // …but no child rows are built while collapsed.
    expect(find.textContaining('llm analyze'), findsNothing);
    expect(find.textContaining('recall_v1'), findsNothing);
  });

  testWidgets('expanding a run builds only its immediate children', (tester) async {
    await _pump(tester, RunTreeView(run: _deepRun()));

    await tester.tap(find.textContaining('answer_with_memory_v1'));
    await tester.pumpAndSettle();

    // Immediate children appear…
    expect(find.textContaining('llm analyze · 100→20 tok'), findsOneWidget);
    expect(find.textContaining('recall_v1'), findsOneWidget);
    // …but the level-1 sub-run's own children stay collapsed.
    expect(find.textContaining('recall (bm25+vector'), findsNothing);
    expect(find.textContaining('synthesize_v1'), findsNothing);
  });

  testWidgets('recurses to arbitrary depth as each sub-run is expanded',
      (tester) async {
    await _pump(tester, RunTreeView(run: _deepRun()));

    await tester.tap(find.textContaining('answer_with_memory_v1'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('recall_v1'));
    await tester.pumpAndSettle();

    // Level-1's children are now built (primitive + the level-2 sub-run row)…
    expect(find.textContaining('recall (bm25+vector k=8 → 5)'), findsOneWidget);
    expect(find.textContaining('synthesize_v1'), findsOneWidget);
    // …but level-2's own LLM child stays hidden until level-2 is expanded.
    expect(find.textContaining('llm synthesize'), findsNothing);

    await tester.tap(find.textContaining('synthesize_v1'));
    await tester.pumpAndSettle();
    expect(find.textContaining('llm synthesize · 50→10 tok'), findsOneWidget);
  });

  testWidgets('tapping an LlmCall row invokes onOpenLlmCall', (tester) async {
    LlmCallNode? opened;
    await _pump(
      tester,
      RunTreeView(run: _deepRun(), onOpenLlmCall: (node) => opened = node),
    );

    await tester.tap(find.textContaining('answer_with_memory_v1'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('llm analyze'));
    await tester.pumpAndSettle();

    expect(opened, isNotNull);
    expect(opened!.callType, 'analyze');
  });

  testWidgets('renders an error node with error emphasis', (tester) async {
    await _pump(
      tester,
      RunTreeView(
        run: const ProcedureRun(
          procedureId: 'p',
          runId: 'r',
          turnId: null,
          status: 'failed',
          elapsedMs: 10,
          entryCount: 1,
          nodes: <RunNode>[
            ErrorNode(errorKind: 'substrateTimeout', message: 'no token in 30s'),
          ],
        ),
      ),
    );

    await tester.tap(find.textContaining('p · failed'));
    await tester.pumpAndSettle();

    final row = tester.widget<CollapsedRow>(find.ancestor(
      of: find.textContaining('error substrateTimeout'),
      matching: find.byType(CollapsedRow),
    ));
    expect(row.emphasis, CollapsedRowEmphasis.error);
  });
}
