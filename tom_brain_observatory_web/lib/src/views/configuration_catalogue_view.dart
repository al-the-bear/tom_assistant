// Plan step 19 — the gear-icon general configuration editor (§ 6.4). A catalogue
// browser over `GET /api/catalogue` + the procedure-script listing
// (`GET /api/procedures`) + the live `GET /api/runtime` snapshot, laid out as
// five tabs:
//
//   • Templates+Fragments — the registered prompt/fragment template files and
//     the role persona/objective prose. Opens the `PromptFileEditorView`
//     (`/api/templates`).
//   • Procedures — the cognition registry index, the per-procedure yaml configs,
//     and each procedure's d4rt **script**. The registry/procedure yaml open the
//     `ConfigFileEditorView` (`/api/config`); a script opens the validated
//     `ProcedureScriptConfigView` (`/api/procedures/<id>`) — the same scripts the
//     Run Tree opens by id, here reachable by id alone for authoring.
//   • Provider settings — the `substrate:` block (provider routing + failover),
//     opened via `/api/config?kind=substrate` (a `next boot` edit).
//   • Model settings — the per-route llm configs (model selection per route),
//     opened via `/api/config?kind=llm_route` (the catalogue's `llm` kind is
//     translated by `CatalogueConfigFile.configWireKind`).
//   • Runtime — the whole-process `brain_run.yaml` run config (ports, roots, the
//     access/memory/trail/tools/mcp sections). The tab shows the *currently
//     running* values the live brain bound beside an editor for the on-disk
//     file, with a "modification requires restart" note (§ 8.3(10) `run` kind,
//     § 8.3(13) `GET /api/runtime`). The live snapshot degrades to a "runtime
//     unavailable" notice when the observatory was launched standalone; the
//     on-disk editor stays available either way.
//
// A registered-but-empty template (or an absent procedure script) appears as an
// empty editable document — the first save materialises it. When no cognition
// config is wired the catalogue is `null` (host `503`) and the catalogue-backed
// tabs degrade to an "unavailable" notice rather than an error.

import 'package:flutter/material.dart';

import '../api/trace_api_client.dart';
import '../model/catalogue.dart';
import '../model/runtime.dart';
import 'config_file_editor_view.dart';
import 'procedure_script_config_view.dart';
import 'prompt_file_editor_view.dart';

/// The §6.4 catalogue browser over [client]. Loads the catalogue, the procedure
/// script listing, and the live runtime snapshot lazily on open.
class ConfigurationCatalogueView extends StatefulWidget {
  final TraceApiClient client;

  const ConfigurationCatalogueView({super.key, required this.client});

  @override
  State<ConfigurationCatalogueView> createState() =>
      _ConfigurationCatalogueViewState();
}

