// Slice 4 — the editable procedure surface (§ 6.3, AUTH-1…AUTH-5). Opened from
// the read-only script inspector's "edit" affordance, it shows the verbatim d4rt
// source in a monospace text area and writes the buffer back to the brain's
// `scripts/system/<procedureId>.dart` via `PUT /api/procedures/<id>` — the brain
// re-reads it on its next run (AUTH-5; no signal, the brain pulls).
//
// The save is gated by the brain's own `ProcedureValidationChain` server-side
// (AUTH-3): a `422` keeps the buffer and renders the findings here, so a rejected
// edit is never silently dropped. A clean `200` reports "saved" and hands the
// fresh source back to the caller via [onSaved] so the inspector re-correlates.

import 'package:flutter/material.dart';

import '../api/trace_api_client.dart';
import '../model/authoring.dart';
import 'authoring_findings.dart';

/// The monospace editor for the procedure [procedureId], seeded with
/// [initialSource]. On a clean save [onSaved] is invoked with the saved buffer
/// (so a host inspector can refresh its read-only correlated view).
class ProcedureEditor extends StatefulWidget {
  final TraceApiClient client;
  final String procedureId;
  final String initialSource;
  final ValueChanged<String>? onSaved;

  const ProcedureEditor({
    super.key,
    required this.client,
    required this.procedureId,
    required this.initialSource,
    this.onSaved,
  });

  @override
  State<ProcedureEditor> createState() => _ProcedureEditorState();
}

class _ProcedureEditorState extends State<ProcedureEditor> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialSource);

  bool _saving = false;

  /// The findings from the last rejected save (`422`), or empty when the last
  /// save was clean or none has run.
  List<AuthoringFinding> _findings = const <AuthoringFinding>[];

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
          .writeProcedureScript(widget.procedureId, _controller.text);
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
      widget.onSaved?.call(_controller.text);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved — the brain re-reads it next run.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_findings.isNotEmpty) AuthoringFindingsBanner(findings: _findings),
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _controller,
            maxLines: null,
            minLines: 12,
            expands: false,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: 'source · ${widget.procedureId}.dart',
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              Flexible(
                child: Text(
                  'validated before it lands; the brain pulls it next run',
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
        ),
      ],
    );
  }
}
