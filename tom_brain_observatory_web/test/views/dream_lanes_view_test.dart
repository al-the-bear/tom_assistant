// Module 3 (widget) — the dreaming-cycle monitor (§ 5A) over a stubbed client.
// Asserts the AppBar entry from the prompt list, the lane dropdown, the run-row
// content + order, the lane filter, the run→detail navigation (rendering the
// shared run-tree), and the empty-lane degradation.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_brain_observatory_web/src/app.dart';
import 'package:tom_brain_observatory_web/src/model/dream_run.dart';
import 'package:tom_brain_observatory_web/src/model/llm_call_detail.dart';
import 'package:tom_brain_observatory_web/src/model/prompt_trace.dart';
import 'package:tom_brain_observatory_web/src/views/dream_lanes_view.dart';
import 'package:tom_brain_observatory_web/src/views/llm_call_detail_view.dart';
import 'package:tom_brain_observatory_web/src/views/run_tree_view.dart';

import '../support/stub_api_client.dart';
import '../support/stub_memory_api_client.dart';

/// A dream-run row with sensible defaults; override per test.
DreamRunRow _row(
  String runId, {
  String procedureId = 'dream_extract_v1',
  String laneId = 'fast',
  String? outcomeStatus = 'accepted',
  int? elapsedMs = 3200,
  int llmCallCount = 1,
  int memoryAccessCount = 2,
}) =>
    DreamRunRow(
      runId: runId,
      procedureId: procedureId,
      laneId: laneId,
      recordedAt: null,
      outcomeStatus: outcomeStatus,
      elapsedMs: elapsedMs,
      llmCallCount: llmCallCount,
      memoryAccessCount: memoryAccessCount,
    );

ProcedureRun _runTree(String runId, String procedureId) => ProcedureRun(
      procedureId: procedureId,
      runId: runId,
      turnId: null,
      status: 'accepted',
      elapsedMs: 3200,
      entryCount: 1,
      nodes: const <RunNode>[NoteNode(category: 'extract')],
    );

/// A turn-less run-tree carrying a single LLM-call node (its detail is fetched
/// from [rawPath]) — the fixture for the MSPP-56 dream-run LLM-call open.
ProcedureRun _runTreeWithLlm(
        String runId, String procedureId, String rawPath) =>
    ProcedureRun(
      procedureId: procedureId,
      runId: runId,
      turnId: null,
      status: 'accepted',
      elapsedMs: 3200,
      entryCount: 1,
      nodes: <RunNode>[
        LlmCallNode(
          callType: 'extractor',
          tokensIn: 512,
          tokensOut: 128,
          rawPath: rawPath,
        ),
      ],
    );

LlmCallDetail _dreamDetail() => const LlmCallDetail(
      callType: 'extractor',
      provider: 'local',
      model: 'fixture-model',
      profile: null,
      roleId: null,
      anchorHash: 'sha256:dddd1111',
      promptHash: 'sha256:dddd2222',
      tokensIn: 512,
      tokensOut: 128,
      retries: 0,
      wallClockMs: 3200,
      wire: <String, Object?>{
        'messages': <Object?>[
          <String, Object?>{'role': 'user', 'content': 'extract durable claims'},
        ],
      },
      answer: 'Dream wire answer.',
    );

const _lanes = <DreamLane>[
  DreamLane(
      id: 'fast',
      agents: <String>['dream_extract_v1', 'dream_connect_v1'],
      runCount: 1),
  DreamLane(id: 'slow', agents: <String>['dream_synthesise_v1'], runCount: 1),
  DreamLane(id: 'other', agents: <String>[], runCount: 1),
];

