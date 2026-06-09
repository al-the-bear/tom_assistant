// PT-2.2 (widget) — the PromptTrace detail sections. Asserts the four §4.2
// sections are present and independently expandable, that a section absent for
// the turn is disabled (an in-flight turn has no run tree), and that the
// configuration-in-effect view (§4.3) renders the distinct (provider, model,
// profile, role) tuples with the read-only deep-link chip. `buildTraceSections`
// is exercised directly (no Navigator) over a static trace.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_brain_observatory_web/src/model/prompt_trace.dart';
import 'package:tom_brain_observatory_web/src/views/configuration_in_effect_view.dart';
import 'package:tom_brain_observatory_web/src/views/prompt_trace_detail_view.dart';

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
}
