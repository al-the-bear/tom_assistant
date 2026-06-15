// Plan step 19 (widget) — the gear-icon general configuration editor (§ 6.4).
// Asserts the catalogue renders the three sections (Prompt configuration &
// templates / Provider settings / Model settings), that opening a template
// fetches its prose into the editor, and that a `503` catalogue degrades to an
// "unavailable" notice rather than an error.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_brain_observatory_web/src/model/catalogue.dart';
import 'package:tom_brain_observatory_web/src/views/configuration_catalogue_view.dart';

import '../support/stub_api_client.dart';

const _catalogue = CognitionCatalogue(
  templates: <CatalogueTemplate>[
    CatalogueTemplate(
      id: 'answer.user',
      kind: 'prompt',
      files: <CatalogueTemplateFile>[
        CatalogueTemplateFile(
            path: 'answer/user.system.md', part: 'system', present: true),
        CatalogueTemplateFile(
            path: 'answer/user.user.md', part: 'user', present: false),
      ],
    ),
  ],
  roles: <CatalogueRole>[
    CatalogueRole(
        name: 'analyser',
        personaPath: 'roles/analyser.persona.md',
        objectivePath: 'roles/analyser.objective.md'),
  ],
  configFiles: <CatalogueConfigFile>[
    CatalogueConfigFile(
        kind: 'registry', name: 'registry', path: 'registry.yaml'),
    CatalogueConfigFile(
        kind: 'substrate', name: 'substrate', path: 'brain_run.yaml'),
    CatalogueConfigFile(kind: 'llm', name: 'default', path: 'llm/default.yaml'),
  ],
);

Future<void> _pump(WidgetTester tester, StubApiClient client) async {
  await tester.pumpWidget(
    MaterialApp(home: ConfigurationCatalogueView(client: client)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the three §6.4 sections', (tester) async {
    await _pump(tester, StubApiClient(catalogueData: _catalogue));

    expect(find.text('Prompt configuration & templates'), findsOneWidget);
    expect(find.text('Provider settings'), findsOneWidget);
    expect(find.text('Model settings'), findsOneWidget);

    // A template part, a role, and the kind-routed config files appear.
    expect(find.text('answer.user · system'), findsOneWidget);
    expect(find.text('role analyser · persona'), findsOneWidget);
    expect(find.text('registry · registry'), findsOneWidget); // prompt section
    expect(find.text('substrate · substrate'), findsOneWidget); // provider
    expect(find.text('llm · default'), findsOneWidget); // model section
  });

  testWidgets('opening a template fetches it into the editor', (tester) async {
    await _pump(
      tester,
      StubApiClient(
        catalogueData: _catalogue,
        prompts: <String, String>{'answer.user/system': 'system prose'},
      ),
    );

    await tester.tap(find.text('answer.user · system'));
    await tester.pumpAndSettle();

    // The prompt-file editor opens keyed off the template id/part, seeded with
    // the fetched override prose.
    expect(find.text('prompt · answer.user.system'), findsOneWidget);
    final field = find.byType(TextField);
    expect(tester.widget<TextField>(field).controller!.text, 'system prose');
  });

  testWidgets('degrades to an unavailable notice on a 503 catalogue',
      (tester) async {
    await _pump(tester, StubApiClient()); // catalogueData == null → 503

    expect(find.textContaining('Configuration unavailable'), findsOneWidget);
  });
}
