// PT-3.2 — the procedure-script inspector page (§ 4.6). Opened from a run row's
// "inspect script" action, it fetches the verbatim d4rt source behind the run's
// procedureId (`GET /api/procedures/<id>`, the [TraceApiClient.procedureScript]
// surface) and renders it **read-only**, line-numbered, with the lines that
// issue an act the run executed visibly correlated (a tinted gutter + a
// trailing marker). The acts the run executed are also listed as chips.
//
// Correlation is best-effort by contract (§ 4.6 / `run_step_correlation.dart`):
// the trail carries no source line numbers, so a highlighted line means "this
// line issues an act the run executed", not an authoritative 1:1 mapping.

import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/trace_api_client.dart';
import '../model/prompt_trace.dart';
import 'procedure_editor.dart';
import 'run_step_correlation.dart';

/// The script inspector for [run], over [client]. Fetches the source lazily.
class ProcedureScriptView extends StatefulWidget {
  final TraceApiClient client;
  final ProcedureRun run;

  const ProcedureScriptView({
    super.key,
    required this.client,
    required this.run,
  });

  @override
  State<ProcedureScriptView> createState() => _ProcedureScriptViewState();
}

class _ProcedureScriptViewState extends State<ProcedureScriptView> {
  late Future<String?> _source;

  /// When true the body is the editable source area (§ 6.3); otherwise the
  /// read-only correlated listing. Toggled from the AppBar edit affordance.
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _source = widget.client.procedureScript(widget.run.procedureId);
  }

  /// After a clean save the freshly-written source replaces the future so a
  /// switch back to the read view re-correlates against what actually landed.
  void _onSaved(String saved) {
    setState(() {
      _source = Future<String?>.value(saved);
      _editing = false;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text('script · ${widget.run.procedureId}'),
          actions: <Widget>[
            IconButton(
              tooltip: _editing ? 'View' : 'Edit source',
              icon: Icon(_editing ? Icons.visibility : Icons.edit),
              onPressed: () => setState(() => _editing = !_editing),
            ),
          ],
        ),
        body: FutureBuilder<String?>(
          future: _source,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(child: Text('Failed to load script: ${snapshot.error}'));
            }
            final source = snapshot.data;
            if (source == null) {
              return Center(
                child: Text('No source for procedure ${widget.run.procedureId}.'),
              );
            }
            if (_editing) {
              return SingleChildScrollView(
                child: ProcedureEditor(
                  client: widget.client,
                  procedureId: widget.run.procedureId,
                  initialSource: source,
                  onSaved: _onSaved,
                ),
              );
            }
            return ProcedureScriptBody(run: widget.run, source: source);
          },
        ),
      );
}

/// The §4.6 body: the executed-acts summary + the correlated source listing.
/// Pure (no Future/Navigator) so widget tests exercise it directly.
class ProcedureScriptBody extends StatelessWidget {
  final ProcedureRun run;
  final String source;

  const ProcedureScriptBody({super.key, required this.run, required this.source});

  @override
  Widget build(BuildContext context) {
    final acts = executedActs(run);
    final highlighted = correlateLines(source, acts);
    final lines = const LineSplitter().convert(source);
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Text('executed in this run', style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        if (acts.isEmpty)
          const Text('(no correlatable acts)')
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final act in acts.toList()..sort())
                Chip(
                  label: Text(act),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        const SizedBox(height: 16),
        Text('source', style: theme.textTheme.labelLarge),
        const SizedBox(height: 4),
        _SourceListing(lines: lines, highlighted: highlighted),
      ],
    );
  }
}

/// A read-only, line-numbered listing. A line in [highlighted] is tinted to mark
/// that it issues an act the run executed (§ 4.6). The whole listing is
/// selectable for copy; nothing here can mutate the script (OBS-1).
class _SourceListing extends StatelessWidget {
  final List<String> lines;
  final Set<int> highlighted;

  const _SourceListing({required this.lines, required this.highlighted});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final gutterWidth = '${lines.length}'.length * 9.0 + 12;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (var i = 0; i < lines.length; i++)
            _SourceLine(
              number: i + 1,
              text: lines[i],
              correlated: highlighted.contains(i),
              gutterWidth: gutterWidth,
            ),
        ],
      ),
    );
  }
}

/// One source line: a line-number gutter, the verbatim text, and — when
/// [correlated] — a tinted background marking it as a line the run executed.
class _SourceLine extends StatelessWidget {
  final int number;
  final String text;
  final bool correlated;
  final double gutterWidth;

  const _SourceLine({
    required this.number,
    required this.text,
    required this.correlated,
    required this.gutterWidth,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: correlated ? scheme.primaryContainer : null,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: gutterWidth,
            child: Text(
              '$number',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              text.isEmpty ? ' ' : text,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
