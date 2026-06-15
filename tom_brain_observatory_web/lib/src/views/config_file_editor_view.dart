// Plan step 19 — the config-file editor reached from the gear catalogue (§ 6.4,
// AUTH-3…AUTH-5). It loads a registered config file's verbatim YAML via
// `GET /api/config?kind=<kind>&name=<name>` and writes the buffer back via
// `PUT /api/config?kind=&name=` — the brain re-reads it (AUTH-5; no signal, it
// pulls). [kind] is the wire alphabet (`registry` / `procedure` / `llm_route` /
// `substrate`); the catalogue's `llm`→`llm_route` translation is done by the
// caller via `CatalogueConfigFile.configWireKind`.
//
// The save is gated by the brain's *own* loader server-side (AUTH-3): a `422`
// keeps the buffer and renders the located rejection here, so an invalid config
// is never silently dropped. The view states the AUTH-4 effect up front — a
// `procedure` config takes effect on the next use; registry / llm_route /
// substrate edits take effect on the next boot — so the operator is not
// surprised by when a save lands.

import 'package:flutter/material.dart';

import '../api/trace_api_client.dart';
import '../model/authoring.dart';
import 'authoring_findings.dart';

/// The editor for the registered config file [kind]/[name]. Fetches the current
/// content lazily on open; a registered-but-absent file (`404` → null) opens as
/// an empty buffer the first save materialises.
class ConfigFileEditorView extends StatefulWidget {
  final TraceApiClient client;

  /// The `/api/config` wire kind: `registry` / `procedure` / `llm_route` /
  /// `substrate`.
  final String kind;
  final String name;

  const ConfigFileEditorView({
    super.key,
    required this.client,
    required this.kind,
    required this.name,
  });

  @override
  State<ConfigFileEditorView> createState() => _ConfigFileEditorViewState();
}

class _ConfigFileEditorViewState extends State<ConfigFileEditorView> {
  final TextEditingController _controller = TextEditingController();

  late Future<String?> _initial;

  /// True until the initial content has been loaded into the buffer once, so a
  /// rebuild after a save does not clobber the operator's edits.
  bool _seeded = false;

  bool _saving = false;
  List<AuthoringFinding> _findings = const <AuthoringFinding>[];

  /// The AUTH-4 effect this kind's edit takes — a `procedure` config is read per
  /// prompt (`next use`), everything else is read at boot (`next boot`). Mirrors
  /// the host's `_effectFor`.
  String get _effect => widget.kind == 'procedure' ? 'next use' : 'next boot';

  @override
  void initState() {
    super.initState();
    _initial = widget.client.readConfigFile(widget.kind, widget.name);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _findings = const <AuthoringFinding>[];
    });
    AuthoringResult result;
    try {
      result = await widget.client
          .writeConfigFile(widget.kind, widget.name, _controller.text);
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Save failed: $error')));
      return;
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      _findings = result.findings;
    });
    if (result.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved — takes effect $_effect.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text('config · ${widget.kind}/${widget.name}'),
        ),
        body: FutureBuilder<String?>(
          future: _initial,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                  child: Text('Failed to load config: ${snapshot.error}'));
            }
            final existing = snapshot.data;
            if (!_seeded) {
              _controller.text = existing ?? '';
              _seeded = true;
            }
            return _editor(context, isNew: existing == null);
          },
        ),
      );

  Widget _editor(BuildContext context, {required bool isNew}) {
    final theme = Theme.of(context);
    return ListView(
      children: <Widget>[
        if (_findings.isNotEmpty) AuthoringFindingsBanner(findings: _findings),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _EffectNotice(effect: _effect),
              const SizedBox(height: 8),
              Text(
                isNew
                    ? 'config file absent on disk — saving creates '
                        '${widget.kind}/${widget.name}'
                    : 'editing config ${widget.kind}/${widget.name}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _controller,
                maxLines: null,
                minLines: 12,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  Flexible(
                    child: Text(
                      'validated by the brain before it lands; '
                      'the brain pulls it on its $_effect',
                      style: theme.textTheme.bodySmall,
                      textAlign: TextAlign.right,
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The AUTH-4 effect banner — a small tinted strip stating when a save lands so
/// the operator knows a `next boot` config will not change behaviour until the
/// brain restarts.
class _EffectNotice extends StatelessWidget {
  final String effect;
  const _EffectNotice({required this.effect});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.schedule, size: 16, color: scheme.onSecondaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Takes effect: $effect',
              style: TextStyle(color: scheme.onSecondaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}
