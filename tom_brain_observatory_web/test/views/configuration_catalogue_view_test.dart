// Plan step 19 (widget) — the gear-icon general configuration editor (§ 6.4),
// laid out as five tabs: Templates+Fragments (prompt/fragment template files +
// role prose), Procedures (the registry index, the per-procedure yaml configs,
// AND each procedure's d4rt script — the same scripts the Run Tree opens by id),
// Provider settings (the `substrate:` block), Model settings (the per-route llm
// configs), and Runtime (the live bound values beside the on-disk run-config
// editor). Asserts each tab routes its files by kind, that a template fetches
// its prose into the editor, that a procedure script opens the validated source
// editor, and that the catalogue / runtime degrade to notices rather than
// errors.

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
        kind: 'procedure', name: 'assist_user', path: 'assist_user.yaml'),
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
  // The TabBar is scrollable (five tabs); a trailing tab can sit off the test
  // viewport, so bring it into view before tapping.
  final tab = find.widgetWithText(Tab, label);
  await tester.ensureVisible(tab);
  await tester.pumpAndSettle();
  await tester.tap(tab);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the five §6.4 tabs and routes config files by kind',
      (tester) async {
    await _pump(
      tester,
      StubApiClient(
        catalogueData: _catalogue,
        procedureIds: const <String>['answer_with_memory_v1'],
      ),
    );

    expect(find.widgetWithText(Tab, 'Templates+Fragments'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Procedures'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Provider settings'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Model settings'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Runtime'), findsOneWidget);

    // Templates+Fragments tab (default): a template part and a role — no config
    // files (those live on their own tabs).
    expect(find.text('answer.user · system'), findsOneWidget);
    expect(find.text('role analyser · persona'), findsOneWidget);
    expect(find.text('registry · registry'), findsNothing);

    await _openTab(tester, 'Procedures');
    expect(find.text('registry · registry'), findsOneWidget);
    expect(find.text('procedure · assist_user'), findsOneWidget);
    // The procedure's d4rt script, listed beside the yaml.
    expect(find.text('answer_with_memory_v1'), findsOneWidget);

    await _openTab(tester, 'Provider settings');
    expect(find.text('substrate · substrate'), findsOneWidget);

    await _openTab(tester, 'Model settings');
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

  testWidgets('opening a procedure script fetches its source into the editor',
      (tester) async {
    await _pump(
      tester,
      StubApiClient(
        catalogueData: _catalogue,
        scripts: <String, String>{'answer_with_memory_v1': 'void main() {}'},
      ),
    );

    await _openTab(tester, 'Procedures');
    await tester.tap(find.text('answer_with_memory_v1'));
    await tester.pumpAndSettle();

    // The validated source editor opens on the procedure id, seeded with the
    // fetched d4rt source.
    expect(find.text('script · answer_with_memory_v1'), findsOneWidget);
    final field = find.byType(TextField);
    expect(tester.widget<TextField>(field).controller!.text, 'void main() {}');
  });

  testWidgets('opening a procedure yaml config targets the procedure kind',
      (tester) async {
    await _pump(
      tester,
      StubApiClient(
        catalogueData: _catalogue,
        configs: <String, String>{'procedure/assist_user': 'temperature: 1.0'},
      ),
    );

    await _openTab(tester, 'Procedures');
    await tester.tap(find.text('procedure · assist_user'));
    await tester.pumpAndSettle();

    expect(find.text('config · procedure/assist_user'), findsOneWidget);
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
