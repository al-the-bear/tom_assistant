// PT-2.2 (widget) — the PromptTrace detail sections. Asserts the four §4.2
// sections are present and independently expandable, that a section absent for
// the turn is disabled (an in-flight turn has no run tree), and that the
// configuration-in-effect view (§4.3) renders the distinct (provider, model,
// profile, role) tuples with the read-only deep-link chip. `buildTraceSections`
// is exercised directly (no Navigator) over a static trace.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_brain_observatory_web/src/model/live_step.dart';
import 'package:tom_brain_observatory_web/src/model/memory_nodes.dart';
import 'package:tom_brain_observatory_web/src/model/prompt_trace.dart';
import 'package:tom_brain_observatory_web/src/views/configuration_in_effect_view.dart';
import 'package:tom_brain_observatory_web/src/views/live_reply_view.dart';
import 'package:tom_brain_observatory_web/src/views/memory/node_detail_view.dart';
import 'package:tom_brain_observatory_web/src/views/prompt_trace_detail_view.dart';

import '../support/stub_api_client.dart';
import '../support/stub_memory_api_client.dart';

PromptTrace _trace({bool withRunTree = true}) => PromptTrace(
      turnId: '260101-120000.000001',
      inbound: Inbound(
        channel: 'openai',
        principalId: 'fixture-user',
        sessionId: 'sess-1',
        conversationId: null,
        profile: 'default',
        persona: 'tom-assistant',
        receivedAt: DateTime.parse('2026-01-01T12:00:00Z'),
        text: 'what did we decide about backup?',
        attachments: const <dynamic>[],
        rawEnvelope: const <String, dynamic>{'model': 'tom-assistant'},
      ),
      configuration: const Configuration(
        entries: <ConfigEntry>[
          ConfigEntry(
            role: 'assistant',
            provider: 'local',
            model: 'gemma3:27b',
            profile: 'default',
          ),
        ],
        memoryProfile: 'default',
      ),
      reply: const Reply(
        finalAnswer: 'We decided on tiered backup.',
        outcomeStatus: 'accepted',
        wallClockMs: 2100,
      ),
      runTree: withRunTree
          ? const ProcedureRun(
              procedureId: 'answer_with_memory_v1',
              runId: 'run-root',
              turnId: '260101-120000.000001',
              status: 'accepted',
              elapsedMs: 2100,
              entryCount: 0,
              nodes: <RunNode>[],
            )
          : null,
    );

Future<void> _pump(WidgetTester tester, PromptTrace trace) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: ListView(children: buildTraceSections(trace))),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the four §4.2 sections', (tester) async {
    await _pump(tester, _trace());
    expect(find.text('Inbound'), findsOneWidget);
    expect(find.text('Configuration'), findsOneWidget);
    expect(find.text('Reply'), findsOneWidget);
    expect(find.text('Run Tree'), findsOneWidget);
  });

  testWidgets('the configuration-in-effect view renders the distinct tuple',
      (tester) async {
    await _pump(tester, _trace());
    // The Configuration section is collapsed by default; expand it to build
    // its body (an ExpansionTile only builds children while expanded).
    await tester.tap(find.text('Configuration'));
    await tester.pumpAndSettle();
    expect(find.byType(ConfigurationInEffectView), findsOneWidget);
    // role · provider/model · profile chip (§4.3).
    expect(find.textContaining('assistant'), findsWidgets);
    expect(find.textContaining('local/gemma3:27b'), findsOneWidget);
  });

  testWidgets('a section absent for the turn is disabled', (tester) async {
    await _pump(tester, _trace(withRunTree: false));
    final runTree = tester.widget<TraceSection>(find.ancestor(
      of: find.text('Run Tree'),
      matching: find.byType(TraceSection),
    ));
    expect(runTree.present, isFalse);
  });

  testWidgets('an in-flight turn streams its Reply via the live-tail (PT-4.2)',
      (tester) async {
    final controller = StreamController<LiveStep>();
    addTearDown(controller.close);
    const inFlight = PromptTrace(
      turnId: '260101-120300.000004',
      inbound: null,
      configuration: Configuration(entries: <ConfigEntry>[], memoryProfile: null),
      reply: null, // in flight — no static reply yet
      runTree: null,
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(
          children: buildTraceSections(
            inFlight,
            liveReply: LiveReplyView(steps: controller.stream),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // The Reply section is present (streaming) and shows the live view expanded.
    final reply = tester.widget<TraceSection>(find.ancestor(
      of: find.text('Reply'),
      matching: find.byType(TraceSection),
    ));
    expect(reply.present, isTrue);
    expect(find.byType(LiveReplyView), findsOneWidget);

    // A streamed assistant block appears in place without a static reply.
    controller.add(const LiveStep(
        heading: '💬 assistant', body: 'streaming answer', isDone: false));
    await tester.pumpAndSettle();
    expect(find.text('streaming answer'), findsOneWidget);
  });

  testWidgets(
      'cross-link: tapping a persisted node id deep-links into its Module-2 '
      'node view (PT-7.1)', (tester) async {
    const turnId = '260101-120000.000001';
    final client = StubApiClient(traces: <String, PromptTrace>{
      turnId: const PromptTrace(
        turnId: turnId,
        inbound: null,
        configuration: Configuration(entries: <ConfigEntry>[], memoryProfile: null),
        reply: null,
        runTree: ProcedureRun(
          procedureId: 'answer_with_memory_v1',
          runId: 'run-root',
          turnId: turnId,
          status: 'accepted',
          elapsedMs: 2100,
          entryCount: 1,
          // A memory access referencing a known fixture node id.
          nodes: <RunNode>[
            PrimitiveCallNode(
                primitive: 'persist', resultId: 'n_fixtureA1', recall: null),
          ],
        ),
      ),
    });
    final memory = StubMemoryApiClient(nodes: <String, MemoryNode>{
      'n_fixtureA1': MemoryNode(
        id: 'n_fixtureA1',
        typeName: 'Conclusion',
        status: 'active',
        createdAt: '2026-01-01T00:00:00Z',
        values: const <String, dynamic>{'text': 'tiered backup'},
      ),
    });

    await tester.pumpWidget(MaterialApp(
      home: PromptTraceDetailView(
          client: client, memoryClient: memory, turnId: turnId),
    ));
    await tester.pumpAndSettle();

    // The run-tree section is expanded; expand the root run to reveal the
    // persisted-node row, then tap it to walk into Module 2.
    await tester.tap(find.textContaining('answer_with_memory_v1'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('persist → n_fixtureA1'));
    await tester.pumpAndSettle();

    expect(find.byType(NodeDetailView), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Node n_fixtureA1'), findsOneWidget);
  });
}
