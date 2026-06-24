// Slice 4 — the externalized prompt-file editor page (§ 6.3, AUTH-1…AUTH-5).
// Opened from a role's "edit prompt files" affordance (§ 4.5), it loads a role's
// `<roleId>.<part>.md` override prose (`part ∈ {persona, objective}`) via
// `GET /api/templates?id=<roleId>&part=<part>` and writes the buffer back via
// `PUT /api/templates?id=<roleId>&part=<part>` — the unified template surface
// (step 18; the old `/api/prompts/{roleId}/{part}` route is removed). The brain
// re-reads it the next time it assembles a call for that role (AUTH-5; no
// signal, the brain pulls).
//
// A `404` on load means no override exists yet: the editor starts empty as a
// "create override", and the first save materialises the file. A blank save is
// rejected `422` (the findings banner shows why) and the buffer is kept.

import 'package:flutter/material.dart';

import '../api/trace_api_client.dart';
import '../model/authoring.dart';
import 'authoring_findings.dart';
import 'read_only_notice.dart';

/// The override editor for a role's [part] prose. Fetches the current override
/// lazily on open; a missing override is the create-override starting point.
class PromptFileEditorView extends StatefulWidget {
  final TraceApiClient client;
  final String roleId;
  final String part;

  const PromptFileEditorView({
    super.key,
    required this.client,
    required this.roleId,
    required this.part,
  });

  @override
  State<PromptFileEditorView> createState() => _PromptFileEditorViewState();
}

class _PromptFileEditorViewState extends State<PromptFileEditorView> {
  final TextEditingController _controller = TextEditingController();

  late Future<String?> _initial;

  /// True until the initial override has been loaded into the buffer once, so a
  /// rebuild after a save does not clobber the operator's edits.
  bool _seeded = false;

  bool _saving = false;

  /// Whether the host accepts authoring writes (`GET /api/meta`); `false` greys
  /// Save and shows the read-only banner. Optimistically `true` until the meta
  /// fetch resolves.
  bool _writable = true;

  List<AuthoringFinding> _findings = const <AuthoringFinding>[];

  @override
  void initState() {
    super.initState();
    _initial = widget.client.readPromptFile(widget.roleId, widget.part);
    widget.client.configWritable().then((writable) {
      if (mounted) setState(() => _writable = writable);
    });
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
          .writePromptFile(widget.roleId, widget.part, _controller.text);
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
        const SnackBar(content: Text('Saved — the brain re-reads it next call.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text('prompt · ${widget.roleId}.${widget.part}'),
        ),
        body: FutureBuilder<String?>(
          future: _initial,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(child: Text('Failed to load prompt: ${snapshot.error}'));
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
              if (!_writable) ...<Widget>[
                const ReadOnlyNotice(),
                const SizedBox(height: 8),
              ],
              Text(
                isNew
                    ? 'no override yet — create override for '
                        '${widget.roleId}.${widget.part}'
                    : 'editing override ${widget.roleId}.${widget.part}.md',
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
                      'the brain re-reads this prose on its next call for the role',
                      style: theme.textTheme.bodySmall,
                      textAlign: TextAlign.right,
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: (_saving || !_writable) ? null : _save,
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
