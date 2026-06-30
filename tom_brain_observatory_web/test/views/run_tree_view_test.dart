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
                recall: RecallDescriptor(
                    modes: <String>['bm25', 'vector'], k: 8, returned: 5),
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

  testWidgets('inspect-script affordance invokes onInspectScript for the run',
      (tester) async {
    ProcedureRun? inspected;
    await _pump(
      tester,
      RunTreeView(run: _deepRun(), onInspectScript: (run) => inspected = run),
    );

    // The root run row exposes an inspect-script action (an Icons.code button).
    await tester.tap(find.byIcon(Icons.code).first);
    await tester.pumpAndSettle();

    expect(inspected, isNotNull);
    expect(inspected!.procedureId, 'answer_with_memory_v1');
  });

  testWidgets('no inspect affordance when onInspectScript is null',
      (tester) async {
    await _pump(tester, RunTreeView(run: _deepRun()));
    expect(find.byIcon(Icons.code), findsNothing);
  });

  testWidgets('tapping a primitive with a resultId invokes onOpenNode (PT-7.1)',
      (tester) async {
    String? opened;
    await _pump(
      tester,
      RunTreeView(
        run: const ProcedureRun(
          procedureId: 'p',
          runId: 'r',
          turnId: null,
          status: 'accepted',
          elapsedMs: 10,
          entryCount: 1,
          nodes: <RunNode>[
            PrimitiveCallNode(
                primitive: 'persist', resultId: 'n_fixtureA1', recall: null),
          ],
        ),
        onOpenNode: (id) => opened = id,
      ),
    );

    await tester.tap(find.textContaining('p · accepted'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('persist → n_fixtureA1'));
    await tester.pumpAndSettle();

    expect(opened, 'n_fixtureA1');
  });

  testWidgets('a count-only recall (no returned ids) never cross-links',
      (tester) async {
    var calls = 0;
    await _pump(
      tester,
      RunTreeView(
        run: const ProcedureRun(
          procedureId: 'p',
          runId: 'r',
          turnId: null,
          status: 'accepted',
          elapsedMs: 10,
          entryCount: 1,
          nodes: <RunNode>[
            PrimitiveCallNode(
              primitive: 'recall',
              resultId: null,
              recall: RecallDescriptor(modes: <String>['bm25'], k: 5, returned: 3),
            ),
          ],
        ),
        onOpenNode: (_) => calls++,
      ),
    );

    await tester.tap(find.textContaining('p · accepted'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('recall (bm25'));
    await tester.pumpAndSettle();

    expect(calls, 0);
  });

  testWidgets('a recall with returned ids deep-links each id via onOpenNode '
      '(PT-7 / §4.7)', (tester) async {
    final opened = <String>[];
    await _pump(
      tester,
      RunTreeView(
        run: const ProcedureRun(
          procedureId: 'p',
          runId: 'r',
          turnId: null,
          status: 'accepted',
          elapsedMs: 10,
          entryCount: 1,
          nodes: <RunNode>[
            PrimitiveCallNode(
              primitive: 'recall',
              resultId: null,
              recall: RecallDescriptor(
                modes: <String>['bm25', 'vector'],
                k: 4,
                returned: 2,
                returnedIds: <String>['n_alpha', 'n_beta'],
              ),
            ),
          ],
        ),
        onOpenNode: opened.add,
      ),
    );

    await tester.tap(find.textContaining('p · accepted'));
    await tester.pumpAndSettle();

    // One deep-link chip per returned id, keyed like NodeLinkChip.
    expect(find.byKey(const ValueKey<String>('node-link:n_alpha')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('node-link:n_beta')),
        findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('node-link:n_alpha')));
    await tester.tap(find.byKey(const ValueKey<String>('node-link:n_beta')));
    await tester.pumpAndSettle();

    expect(opened, <String>['n_alpha', 'n_beta']);
  });

  testWidgets('an edge primitive deep-links both endpoints via onOpenNode '
      '(PT-7 / §3.8 / §4.7)', (tester) async {
    final opened = <String>[];
    await _pump(
      tester,
      RunTreeView(
        run: const ProcedureRun(
          procedureId: 'p',
          runId: 'r',
          turnId: null,
          status: 'accepted',
          elapsedMs: 10,
          entryCount: 1,
          nodes: <RunNode>[
            PrimitiveCallNode(
              primitive: 'edge',
              resultId: 'e_edge1',
              recall: null,
              edge: EdgeDescriptor(
                  type: 'supports', from: 'n_alpha', to: 'n_beta'),
            ),
          ],
        ),
        onOpenNode: opened.add,
      ),
    );

    await tester.tap(find.textContaining('p · accepted'));
    await tester.pumpAndSettle();

    // The summary row renders the relation; the edge id itself is not a chip.
    expect(find.textContaining('edge n_alpha -supports-> n_beta'),
        findsOneWidget);
    // One deep-link chip per endpoint, keyed like NodeLinkChip.
    expect(find.byKey(const ValueKey<String>('node-link:n_alpha')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('node-link:n_beta')),
        findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('node-link:n_alpha')));
    await tester.tap(find.byKey(const ValueKey<String>('node-link:n_beta')));
    await tester.pumpAndSettle();

    expect(opened, <String>['n_alpha', 'n_beta']);
  });

  testWidgets('a bare edge (no endpoint descriptor) deep-links nothing',
      (tester) async {
    var calls = 0;
    await _pump(
      tester,
      RunTreeView(
        run: const ProcedureRun(
          procedureId: 'p',
          runId: 'r',
          turnId: null,
          status: 'accepted',
          elapsedMs: 10,
          entryCount: 1,
          nodes: <RunNode>[
            PrimitiveCallNode(
                primitive: 'edge', resultId: 'e_bare2', recall: null),
          ],
        ),
        onOpenNode: (_) => calls++,
      ),
    );

    await tester.tap(find.textContaining('p · accepted'));
    await tester.pumpAndSettle();

    // No endpoint descriptor → no chips; the bare `edge → <id>` row deep-links
    // its own id (an edge id) like any id-returning primitive.
    expect(find.byKey(const ValueKey<String>('node-link:e_bare2')), findsNothing);
    await tester.tap(find.textContaining('edge → e_bare2'));
    await tester.pumpAndSettle();
    expect(calls, 1); // the resultId tap fires once; no endpoint chips exist.
  });

  testWidgets('renders a tool-call node with its name, args and result size',
      (tester) async {
    await _pump(
      tester,
      RunTreeView(
        run: const ProcedureRun(
          procedureId: 'p',
          runId: 'r',
          turnId: null,
          status: 'accepted',
          elapsedMs: 10,
          entryCount: 1,
          nodes: <RunNode>[
            ToolCallNode(
              name: 'memory.read',
              argSummary: 'text: user name, k: 5',
              outcome: 'invoked',
              resultChars: 6274,
            ),
          ],
        ),
      ),
    );

    await tester.tap(find.textContaining('p · accepted'));
    await tester.pumpAndSettle();
    // A successful invoke renders name(args) → ok, <n> chars with no emphasis.
    final row = tester.widget<CollapsedRow>(find.ancestor(
      of: find.textContaining('tool memory.read(text: user name, k: 5) → ok, 6274 chars'),
      matching: find.byType(CollapsedRow),
    ));
    expect(row.emphasis, CollapsedRowEmphasis.normal);
  });

  testWidgets('renders a denied tool-call node with its reason and error emphasis',
      (tester) async {
    await _pump(
      tester,
      RunTreeView(
        run: const ProcedureRun(
          procedureId: 'p',
          runId: 'r',
          turnId: null,
          status: 'accepted',
          elapsedMs: 10,
          entryCount: 1,
          nodes: <RunNode>[
            ToolCallNode(
              name: 'file.write',
              argSummary: '',
              outcome: 'denied',
              reason: 'outside file scope',
            ),
          ],
        ),
      ),
    );

    await tester.tap(find.textContaining('p · accepted'));
    await tester.pumpAndSettle();
    final row = tester.widget<CollapsedRow>(find.ancestor(
      of: find.textContaining('tool file.write() → denied: outside file scope'),
      matching: find.byType(CollapsedRow),
    ));
    expect(row.emphasis, CollapsedRowEmphasis.error);
  });

  testWidgets('renders a note with its payload detail and a stackPeek read '
      '(§5.7)', (tester) async {
    await _pump(
      tester,
      RunTreeView(
        run: const ProcedureRun(
          procedureId: 'dream_extract_v1',
          runId: 'r',
          turnId: null,
          status: 'accepted',
          elapsedMs: 250,
          entryCount: 2,
          nodes: <RunNode>[
            PrimitiveCallNode(
              primitive: 'stackPeek',
              resultId: null,
              recall: null,
              detail: 'interests (k=16 → 3 entries)',
            ),
            NoteNode(category: 'progress', detail: 'stage=extract, claims=5'),
          ],
        ),
      ),
    );

    await tester.tap(find.textContaining('dream_extract_v1'));
    await tester.pumpAndSettle();

    // The stackPeek read shows its name / k / entry count inline…
    expect(find.textContaining('stackPeek interests (k=16 → 3 entries)'),
        findsOneWidget);
    // …and the note shows its category plus the payload detail tail.
    expect(find.textContaining('note progress — stage=extract, claims=5'),
        findsOneWidget);
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
