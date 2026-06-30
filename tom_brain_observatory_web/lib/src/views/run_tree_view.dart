// PT-2.3 — the recursive run-tree view (§ 4.4, § 6.1), the centre of Module 1.
// The top-level `ProcedureRun` is the root; every structural node renders by
// kind. The tree is **lazily expanded**: a collapsed run row shows its summary
// without building its children; expanding it builds its immediate children;
// each sub-run recurses to whatever depth the run reached — there is no fixed
// depth limit. Laziness is a real contract (tested), so a collapsed run does
// not build its child widgets — [_RunTile] only constructs them while expanded.
//
// An `LlmCall` is a collapsed one-liner (§ 4.4); tapping it invokes
// [onOpenLlmCall] to open the full LLM-call detail (§ 4.5 / PT-2.4). Every run
// row (the root and each sub-run) carries an "inspect script" action that
// invokes [onInspectScript] to open that run's procedure source (§ 4.6 / PT-3.2).
//
// A primitive that persisted a node (`persist → <id>`) surfaces that node id;
// tapping it invokes [onOpenNode] to deep-link into Module 2's node view
// (§ 4.7 / PT-7.1). A recall surfaces a deep-link chip per returned id; an
// `edge` primitive surfaces a deep-link chip per endpoint (`from` / `to`) — the
// edge id itself is an edge, not a node, so the main row stays inert (§ 3.8 /
// § 3.9). A recall with no resolvable ids, a bare `edge → <id>`, or any other
// bare primitive carries no chip and stays inert.

import 'package:flutter/material.dart';

import '../model/prompt_trace.dart';
import 'collapsed_row.dart';

/// Renders [run] as the recursive run tree. [onOpenLlmCall] opens the detail of
/// a tapped LLM-call row; [onInspectScript] opens the procedure source behind a
/// run row; [onOpenNode] deep-links a persisted node id into Module 2 (§ 4.7).
/// A `null` callback makes the corresponding affordance inert/absent.
class RunTreeView extends StatelessWidget {
  final ProcedureRun run;
  final ValueChanged<LlmCallNode>? onOpenLlmCall;
  final ValueChanged<ProcedureRun>? onInspectScript;
  final ValueChanged<String>? onOpenNode;

  const RunTreeView({
    super.key,
    required this.run,
    this.onOpenLlmCall,
    this.onInspectScript,
    this.onOpenNode,
  });

  @override
  Widget build(BuildContext context) => _RunTile(
        run: run,
        depth: 0,
        onOpenLlmCall: onOpenLlmCall,
        onInspectScript: onInspectScript,
        onOpenNode: onOpenNode,
      );
}

/// A lazily-expanding run row. Collapsed, it shows only its summary; while
/// expanded it builds its immediate child node rows (sub-runs are nested
/// [_RunTile]s — the recursion).
class _RunTile extends StatefulWidget {
  final ProcedureRun run;
  final int depth;
  final ValueChanged<LlmCallNode>? onOpenLlmCall;
  final ValueChanged<ProcedureRun>? onInspectScript;
  final ValueChanged<String>? onOpenNode;

  const _RunTile({
    required this.run,
    required this.depth,
    required this.onOpenLlmCall,
    required this.onInspectScript,
    required this.onOpenNode,
  });

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
            trailing: widget.onInspectScript == null
                ? null
                : IconButton(
                    icon: const Icon(Icons.code, size: 18),
                    tooltip: 'inspect script',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => widget.onInspectScript!(widget.run),
                  ),
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
                      onInspectScript: widget.onInspectScript,
                      onOpenNode: widget.onOpenNode,
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
  final ValueChanged<ProcedureRun>? onInspectScript;
  final ValueChanged<String>? onOpenNode;

  const _RunNodeRow({
    required this.node,
    required this.depth,
    required this.onOpenLlmCall,
    required this.onInspectScript,
    required this.onOpenNode,
  });

