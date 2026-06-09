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
            return _LlmCallBody(detail: detail);
          },
        ),
      );
}

/// The §4.5 body. Pure (no Future/Navigator) so it is testable directly.
class _LlmCallBody extends StatelessWidget {
  final LlmCallDetail detail;
  const _LlmCallBody({required this.detail});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
