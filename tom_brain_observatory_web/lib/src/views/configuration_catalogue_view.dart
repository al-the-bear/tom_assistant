// Plan step 19 — the gear-icon general configuration editor (§ 6.4). A catalogue
// browser over `GET /api/catalogue` plus the live `GET /api/runtime` snapshot,
// laid out as four tabs:
//
//   • Prompt — the registered prompt/fragment templates, the role persona/
//     objective prose, and the registry + per-procedure config files. Templates
//     and roles open the `PromptFileEditorView` (`/api/templates`); config files
//     open the `ConfigFileEditorView` (`/api/config`).
//   • Providers — the `substrate:` block (provider routing + failover), opened
//     via `/api/config?kind=substrate` (a `next boot` edit).
//   • Models — the per-route llm configs (model selection per route), opened via
//     `/api/config?kind=llm_route` (the catalogue's `llm` kind is translated by
//     `CatalogueConfigFile.configWireKind`).
//   • Runtime — the whole-process `brain_run.yaml` run config (ports, roots, the
//     access/memory/trail/tools/mcp sections). The tab shows the *currently
//     running* values the live brain bound beside an editor for the on-disk
//     file, with a "modification requires restart" note (§ 8.3(10) `run` kind,
//     § 8.3(13) `GET /api/runtime`). The live snapshot degrades to a "runtime
//     unavailable" notice when the observatory was launched standalone; the
//     on-disk editor stays available either way.
//
// A registered-but-empty template appears as an empty editable document (the
// editor turns an absent file into a create-override). When no cognition config
// is wired the catalogue is `null` (host `503`) and the prompt/provider/model
// tabs degrade to an "unavailable" notice rather than an error.

import 'package:flutter/material.dart';

import '../api/trace_api_client.dart';
import '../model/catalogue.dart';
import '../model/runtime.dart';
import 'config_file_editor_view.dart';
import 'prompt_file_editor_view.dart';

/// The §6.4 catalogue browser over [client]. Loads the catalogue and the live
/// runtime snapshot lazily on open.
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
  late Future<RuntimeSnapshot?> _runtime;

  @override
  void initState() {
    super.initState();
    _catalogue = widget.client.catalogue();
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

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 4,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Configuration'),
            bottom: const TabBar(
              tabs: <Widget>[
                Tab(text: 'Prompt'),
                Tab(text: 'Providers'),
                Tab(text: 'Models'),
                Tab(text: 'Runtime'),
              ],
            ),
          ),
          body: TabBarView(
            children: <Widget>[
              _catalogueTab((c) => _promptTab(c)),
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

  Widget _promptTab(CognitionCatalogue catalogue) {
    final promptConfigs = <CatalogueConfigFile>[
      for (final f in catalogue.configFiles)
        if (f.isPromptConfig) f,
    ];
    return ListView(
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
        for (final f in promptConfigs) _configTile(f),
      ],
    );
  }

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
                  'Ports, roots, and the access / memory / trail / tools / mcp '
                  'sections. Saved edits take effect at next boot.',
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