Future<void> _openMonitor(WidgetTester tester, StubApiClient client) async {
  await tester.pumpWidget(ObservatoryApp(
    memoryClient: StubMemoryApiClient(),
    client: client,
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithIcon(IconButton, Icons.bedtime));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the bedtime icon opens the dreaming-cycle monitor',
      (tester) async {
    await _openMonitor(tester, StubApiClient(dreamLanes: _lanes));
    expect(find.byType(DreamLanesView), findsOneWidget);
  });

  testWidgets('the lane dropdown offers All lanes plus each configured lane',
      (tester) async {
    await _openMonitor(tester, StubApiClient(dreamLanes: _lanes));
    expect(find.byKey(const ValueKey<String>('dream-lane-dropdown')),
        findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('dream-lane-dropdown')));
    await tester.pumpAndSettle();
    // The menu shows the synthetic All-lanes entry plus each lane with its count.
    expect(find.text('All lanes'), findsWidgets);
    expect(find.text('fast (1)'), findsWidgets);
    expect(find.text('slow (1)'), findsWidgets);
    expect(find.text('other (1)'), findsWidgets);
  });

  testWidgets('renders dream-run rows in the order the client returned them',
      (tester) async {
    await _openMonitor(
      tester,
      StubApiClient(
        dreamLanes: _lanes,
        dreamRuns: <DreamRunRow>[
          _row('run_a_0', procedureId: 'dream_extract_v1', laneId: 'fast'),
          _row('run_b_0', procedureId: 'dream_synthesise_v1', laneId: 'slow'),
        ],
      ),
    );
    final tiles =
        tester.widgetList<DreamRunTile>(find.byType(DreamRunTile)).toList();
    expect(tiles.map((t) => t.row.runId), <String>['run_a_0', 'run_b_0']);
    expect(find.textContaining('llm 1 · mem 2'), findsWidgets);
  });

  testWidgets('selecting a lane filters the run list', (tester) async {
    await _openMonitor(
      tester,
      StubApiClient(
        dreamLanes: _lanes,
        dreamRuns: <DreamRunRow>[
          _row('run_a_0', procedureId: 'dream_extract_v1', laneId: 'fast'),
          _row('run_b_0', procedureId: 'dream_synthesise_v1', laneId: 'slow'),
        ],
      ),
    );
    expect(find.byType(DreamRunTile), findsNWidgets(2));

    await tester.tap(find.byKey(const ValueKey<String>('dream-lane-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('slow (1)').last);
    await tester.pumpAndSettle();

    final tiles =
        tester.widgetList<DreamRunTile>(find.byType(DreamRunTile)).toList();
    expect(tiles, hasLength(1));
    expect(tiles.single.row.procedureId, 'dream_synthesise_v1');
  });

  testWidgets('selecting a run opens its run-tree detail', (tester) async {
    await _openMonitor(
      tester,
      StubApiClient(
        dreamLanes: _lanes,
        dreamRuns: <DreamRunRow>[_row('run_a_0')],
        dreamRunDetails: <String, DreamRun>{
          'run_a_0': DreamRun(
            runId: 'run_a_0',
            procedureId: 'dream_extract_v1',
            laneId: 'fast',
            run: _runTree('run_a_0', 'dream_extract_v1'),
          ),
        },
      ),
    );

    await tester.tap(find.text('dream_extract_v1'));
    await tester.pumpAndSettle();

    expect(find.byType(DreamRunDetailView), findsOneWidget);
    expect(find.byType(RunTreeView), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'run_a_0'), findsOneWidget);
  });

  // MSPP-56 — an LLM-call row in a dream run opens the same §4.5 detail Module 1
  // shows, fetched through the turn-less `LlmCallSource.dreamRun(runId)` source.
  testWidgets('opening a dream-run LLM-call row shows its verbatim wire body',
      (tester) async {
    const rawPath = '../../llm/extractor/run_a_0__01.raw.json';
    final client = StubApiClient(
      dreamLanes: _lanes,
      dreamRuns: <DreamRunRow>[_row('run_a_0')],
      dreamRunDetails: <String, DreamRun>{
        'run_a_0': DreamRun(
          runId: 'run_a_0',
          procedureId: 'dream_extract_v1',
          laneId: 'fast',
          run: _runTreeWithLlm('run_a_0', 'dream_extract_v1', rawPath),
        ),
      },
      llmCalls: <String, LlmCallDetail>{rawPath: _dreamDetail()},
    );
    await _openMonitor(tester, client);

    // Drill into the dream run, expand its run-tree, open the LLM-call row.
    await tester.tap(find.text('dream_extract_v1'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('run:run_a_0')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('llm extractor'));
    await tester.pumpAndSettle();

    // The shared detail view opened, rendering the fetched wire body + answer.
    expect(find.byType(LlmCallDetailView), findsOneWidget);
    expect(find.text('Dream wire answer.'), findsOneWidget);
    expect(find.textContaining('extract durable claims'), findsOneWidget);

    // It resolved the dump against the turn-less `?run=` log (MSPP-55/56), not a
    // turnId a dream run does not have.
    expect(client.llmCallSources, hasLength(1));
    expect(client.llmCallSources.single.queryParameters,
        <String, String>{'run': 'run_a_0'});
  });

  testWidgets('an empty lane shows the no-runs notice, never an error',
      (tester) async {
    await _openMonitor(
      tester,
      StubApiClient(dreamLanes: _lanes, dreamRuns: const <DreamRunRow>[]),
    );
    expect(find.text('No dream runs in this lane.'), findsOneWidget);
  });
}