  @override
  Widget build(BuildContext context) => switch (node) {
        SubRunNode(:final run) => _RunTile(
            run: run,
            depth: depth,
            onOpenLlmCall: onOpenLlmCall,
            onInspectScript: onInspectScript,
            onOpenNode: onOpenNode,
          ),
        LlmCallNode() => CollapsedRow(
            icon: Icons.smart_toy,
            label: _llmSummary(node as LlmCallNode),
            expandable: true,
            expanded: false,
            onTap: onOpenLlmCall == null
                ? null
                : () => onOpenLlmCall!(node as LlmCallNode),
          ),
        // A persisted node id (`persist → <id>`) deep-links into Module 2
        // (§ 4.7); a recall surfaces a deep-link chip per returned id; a recall
        // with no resolvable ids or a bare primitive carries none, so it stays
        // inert.
        PrimitiveCallNode() => _buildPrimitive(node as PrimitiveCallNode),
        // A `tool.invoke` — a memory or sandbox tool call (§ 4.4). The row shows
        // the tool name, its arg summary, and the outcome (with the result size
        // on success — a size, never the payload). Inert: tool payloads are not
        // recorded in the tree (a denied/failed call surfaces its reason inline).
        ToolCallNode() => CollapsedRow(
            icon: Icons.build,
            label: _toolSummary(node as ToolCallNode),
            expandable: false,
            expanded: false,
            onTap: null,
            emphasis: (node as ToolCallNode).outcome == 'invoked'
                ? CollapsedRowEmphasis.normal
                : CollapsedRowEmphasis.error,
          ),
        NoteNode(:final category, :final detail) => CollapsedRow(
            icon: Icons.sticky_note_2,
            label: detail == null ? 'note $category' : 'note $category — $detail',
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

  /// Renders a `kind: primitive` node. A recall whose descriptor carries
  /// resolvable returned ids, or an `edge` whose descriptor carries its two
  /// endpoints (and an [onOpenNode] seam in either case) shows its summary row
  /// plus a deep-link chip per node id (§ 4.7); otherwise it is a single row
  /// that is tappable only when it carries a persisted `resultId`.
  Widget _buildPrimitive(PrimitiveCallNode node) {
    final recall = node.recall;
    final edge = node.edge;
    final open = onOpenNode;
    if (recall != null && recall.returnedIds.isNotEmpty && open != null) {
      return _primitiveWithChips(node, recall.returnedIds, open);
    }
    // An `edge` write deep-links its two endpoints (`from` / `to`) — both are
    // nodes. The edge's own id (`resultId`) is an edge, not a node, so the
    // summary row stays inert.
    if (edge != null && open != null) {
      return _primitiveWithChips(node, <String>[edge.from, edge.to], open);
    }
    final resultId = node.resultId;
    // A node-producing primitive (e.g. `persist`) whose result id names a node
    // (`n_…`) gets the same deep-link chip the edge endpoints get (§ 4.7), so
    // the persisted node is openable — the gap the user hit. An edge or
    // stack-entry result id (`e_…` / `se_…`) is not a node, so those primitives
    // keep the inert summary row below.
    if (resultId != null && resultId.startsWith('n_') && open != null) {
      return _primitiveWithChips(node, <String>[resultId], open);
    }
    return CollapsedRow(
      icon: Icons.memory,
      label: _primitiveSummary(node),
      expandable: resultId != null && open != null,
      expanded: false,
      onTap: resultId == null || open == null ? null : () => open(resultId),
    );
  }

  /// An inert summary row followed by a deep-link chip per node id in [nodeIds].
  Widget _primitiveWithChips(
    PrimitiveCallNode node,
    List<String> nodeIds,
    ValueChanged<String> open,
  ) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          CollapsedRow(
            icon: Icons.memory,
            label: _primitiveSummary(node),
            expandable: false,
            expanded: false,
            onTap: null,
          ),
          Padding(
            padding: const EdgeInsets.only(left: 24, bottom: 4),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: <Widget>[
                for (final id in nodeIds) _NodeRefChip(nodeId: id, onOpen: open),
              ],
            ),
          ),
        ],
      );

  /// `tool <name>(<args>) → <outcome>` for a tool call; the success result size
  /// (`ok, <n> chars`) or the failure/denial reason is appended (§ 3.9 / § 4.4).
  static String _toolSummary(ToolCallNode n) {
    final base = 'tool ${n.name}(${n.argSummary})';
    return switch (n.outcome) {
      'invoked' => '$base → ok${n.resultChars == null ? '' : ', ${n.resultChars} chars'}',
      'failed' => '$base → failed${n.reason == null ? '' : ': ${n.reason}'}',
      'denied' => '$base → denied${n.reason == null ? '' : ': ${n.reason}'}',
      _ => '$base → ${n.outcome}',
    };
  }

  /// `llm <callType> · <in>→<out> tok` — what the run node carries (§ 3.9). The
  /// provider/model/wall-clock live in the raw dump (PT-2.4), shown on expand.
  static String _llmSummary(LlmCallNode n) =>
      'llm ${n.callType} · ${n.tokensIn}→${n.tokensOut} tok';

  /// `<recall-variant> (<modes> k=<k> → <returned>)` for a recall-family read
  /// (the prefix is the exact primitive — `recall`, `recallOld`, `recallMulti`,
  /// …), `edge <from> -<type>-> <to>` for an edge with endpoints, else
  /// `<primitive>[ → id]`.
  static String _primitiveSummary(PrimitiveCallNode n) {
    final r = n.recall;
    if (r != null) {
      final parts = <String>[
        if (r.modes.isNotEmpty) r.modes.join('+'),
        if (r.k != null) 'k=${r.k}',
      ];
      return '${n.primitive} (${parts.join(' ')} → ${r.returned})';
    }
    final e = n.edge;
    if (e != null) {
      return 'edge ${e.from} -${e.type}-> ${e.to}';
    }
    if (n.detail != null) {
      return '${n.primitive} ${n.detail}';
    }
    return n.resultId == null ? n.primitive : '${n.primitive} → ${n.resultId}';
  }
}

/// A tappable chip naming a recall-returned node id; invokes [onOpen] to walk
/// into Module 2's node view (§ 4.7). Mirrors `NodeLinkChip`'s affordance but
/// routes through the run-tree's decoupled [RunTreeView.onOpenNode] seam rather
/// than holding a `MemoryApiClient`. The `node-link:<id>` key matches
/// `NodeLinkChip` so node references look and test the same everywhere.
class _NodeRefChip extends StatelessWidget {
  final String nodeId;
  final ValueChanged<String> onOpen;

  const _NodeRefChip({required this.nodeId, required this.onOpen});

  @override
  Widget build(BuildContext context) => ActionChip(
        key: ValueKey<String>('node-link:$nodeId'),
        avatar: const Icon(Icons.account_tree, size: 16),
        label: Text(nodeId),
        visualDensity: VisualDensity.compact,
        onPressed: () => onOpen(nodeId),
      );
}
