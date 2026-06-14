// PT-2.4 — the LLM-call detail page (§ 4.5). Opened from a run-tree `LlmCall`
// one-liner, it fetches the verbatim §3.7 raw dump behind the node's [rawPath]
// (via `GET /api/llm`, the [TraceApiClient.llmCallDetail] surface) and renders
// the full detail: provider·model·profile·callType, the anchor + prompt hashes
// **verbatim** (so two identical scaffolds are visibly identical, § 4.5),
// tokens in/out, retries, wall-clock, the scrollable/copyable wire body, and
// the returned answer.

import 'package:flutter/material.dart';

import '../api/trace_api_client.dart';
import '../model/llm_call_detail.dart';
import '../model/prompt_trace.dart';
import 'format.dart';
import 'monospace_block.dart';
import 'prompt_file_editor_view.dart';

/// The detail page for one run-tree LLM call ([node]) within [turnId], over
/// [client]. Fetches the §3.7 dump lazily on open.
class LlmCallDetailView extends StatefulWidget {
  final TraceApiClient client;
  final String turnId;
  final LlmCallNode node;

  const LlmCallDetailView({
    super.key,
    required this.client,
    required this.turnId,
    required this.node,
  });

  @override
  State<LlmCallDetailView> createState() => _LlmCallDetailViewState();
}

class _LlmCallDetailViewState extends State<LlmCallDetailView> {
  late Future<LlmCallDetail?> _detail;

  @override
  void initState() {
    super.initState();
    _detail = widget.client.llmCallDetail(widget.turnId, widget.node.rawPath);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('llm · ${widget.node.callType}')),
        body: FutureBuilder<LlmCallDetail?>(
          future: _detail,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(child: Text('Failed to load LLM call: ${snapshot.error}'));
            }
            final detail = snapshot.data;
            if (detail == null) {
              return const Center(child: Text('No raw dump for this LLM call.'));
            }
            return _LlmCallBody(
              detail: detail,
              onEditPrompt: (roleId, part) =>
                  _openPromptEditor(context, roleId, part),
            );
          },
        ),
      );

  /// Opens a role's persona/objective override in the editable prompt-file view
  /// (§ 6.3); the affordance is only offered when the call carries a [roleId].
  void _openPromptEditor(BuildContext context, String roleId, String part) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PromptFileEditorView(
        client: widget.client,
        roleId: roleId,
        part: part,
      ),
    ));
  }
}

/// The §4.5 body. Pure (no Future) so it is testable directly. [onEditPrompt] is
/// invoked with `(roleId, part)` when a role's "edit prompt files" affordance is
/// triggered (§ 6.3); it is offered only when the call carries a role.
class _LlmCallBody extends StatelessWidget {
  final LlmCallDetail detail;
  final void Function(String roleId, String part)? onEditPrompt;

  const _LlmCallBody({required this.detail, this.onEditPrompt});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final roleId = detail.roleId;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        // provider·model·profile·callType — what actually ran (§ 4.3 / § 4.5).
        Text(
          <String>[
            detail.provider ?? '(provider?)',
            detail.model ?? '(model?)',
            if (detail.profile != null) detail.profile!,
            detail.callType,
          ].join('  ·  '),
          style: theme.textTheme.titleMedium,
        ),
        if (roleId != null && onEditPrompt != null) ...<Widget>[
          const SizedBox(height: 8),
          _EditPromptBar(
            roleId: roleId,
            onEditPrompt: onEditPrompt!,
          ),
        ],
        const SizedBox(height: 16),
        _MetricsWrap(detail: detail),
        const SizedBox(height: 16),
        // Hashes verbatim — identical scaffolds are visibly identical (§ 4.5).
        _HashLine(label: 'anchor', hash: detail.anchorHash),
        _HashLine(label: 'prompt', hash: detail.promptHash),
        const SizedBox(height: 16),
        Text('wire', style: theme.textTheme.labelLarge),
        const SizedBox(height: 4),
        MonospaceBlock(text: detail.wirePretty, maxHeight: 360),
        const SizedBox(height: 16),
        Text('answer', style: theme.textTheme.labelLarge),
        const SizedBox(height: 4),
        SelectableText(detail.answer ?? '(no answer captured)'),
      ],
    );
  }
}

/// The role's "edit prompt files" affordance (§ 6.3): a labelled pair of
/// buttons opening this call's [roleId] persona / objective override in the
/// editable prompt-file view. Shown only when the call carries a role.
class _EditPromptBar extends StatelessWidget {
  final String roleId;
  final void Function(String roleId, String part) onEditPrompt;

  const _EditPromptBar({required this.roleId, required this.onEditPrompt});

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          Text('role $roleId', style: Theme.of(context).textTheme.bodySmall),
          for (final part in const <String>['persona', 'objective'])
            OutlinedButton.icon(
              icon: const Icon(Icons.edit, size: 16),
              label: Text('edit $part'),
              onPressed: () => onEditPrompt(roleId, part),
            ),
        ],
      );
}

/// tokens in/out · retries · wall-clock — the §4.5 metrics row.
class _MetricsWrap extends StatelessWidget {
  final LlmCallDetail detail;
  const _MetricsWrap({required this.detail});

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          _MetricChip(label: 'in', value: '${detail.tokensIn ?? '—'} tok'),
          _MetricChip(label: 'out', value: '${detail.tokensOut ?? '—'} tok'),
          _MetricChip(label: 'retries', value: '${detail.retries ?? 0}'),
          _MetricChip(label: 'wall', value: formatWallClock(detail.wallClockMs)),
        ],
      );
}

class _MetricChip extends StatelessWidget {
  final String label;
  final String value;
  const _MetricChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) =>
      Chip(label: Text('$label $value'), visualDensity: VisualDensity.compact);
}

/// One verbatim hash line: `<label> <hash>` in monospace, selectable.
class _HashLine extends StatelessWidget {
  final String label;
  final String? hash;
  const _HashLine({required this.label, required this.hash});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: SelectableText(
          '$label  ${hash ?? '(absent)'}',
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      );
}
