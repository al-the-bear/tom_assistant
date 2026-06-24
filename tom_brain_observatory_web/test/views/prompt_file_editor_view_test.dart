// Slice 4 — the externalized prompt-file editor (§ 6.3, AUTH-1…AUTH-5). A role's
// persona / objective prose opens in a monospace text area; "save" marshals it
// to `PUT /api/templates?id=<roleId>&part=<part>` so the brain re-reads it the
// next time it assembles a call for that role (AUTH-5). When no override exists
// yet the GET reports an empty half and the editor starts empty as a "create
// override" — the first save materialises the file.
//
// The behaviour group below drives a route-agnostic stub. The final group
// (step 18) drives the editor over the *real* `HttpTraceApiClient` + a
// `MockClient`, proving the load GET and save PUT both go to the migrated
// `/api/templates?id=&part=` route keyed off the call's role id.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tom_brain_observatory_web/src/api/trace_api_client.dart';
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

  // Step 18 — the editor over the *real* client, proving it loads + saves a
  // template through the migrated `/api/templates?id=&part=` route (not the
  // removed `/api/prompts/<roleId>/<part>`), keyed off the call's role id/part.
  group('via the migrated /api/templates route (HttpTraceApiClient)', () {
    final origin = Uri.parse('http://localhost:8787/');

    testWidgets('loads via GET /api/templates and saves via PUT /api/templates',
        (tester) async {
      final seen = <http.Request>[];
      final client = HttpTraceApiClient(
        origin: origin,
        httpClient: MockClient((req) async {
          seen.add(req);
          if (req.url.path == '/api/meta') {
            return http.Response(
              jsonEncode(<String, Object?>{'configWritable': true}),
              200,
              headers: const <String, String>{'content-type': 'application/json'},
            );
          }
          if (req.method == 'GET') return http.Response('old persona prose', 200);
          return http.Response(
            jsonEncode(<String, Object?>{'ok': true}),
            200,
            headers: const <String, String>{'content-type': 'application/json'},
          );
        }),
      );

      await _pump(
        tester,
        PromptFileEditorView(
          client: client,
          roleId: 'analyser',
          part: 'persona',
        ),
      );

      // The load is a GET to the template surface keyed off the role id/part.
      // The editor also fires GET /api/meta from initState, so select the
      // template load out of the recorded requests.
      final load = seen.firstWhere(
          (r) => r.method == 'GET' && r.url.path == '/api/templates');
      expect(load.url.queryParameters,
          <String, String>{'id': 'analyser', 'part': 'persona'});

      final field = find.byType(TextField);
      expect(
          tester.widget<TextField>(field).controller!.text, 'old persona prose');

      await tester.enterText(field, 'new persona prose');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      // The save is a PUT of the buffer to the same template-surface target.
      final save = seen.last;
      expect(save.method, 'PUT');
      expect(save.url.path, '/api/templates');
      expect(save.url.queryParameters,
          <String, String>{'id': 'analyser', 'part': 'persona'});
      expect(save.body, 'new persona prose');
      expect(find.textContaining('Saved'), findsOneWidget);
    });
  });
}
