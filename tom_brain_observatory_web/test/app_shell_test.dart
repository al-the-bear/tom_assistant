// PT-2.0/PT-2.1 — the app-shell smoke test. The shell mounts the prompt-list
// view over the injected [TraceApiClient] (a stub here, not a live brain): rows
// render newest-first as given, and the empty-state shows when none are traced.
// This proves the shell → client → §3.9-row → rendered-row path end to end; the
// production client (HttpTraceApiClient) talks to the same-origin `/api`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_brain_observatory_web/src/app.dart';
import 'package:tom_brain_observatory_web/src/views/prompt_list_view.dart';

import 'support/stub_api_client.dart';

void main() {
  testWidgets('renders the rows returned by the API client', (tester) async {
    await tester.pumpWidget(ObservatoryApp(
      client: StubApiClient(rows: [
        stubRow('260101-120200.000003', preview: 'newest prompt'),
        stubRow('260101-120100.000002', preview: 'older prompt'),
      ]),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(PromptListTile), findsNWidgets(2));
    expect(find.text('newest prompt'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('260101-120200.000003')), findsOneWidget);
  });

  testWidgets('shows the empty-state when no prompts are traced', (tester) async {
    await tester.pumpWidget(const ObservatoryApp(client: StubApiClient()));
    await tester.pumpAndSettle();

    expect(find.text('No prompts traced yet.'), findsOneWidget);
  });
}
