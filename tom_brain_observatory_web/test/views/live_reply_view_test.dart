// PT-4.2 (widget) — the streaming Reply view (§ 3.5, § 4.8). It replays the
// `💬 assistant` blocks as they arrive over the SSE live-tail, shows the current
// non-assistant step as a running status, and on the `✅ DONE` banner stops the
// progress indicator and shows the outcome.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_brain_observatory_web/src/model/live_step.dart';
import 'package:tom_brain_observatory_web/src/views/live_reply_view.dart';

Future<void> _pump(WidgetTester tester, Stream<LiveStep> steps) async {
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: LiveReplyView(steps: steps))),
  );
}

void main() {
  testWidgets('replays assistant blocks and shows progress until DONE',
      (tester) async {
    final controller = StreamController<LiveStep>();
    await _pump(tester, controller.stream);

    // A non-assistant step surfaces as a running status + a progress indicator.
    controller.add(const LiveStep(
        heading: '🧠 thinking (recall_planner)', body: '', isDone: false));
    await tester.pump();
    expect(find.textContaining('thinking'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // The assistant block is rendered verbatim as it arrives.
    controller.add(const LiveStep(
        heading: '💬 assistant',
        body: 'We settled on the tiered backup topology.',
        isDone: false));
    await tester.pump();
    expect(find.text('We settled on the tiered backup topology.'), findsOneWidget);

    // DONE stops the progress and shows the outcome banner.
    controller.add(const LiveStep(
        heading: '✅ DONE (llmCalls=2, memCalls=1, toolCalls=1, 2100ms)',
        body: '',
        isDone: true));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.textContaining('2100ms'), findsOneWidget);

    await controller.close();
  });
}
