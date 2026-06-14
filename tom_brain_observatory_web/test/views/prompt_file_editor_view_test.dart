// Slice 4 — the externalized prompt-file editor (§ 6.3, AUTH-1…AUTH-5). A role's
// persona / objective prose opens in a monospace text area; "save" marshals it
// to `PUT /api/prompts/<roleId>/<part>` so the brain re-reads it the next time it
// assembles a call for that role (AUTH-5). When no override exists yet the GET
// 404s and the editor starts empty as a "create override" — the first save
// materialises the file.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_brain_observatory_web/src/model/authoring.dart';
import 'package:tom_brain_observatory_web/src/views/prompt_file_editor_view.dart';

import '../support/stub_api_client.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: child));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('loads the existing override and saves an edit', (tester) async {
    final client = StubApiClient(
      prompts: <String, String>{'analyser/persona': 'old persona prose'},
    );
    await _pump(
      tester,
      PromptFileEditorView(
        client: client,
        roleId: 'analyser',
        part: 'persona',
      ),
    );

    final field = find.byType(TextField);
    expect(tester.widget<TextField>(field).controller!.text, 'old persona prose');

    await tester.enterText(field, 'new persona prose');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(client.promptWrites.single,
        ('analyser', 'persona', 'new persona prose'));
    expect(client.prompts['analyser/persona'], 'new persona prose');
  });

  testWidgets('starts empty as a create-override when no file exists (404)',
      (tester) async {
    final client = StubApiClient(); // no prompts
    await _pump(
      tester,
      PromptFileEditorView(
        client: client,
        roleId: 'answerer',
        part: 'objective',
      ),
    );

    expect(find.textContaining('create override'), findsOneWidget);
    final field = find.byType(TextField);
    expect(tester.widget<TextField>(field).controller!.text, '');

    await tester.enterText(field, 'fresh objective');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(client.promptWrites.single, ('answerer', 'objective', 'fresh objective'));
  });

  testWidgets('surfaces a rejected save and keeps the buffer', (tester) async {
    final client = StubApiClient(
      prompts: <String, String>{'analyser/persona': 'x'},
      rejectWrites: AuthoringResult.rejected(const <AuthoringFinding>[
        AuthoringFinding(
            code: 'prompt.invalid', message: 'prompt prose must be non-empty'),
      ]),
    );
    await _pump(
      tester,
      PromptFileEditorView(
        client: client,
        roleId: 'analyser',
        part: 'persona',
      ),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.textContaining('prompt prose must be non-empty'), findsOneWidget);
  });
}
