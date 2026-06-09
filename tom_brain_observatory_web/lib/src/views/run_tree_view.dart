// PT-2.3 — the recursive run-tree view (§ 4.4, § 6.1), the centre of Module 1.
// The top-level `ProcedureRun` is the root; every structural node renders by
// kind. The tree is **lazily expanded**: a collapsed run row shows its summary
// without building its children; expanding it builds its immediate children;
// each sub-run recurses to whatever depth the run reached — there is no fixed
// depth limit. Laziness is a real contract (tested), so a collapsed run does
// not build its child widgets — [_RunTile] only constructs them while expanded.
//
// An `LlmCall` is a collapsed one-liner (§ 4.4); tapping it invokes
// [onOpenLlmCall] to open the full LLM-call detail (§ 4.5 / PT-2.4).

import 'package:flutter/material.dart';

import '../model/prompt_trace.dart';
import 'collapsed_row.dart';

/// Renders [run] as the recursive run tree. [onOpenLlmCall] opens the detail of
/// a tapped LLM-call row; `null` makes LLM rows inert.
class RunTreeView extends StatelessWidget {
  final ProcedureRun run;
  final ValueChanged<LlmCallNode>? onOpenLlmCall;

  const RunTreeView({super.key, required this.run, this.onOpenLlmCall});

  @override
  Widget build(BuildContext context) =>
      _RunTile(run: run, depth: 0, onOpenLlmCall: onOpenLlmCall);
}

/// A lazily-expanding run row. Collapsed, it shows only its summary; while
/// expanded it builds its immediate child node rows (sub-runs are nested
/// [_RunTile]s — the recursion).
class _RunTile extends StatefulWidget {
  final ProcedureRun run;
  final int depth;
  final ValueChanged<LlmCallNode>? onOpenLlmCall;

  const _RunTile({required this.run, required this.depth, required this.onOpenLlmCall});

  @override
  State<_RunTile> createState() => _RunTileState();
}

class _RunTileState extends State<_RunTile> {
  bool _expanded = false;

  /// `procedureId · status · {n} steps[ · elapsedMs]` — the run summary.
  String get _summary {
    final run = widget.run;
    return <String>[
      run.procedureId,
      run.status,
      '${run.nodes.length} steps',
      if (run.elapsedMs != null) '${run.elapsedMs}ms',
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          CollapsedRow(
            key: ValueKey<String>('run:${widget.run.runId}'),
            icon: Icons.account_tree,
            label: _summary,
            expandable: widget.run.nodes.isNotEmpty,
            expanded: _expanded,
            onTap: widget.run.nodes.isEmpty
                ? null
                : () => setState(() => _expanded = !_expanded),
          ),
          // Lazy: child rows are built only while expanded.
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (final node in widget.run.nodes)
                    _RunNodeRow(
                      node: node,
                      depth: widget.depth + 1,
                      onOpenLlmCall: widget.onOpenLlmCall,
                    ),
                ],
              ),
            ),
        ],
      );
}

/// Renders one [RunNode] by kind (§ 4.4). A sub-run defers to a nested
/// [_RunTile] (the recursion); leaf kinds are single rows.
class _RunNodeRow extends StatelessWidget {
  final RunNode node;
  final int depth;
  final ValueChanged<LlmCallNode>? onOpenLlmCall;

  const _RunNodeRow({
    required this.node,
    required this.depth,
    required this.onOpenLlmCall,
  });

  @override
  Widget build(BuildContext context) => switch (node) {
        SubRunNode(:final run) =>
          _RunTile(run: run, depth: depth, onOpenLlmCall: onOpenLlmCall),
        LlmCallNode() => CollapsedRow(
            icon: Icons.smart_toy,
            label: _llmSummary(node as LlmCallNode),
            expandable: true,
            expanded: false,
            onTap: onOpenLlmCall == null
                ? null
                : () => onOpenLlmCall!(node as LlmCallNode),
          ),
        PrimitiveCallNode() => CollapsedRow(
            icon: Icons.memory,
            label: _primitiveSummary(node as PrimitiveCallNode),
            expandable: false,
            expanded: false,
            onTap: null,
          ),
        NoteNode(:final category) => CollapsedRow(
            icon: Icons.sticky_note_2,
            label: 'note $category',
            expandable: false,
            expanded: false,
            onTap: null,
          ),
        ErrorNode(:final errorKind, :final message) => CollapsedRow(
            icon: Icons.error_outline,
            label: 'error $errorKind: $message',
            expandable: false,
            expanded: false,
            onTap: null,
            emphasis: CollapsedRowEmphasis.error,
          ),
      };

  /// `llm <callType> · <in>→<out> tok` — what the run node carries (§ 3.9). The
  /// provider/model/wall-clock live in the raw dump (PT-2.4), shown on expand.
  static String _llmSummary(LlmCallNode n) =>
      'llm ${n.callType} · ${n.tokensIn}→${n.tokensOut} tok';

  /// `recall (<modes> k=<k> → <returned>)` for a recall, else `<primitive>[ → id]`.
  static String _primitiveSummary(PrimitiveCallNode n) {
    final r = n.recall;
    if (r != null) {
      final k = r.k == null ? '' : ' k=${r.k}';
      return 'recall (${r.modes}$k → ${r.returned})';
    }
    return n.resultId == null ? n.primitive : '${n.primitive} → ${n.resultId}';
  }
}
