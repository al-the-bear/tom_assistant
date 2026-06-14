// Slice 4 — the editable procedure surface (§ 6.3, AUTH-1…AUTH-5). The script
// inspector gains an "edit" affordance that opens the verbatim source in a
// monospace text area; "save" marshals the buffer to
// `PUT /api/procedures/<id>` (the brain re-reads it on its next run, AUTH-5).
// A `422` keeps the buffer and surfaces the brain's own validator findings, so
// a rejected save never silently drops the operator's edit.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_brain_observatory_web/src/model/authoring.dart';
import 'package:tom_brain_observatory_web/src/views/procedure_editor.dart';

import '../support/stub_api_client.dart';

const _source = "Future<ProcedureResult> run(ProcedureInputs i) async => x;\n";

Future<void> _pump(WidgetTester tester, Widget child) async {
  // The editor is always hosted inside a Scaffold body in production
  // (ProcedureScriptView); wrap it so TextField/ScaffoldMessenger resolve.
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the source in an editable field and saves the edit',
      (tester) async {
    final client = StubApiClient();
    await _pump(
      tester,
      ProcedureEditor(
        client: client,
        procedureId: 'answer_v1',
        initialSource: _source,
      ),
    );

    final field = find.byType(TextField);
    expect(field, findsOneWidget);
    expect(tester.widget<TextField>(field).controller!.text, _source);

    await tester.enterText(field, 'EDITED SOURCE');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(client.procedureWrites.single, ('answer_v1', 'EDITED SOURCE'));
    expect(client.scripts['answer_v1'], 'EDITED SOURCE');
  });

  testWidgets('surfaces the validator findings on a rejected save (422)',
      (tester) async {
    final client = StubApiClient(
      rejectWrites: AuthoringResult.rejected(const <AuthoringFinding>[
        AuthoringFinding(
          code: 'procedure.sandbox.violation',
          message: 'reaches outside the bridged surface',
        ),
      ]),
    );
    await _pump(
      tester,
      ProcedureEditor(
        client: client,
        procedureId: 'answer_v1',
        initialSource: _source,
      ),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    // The findings are shown; the buffer is kept (still editable, not reset).
    expect(find.textContaining('procedure.sandbox.violation'), findsOneWidget);
    expect(find.textContaining('reaches outside the bridged surface'),
        findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        _source);
  });
}
