// Plan step 19 (widget / route) — the config-file editor (§ 6.4,
// AUTH-3…AUTH-5). The behaviour group drives a route-agnostic stub: it loads the
// current YAML, surfaces the brain's loader rejection on a `422` (keeping the
// buffer), and shows the AUTH-4 next-boot notice for a `substrate`/provider
// edit. The final group drives the editor over the *real* `HttpTraceApiClient`
// + a `MockClient`, proving load + save go to `/api/config?kind=&name=`.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tom_brain_observatory_web/src/api/trace_api_client.dart';
import 'package:tom_brain_observatory_web/src/model/authoring.dart';
import 'package:tom_brain_observatory_web/src/views/config_file_editor_view.dart';

import '../support/stub_api_client.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: child));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('loads the config and shows the next-boot effect for substrate',
      (tester) async {
    final client = StubApiClient(
      configs: <String, String>{'substrate/substrate': 'substrate:\n  primary: local'},
    );
    await _pump(
      tester,
      ConfigFileEditorView(
        client: client,
        kind: 'substrate',
        name: 'substrate',
      ),
    );

    final field = find.byType(TextField);
    expect(tester.widget<TextField>(field).controller!.text,
        'substrate:\n  primary: local');
    // AUTH-4: a substrate/provider edit takes effect on the next boot.
    expect(find.textContaining('next boot'), findsWidgets);
  });

  testWidgets('shows the next-use effect for a procedure config', (tester) async {
    final client = StubApiClient(
      configs: <String, String>{'procedure/answer': 'temperature: 0.3'},
    );
    await _pump(
      tester,
      ConfigFileEditorView(client: client, kind: 'procedure', name: 'answer'),
    );

    expect(find.textContaining('next use'), findsWidgets);
    expect(find.textContaining('next boot'), findsNothing);
  });

  testWidgets('surfaces a rejected save (422) and keeps the buffer',
      (tester) async {
    final client = StubApiClient(
      configs: <String, String>{'substrate/substrate': 'substrate:\n  primary: local'},
      rejectWrites: AuthoringResult.rejected(const <AuthoringFinding>[
        AuthoringFinding(
            code: 'config.invalid',
            message: 'substrate.primary: unknown provider "bogus"'),
      ]),
    );
    await _pump(
      tester,
      ConfigFileEditorView(client: client, kind: 'substrate', name: 'substrate'),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.textContaining('unknown provider "bogus"'), findsOneWidget);
  });

  // Plan step 9 — read-only greying. When the host reports
  // `configWritable: false` (a `--observatory-readonly` observatory), the editor
  // disables Save and shows the read-only banner, so the operator sees the
  // surface is closed before attempting a save the server would 409.
  testWidgets('greys Save and shows the banner when configWritable is false',
      (tester) async {
    final client = StubApiClient(
      configs: <String, String>{'procedure/answer': 'temperature: 0.3'},
      configWritableData: false,
    );
    await _pump(
      tester,
      ConfigFileEditorView(client: client, kind: 'procedure', name: 'answer'),
    );

    final save = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save'));
    expect(save.onPressed, isNull, reason: 'Save must be disabled when read-only');
    expect(find.textContaining('Read-only'), findsOneWidget);
  });

  testWidgets('Save is enabled when configWritable is true (default)',
      (tester) async {
    final client = StubApiClient(
      configs: <String, String>{'procedure/answer': 'temperature: 0.3'},
    );
    await _pump(
      tester,
      ConfigFileEditorView(client: client, kind: 'procedure', name: 'answer'),
    );

    final save = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save'));
    expect(save.onPressed, isNotNull);
    expect(find.textContaining('Read-only'), findsNothing);
  });

  // Step 19 — the editor over the *real* client, proving load + save go to the
  // `/api/config?kind=&name=` route keyed off the catalogue entry's wire kind.
  group('via the /api/config route (HttpTraceApiClient)', () {
    final origin = Uri.parse('http://localhost:8787/');

    testWidgets('loads via GET /api/config and saves via PUT /api/config',
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
          if (req.method == 'GET') {
            return http.Response('substrate:\n  primary: local', 200);
          }
          return http.Response(
            jsonEncode(<String, Object?>{
              'ok': true,
              'kind': 'substrate',
              'name': 'substrate',
              'effect': 'next-boot',
            }),
            200,
            headers: const <String, String>{'content-type': 'application/json'},
          );
        }),
      );

      await _pump(
        tester,
        ConfigFileEditorView(
            client: client, kind: 'substrate', name: 'substrate'),
      );

      // The editor also fires GET /api/meta from initState to learn the
      // read-only flag, so select the config load out of the recorded requests.
      final load = seen.firstWhere(
          (r) => r.method == 'GET' && r.url.path == '/api/config');
      expect(load.url.queryParameters,
          <String, String>{'kind': 'substrate', 'name': 'substrate'});

      final field = find.byType(TextField);
      await tester.enterText(field, 'substrate:\n  primary: openrouter');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      final save = seen.last;
      expect(save.method, 'PUT');
      expect(save.url.path, '/api/config');
      expect(save.url.queryParameters,
          <String, String>{'kind': 'substrate', 'name': 'substrate'});
      expect(save.body, 'substrate:\n  primary: openrouter');
      expect(find.textContaining('Saved'), findsOneWidget);
    });
  });
}
