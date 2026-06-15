// PT-2.1 (widget) — the prompt-list view over a stubbed client. Asserts the
// §4.1 row content (preview, principal/persona, counts, outcome chip,
// wall-clock), the order the client returned, the in-flight row's "in-flight"
// chip, and the row→detail navigation (§4.2).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_brain_observatory_web/src/app.dart';
import 'package:tom_brain_observatory_web/src/model/prompt_trace.dart';
import 'package:tom_brain_observatory_web/src/views/configuration_catalogue_view.dart';
import 'package:tom_brain_observatory_web/src/views/outcome_chip.dart';
import 'package:tom_brain_observatory_web/src/views/prompt_list_view.dart';
import 'package:tom_brain_observatory_web/src/views/prompt_trace_detail_view.dart';

import '../support/stub_api_client.dart';
import '../support/stub_memory_api_client.dart';

void main() {
  testWidgets('reloads the list when a list-change tick arrives (PT-4.2)',
      (tester) async {
    final changes = StreamController<void>.broadcast();
    addTearDown(changes.close);
    await tester.pumpWidget(ObservatoryApp(
      memoryClient: StubMemoryApiClient(),
      client: StubApiClient(
        rows: <PromptListRow>[stubRow('260101-120000.000001', preview: 'first')],
        rowsAfterChange: <PromptListRow>[
          stubRow('260101-120100.000002', preview: 'just arrived'),
          stubRow('260101-120000.000001', preview: 'first'),
        ],
        changes: changes.stream,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('just arrived'), findsNothing);

    changes.add(null);
    await tester.pumpAndSettle();
    expect(find.text('just arrived'), findsOneWidget);
    expect(find.text('first'), findsOneWidget);
  });

  testWidgets('renders §4.1 row content', (tester) async {
    await tester.pumpWidget(ObservatoryApp(
      memoryClient: StubMemoryApiClient(),
      client: StubApiClient(rows: [
        stubRow(
          '260101-120000.000001',
          preview: 'what did we decide about backup?',
          principalId: 'fixture-user',
          persona: 'tom-assistant',
          llmCallCount: 2,
          memoryAccessCount: 5,
        ),
      ]),
    ));
    await tester.pumpAndSettle();

    expect(find.text('what did we decide about backup?'), findsOneWidget);
    expect(find.textContaining('fixture-user'), findsOneWidget);
    expect(find.textContaining('llm 2 · mem 5'), findsOneWidget);
    expect(find.descendant(of: find.byType(OutcomeChip), matching: find.text('OK')),
        findsOneWidget);
    expect(find.text('2.1s'), findsOneWidget);
  });

  testWidgets('renders rows in the order the client returned them', (tester) async {
    await tester.pumpWidget(ObservatoryApp(
      memoryClient: StubMemoryApiClient(),
      client: StubApiClient(rows: [
        stubRow('260101-120200.000003', preview: 'newest'),
        stubRow('260101-120000.000001', preview: 'oldest'),
      ]),
    ));
    await tester.pumpAndSettle();

    final tiles = tester.widgetList<PromptListTile>(find.byType(PromptListTile)).toList();
    expect(tiles.map((t) => t.row.turnId), <String>[
      '260101-120200.000003',
      '260101-120000.000001',
    ]);
  });

  testWidgets('an in-flight row shows the in-flight chip and em-dash clock',
      (tester) async {
    await tester.pumpWidget(ObservatoryApp(
      memoryClient: StubMemoryApiClient(),
      client: StubApiClient(rows: [
        stubRow('260101-120300.000004',
            preview: 'in flight', outcomeStatus: null, wallClockMs: null),
      ]),
    ));
    await tester.pumpAndSettle();

    expect(find.descendant(of: find.byType(OutcomeChip), matching: find.text('in-flight')),
        findsOneWidget);
    expect(find.text('—'), findsOneWidget);
  });

  testWidgets('the gear icon opens the general configuration editor (step 19)',
      (tester) async {
    await tester.pumpWidget(ObservatoryApp(
      memoryClient: StubMemoryApiClient(),
      client: StubApiClient(rows: [stubRow('260101-120000.000001')]),
    ));
    await tester.pumpAndSettle();

    // The §6.4 gear affordance is on the main-page app bar.
    final gear = find.widgetWithIcon(IconButton, Icons.settings);
    expect(gear, findsOneWidget);

    await tester.tap(gear);
    await tester.pumpAndSettle();
    expect(find.byType(ConfigurationCatalogueView), findsOneWidget);
  });

  testWidgets('selecting a row opens its PromptTrace detail', (tester) async {
    const turnId = '260101-120000.000001';
    await tester.pumpWidget(ObservatoryApp(
      memoryClient: StubMemoryApiClient(),
      client: StubApiClient(
        rows: [stubRow(turnId, preview: 'open me')],
        traces: <String, PromptTrace>{
          turnId: const PromptTrace(
            turnId: turnId,
            inbound: null,
            configuration: Configuration(entries: <ConfigEntry>[], memoryProfile: null),
            reply: null,
            runTrees: <ProcedureRun>[],
          ),
        },
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('open me'));
    await tester.pumpAndSettle();

    expect(find.byType(PromptTraceDetailView), findsOneWidget);
    expect(find.widgetWithText(AppBar, turnId), findsOneWidget);
  });
}
