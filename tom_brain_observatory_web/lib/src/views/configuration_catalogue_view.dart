// Plan step 19 — the gear-icon general configuration editor (§ 6.4). A catalogue
// browser over `GET /api/catalogue` with three sections:
//
//   • Prompt configuration & templates — the registered prompt/fragment
//     templates, the role persona/objective prose, and the registry +
//     per-procedure config files. Templates and roles open the
//     `PromptFileEditorView` (`/api/templates`); config files open the
//     `ConfigFileEditorView` (`/api/config`).
//   • Provider settings — the `substrate:` block (provider routing + failover),
//     opened via `/api/config?kind=substrate` (a `next boot` edit).
//   • Model settings — the per-route llm configs (model selection per route),
//     opened via `/api/config?kind=llm_route` (the catalogue's `llm` kind is
//     translated by `CatalogueConfigFile.configWireKind`).
//
// A registered-but-empty template appears as an empty editable document (the
// editor turns an absent file into a create-override). When no cognition config
// is wired the catalogue is `null` (host `503`) and the view degrades to an
// "unavailable" notice rather than an error.

import 'package:flutter/material.dart';

import '../api/trace_api_client.dart';
import '../model/catalogue.dart';
import 'config_file_editor_view.dart';
import 'prompt_file_editor_view.dart';

/// The §6.4 catalogue browser over [client]. Loads the catalogue lazily on open.
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

  @override
  void initState() {
    super.initState();
    _catalogue = widget.client.catalogue();
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
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Configuration')),
        body: FutureBuilder<CognitionCatalogue?>(
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
            return _catalogueBody(catalogue);
          },
        ),
      );

  Widget _catalogueBody(CognitionCatalogue catalogue) {
    final promptConfigs = <CatalogueConfigFile>[
      for (final f in catalogue.configFiles)
        if (f.isPromptConfig) f,
    ];
    final providerConfigs = <CatalogueConfigFile>[
      for (final f in catalogue.configFiles)
        if (f.kind == 'substrate') f,
    ];
    final modelConfigs = <CatalogueConfigFile>[
      for (final f in catalogue.configFiles)
        if (f.kind == 'llm') f,
    ];

    return ListView(
      children: <Widget>[
        _Section(
          title: 'Prompt configuration & templates',
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
            for (final f in promptConfigs)
              _configTile(f),
          ],
        ),
        _Section(
          title: 'Provider settings',
          children: <Widget>[
            for (final f in providerConfigs) _configTile(f),
          ],
        ),
        _Section(
          title: 'Model settings',
          children: <Widget>[
            for (final f in modelConfigs) _configTile(f),
          ],
        ),
      ],
    );
  }

  Widget _configTile(CatalogueConfigFile f) => ListTile(
        leading: const Icon(Icons.settings_outlined),
        title: Text('${f.kind} · ${f.name}'),
        subtitle: Text(f.path),
        onTap: () => _openConfig(f.configWireKind, f.name),
      );
}

/// A titled section with its rows, or an "(none registered)" placeholder when
/// the catalogue registers nothing for it.
class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _Section({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(title, style: theme.textTheme.titleMedium),
        ),
        if (children.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('(none registered)'),
          )
        else
          ...children,
        const Divider(height: 1),
      ],
    );
  }
}