class _ConfigurationCatalogueViewState
    extends State<ConfigurationCatalogueView> {
  late Future<CognitionCatalogue?> _catalogue;
  late Future<List<String>> _procedureScripts;
  late Future<RuntimeSnapshot?> _runtime;

  @override
  void initState() {
    super.initState();
    _catalogue = widget.client.catalogue();
    _procedureScripts = widget.client.listProcedureScripts();
    _runtime = widget.client.runtime();
  }

  void _openTemplatePart(String id, String part) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PromptFileEditorView(
        client: widget.client,
        roleId: id,
        part: part,
      ),
    ));
  }

  void _openConfig(String wireKind, String name) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ConfigFileEditorView(
        client: widget.client,
        kind: wireKind,
        name: name,
      ),
    ));
  }

  void _openScript(String procedureId) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ProcedureScriptConfigView(
        client: widget.client,
        procedureId: procedureId,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 5,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Configuration'),
            bottom: const TabBar(
              isScrollable: true,
              tabs: <Widget>[
                Tab(text: 'Templates+Fragments'),
                Tab(text: 'Procedures'),
                Tab(text: 'Provider settings'),
                Tab(text: 'Model settings'),
                Tab(text: 'Runtime'),
              ],
            ),
          ),
          body: TabBarView(
            children: <Widget>[
              _catalogueTab(_templatesTab),
              _catalogueTab(_proceduresTab),
              _catalogueTab((c) => _configListTab(
                    <CatalogueConfigFile>[
                      for (final f in c.configFiles)
                        if (f.kind == 'substrate') f,
                    ],
                  )),
              _catalogueTab((c) => _configListTab(
                    <CatalogueConfigFile>[
                      for (final f in c.configFiles)
                        if (f.kind == 'llm') f,
                    ],
                  )),
              _runtimeTab(),
            ],
          ),
        ),
      );

  /// Wraps a catalogue-backed tab body: spinner while loading, an error line on
  /// failure, an "unavailable" notice on a `503` (`null`) catalogue.
  Widget _catalogueTab(Widget Function(CognitionCatalogue) body) =>
      FutureBuilder<CognitionCatalogue?>(
        future: _catalogue,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
                child: Text('Failed to load catalogue: ${snapshot.error}'));
          }
          final catalogue = snapshot.data;
          if (catalogue == null) {
            return const Center(
              child: Text(
                'Configuration unavailable — the observatory was launched '
                'without a cognition root.',
                textAlign: TextAlign.center,
              ),
            );
          }
          return body(catalogue);
        },
      );

  /// Templates+Fragments: every prompt/fragment template file and every role's
  /// persona/objective prose. No config files — those live on their own tabs.
  Widget _templatesTab(CognitionCatalogue catalogue) => ListView(
        children: <Widget>[
          for (final t in catalogue.templates)
            for (final file in t.files)
              ListTile(
                leading: const Icon(Icons.description_outlined),
                title: Text('${t.id} · ${file.part}'),
                subtitle: Text(file.present ? file.path : '(empty — create)'),
                onTap: () => _openTemplatePart(t.id, file.part),
              ),
          for (final r in catalogue.roles) ...<Widget>[
            ListTile(
              leading: const Icon(Icons.badge_outlined),
              title: Text('role ${r.name} · persona'),
              subtitle: Text(r.personaPath ?? '(empty — create)'),
              onTap: () => _openTemplatePart(r.name, 'persona'),
            ),
            ListTile(
              leading: const Icon(Icons.badge_outlined),
              title: Text('role ${r.name} · objective'),
              subtitle: Text(r.objectivePath ?? '(empty — create)'),
              onTap: () => _openTemplatePart(r.name, 'objective'),
            ),
          ],
        ],
      );

  /// Procedures: the registry index + the per-procedure yaml configs (opened as
  /// config files), then each procedure's d4rt script (opened in the validated
  /// source editor). The script listing is its own future so a config-only host
  /// still renders the yaml section.
  Widget _proceduresTab(CognitionCatalogue catalogue) {
    final procedureConfigs = <CatalogueConfigFile>[
      for (final f in catalogue.configFiles)
        if (f.isPromptConfig) f, // registry + per-procedure yaml
    ];
    return ListView(
      children: <Widget>[
        for (final f in procedureConfigs) _configTile(f),
        const Divider(height: 1),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text('Procedure scripts (d4rt)'),
        ),
        _procedureScriptList(),
      ],
    );
  }

  /// The procedure-script tiles, from `GET /api/procedures`. Each opens the
  /// validated `ProcedureScriptConfigView` — the same source the Run Tree shows,
  /// reachable here by id alone.
  Widget _procedureScriptList() => FutureBuilder<List<String>>(
        future: _procedureScripts,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final scripts = snapshot.data ?? const <String>[];
          if (scripts.isEmpty) {
            return const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('(no procedure scripts hosted)'),
            );
          }
          return Column(
            children: <Widget>[
              for (final id in scripts)
                ListTile(
                  leading: const Icon(Icons.code),
                  title: Text(id),
                  subtitle: Text('scripts/system/$id.dart'),
                  onTap: () => _openScript(id),
                ),
            ],
          );
        },
      );

  Widget _configListTab(List<CatalogueConfigFile> files) {
    if (files.isEmpty) {
      return const Center(child: Text('(none registered)'));
    }
    return ListView(
      children: <Widget>[for (final f in files) _configTile(f)],
    );
  }

  /// The Runtime tab: the live bound values beside the editable on-disk run
  /// config. The live snapshot degrades to a notice when standalone; the editor
  /// tile is always offered (the on-disk file is editable either way).
  Widget _runtimeTab() => FutureBuilder<RuntimeSnapshot?>(
        future: _runtime,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final runtime = snapshot.hasError ? null : snapshot.data;
          final theme = Theme.of(context);
          return ListView(
            children: <Widget>[
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(
                  'Currently running — modification requires restart',
                ),
              ),
              if (runtime == null)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'Runtime unavailable — the observatory was launched '
                    'standalone (no live brain to query). The on-disk run '
                    'configuration can still be edited below.',
                  ),
                )
              else ...<Widget>[
                for (final g in runtime.gateways)
                  ListTile(
                    leading: const Icon(Icons.lan_outlined),
                    title: Text('${g.name} gateway'),
                    subtitle: Text(
                      'running on port ${g.port}'
                      '${g.basePath.isEmpty ? '' : ' · ${g.basePath}'}',
                    ),
                  ),
                ListTile(
                  leading: const Icon(Icons.send_outlined),
                  title: const Text('Telegram channel'),
                  subtitle:
                      Text(runtime.telegramEnabled ? 'enabled' : 'disabled'),
                ),
                if (runtime.memoryRoot != null)
                  ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: const Text('memory root'),
                    subtitle: Text(runtime.memoryRoot!),
                  ),
                if (runtime.trailRoot != null)
                  ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: const Text('trail root'),
                    subtitle: Text(runtime.trailRoot!),
                  ),
                if (runtime.cognitionRoot != null)
                  ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: const Text('cognition root'),
                    subtitle: Text(runtime.cognitionRoot!),
                  ),
              ],
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text('On-disk run configuration',
                    style: theme.textTheme.titleMedium),
              ),
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('Edit run configuration (brain_run.yaml)'),
                subtitle: const Text(
                  'Ports, roots, the access / memory / trail / tools / mcp '
                  'sections, and the conversation-history sizing. Saved edits '
                  'take effect at next boot.',
                ),
                onTap: () => _openConfig('run', 'brain_run'),
              ),
            ],
          );
        },
      );

  Widget _configTile(CatalogueConfigFile f) => ListTile(
        leading: const Icon(Icons.settings_outlined),
        title: Text('${f.kind} · ${f.name}'),
        subtitle: Text(f.path),
        onTap: () => _openConfig(f.configWireKind, f.name),
      );
}
