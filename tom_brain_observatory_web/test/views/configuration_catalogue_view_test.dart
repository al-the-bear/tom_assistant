// Plan step 19 (widget) — the gear-icon general configuration editor (§ 6.4).
// Asserts the catalogue renders as four tabs (Prompt / Providers / Models /
// Runtime), that opening a template fetches its prose into the editor, that the
// Runtime tab shows the live `/api/runtime` values beside the editable on-disk
// run config (and degrades to a "runtime unavailable" notice when standalone,
// while still offering the editor), and that a `503` catalogue degrades to an
// "unavailable" notice rather than an error.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_brain_observatory_web/src/model/catalogue.dart';
import 'package:tom_brain_observatory_web/src/model/runtime.dart';
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

Future<void> _openTab(WidgetTester tester, String label) async {
  await tester.tap(find.widgetWithText(Tab, label));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the four §6.4 tabs and routes config files by kind',
      (tester) async {
    await _pump(tester, StubApiClient(catalogueData: _catalogue));

    expect(find.widgetWithText(Tab, 'Prompt'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Providers'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Models'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Runtime'), findsOneWidget);

    // Prompt tab (default): a template part, a role, the prompt-kind config.
    expect(find.text('answer.user · system'), findsOneWidget);
    expect(find.text('role analyser · persona'), findsOneWidget);
    expect(find.text('registry · registry'), findsOneWidget);

    await _openTab(tester, 'Providers');
    expect(find.text('substrate · substrate'), findsOneWidget);

    await _openTab(tester, 'Models');
    expect(find.text('llm · default'), findsOneWidget);
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

  testWidgets('Runtime tab shows the live values beside the run-config editor',
      (tester) async {
    await _pump(
      tester,
      StubApiClient(
        catalogueData: _catalogue,
        runtimeData: const RuntimeSnapshot(
          gateways: <RuntimeGateway>[
            RuntimeGateway(name: 'openai', port: 8841, basePath: '/v1'),
          ],
          telegramEnabled: true,
          memoryRoot: '/srv/brain/mem',
        ),
      ),
    );

    await _openTab(tester, 'Runtime');

    // The currently-running values, the "requires restart" framing, and the
    // editable on-disk run config tile.
    expect(find.textContaining('modification requires restart'), findsOneWidget);
    expect(find.textContaining('running on port 8841'), findsOneWidget);
    expect(find.text('/srv/brain/mem'), findsOneWidget);
    expect(find.text('Edit run configuration (brain_run.yaml)'),
        findsOneWidget);
  });

  testWidgets(
      'Runtime tab degrades to a notice when standalone but keeps the editor',
      (tester) async {
    // catalogueData present (so the other tabs render), runtimeData null → 503.
    await _pump(tester, StubApiClient(catalogueData: _catalogue));

    await _openTab(tester, 'Runtime');

    expect(find.textContaining('Runtime unavailable'), findsOneWidget);
    expect(find.text('Edit run configuration (brain_run.yaml)'),
        findsOneWidget);
  });

  testWidgets('opening the run config from the Runtime tab targets brain_run',
      (tester) async {
    await _pump(
      tester,
      StubApiClient(
        catalogueData: _catalogue,
        configs: <String, String>{'run/brain_run': 'substrate: {}'},
      ),
    );

    await _openTab(tester, 'Runtime');
    await tester.tap(find.text('Edit run configuration (brain_run.yaml)'));
    await tester.pumpAndSettle();

    // The config editor opens on the `run` kind / `brain_run` name.
    expect(find.text('config · run/brain_run'), findsOneWidget);
  });

  testWidgets('degrades to an unavailable notice on a 503 catalogue',
      (tester) async {
    await _pump(tester, StubApiClient()); // catalogueData == null → 503

    expect(find.textContaining('Configuration unavailable'), findsOneWidget);
  });
}
