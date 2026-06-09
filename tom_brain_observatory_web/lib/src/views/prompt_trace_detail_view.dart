// The PromptTrace detail page (§ 4.2). Fetches one trace by turnId from the
// injected [TraceApiClient] and renders the four independently-expandable
// sections — Inbound / Configuration / Reply / Run Tree. PT-2.2 fills the
// Inbound / Configuration / Reply sections + the configuration-in-effect view
// (§ 4.3); PT-2.3 the recursive run-tree; PT-2.4 the LLM-call detail. The body
// is built by [buildTraceSections] so the section composition is testable
// without a Navigator.

import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/memory_api_client.dart';
import '../api/trace_api_client.dart';
import '../model/live_step.dart';
import '../model/prompt_trace.dart';
import 'configuration_in_effect_view.dart';
import 'format.dart';
import 'live_reply_view.dart';
import 'llm_call_detail_view.dart';
import 'memory/node_detail_view.dart';
import 'monospace_block.dart';
import 'outcome_chip.dart';
import 'procedure_script_view.dart';
import 'run_tree_view.dart';

/// The detail page for [turnId], over [client]. [memoryClient] backs the
/// cross-links from run-tree node ids into Module 2's node view (§ 4.7 / PT-7.1).
class PromptTraceDetailView extends StatefulWidget {
  final TraceApiClient client;
  final MemoryApiClient memoryClient;
  final String turnId;

  const PromptTraceDetailView({
    super.key,
    required this.client,
    required this.memoryClient,
    required this.turnId,
  });

  @override
  State<PromptTraceDetailView> createState() => _PromptTraceDetailViewState();
}

class _PromptTraceDetailViewState extends State<PromptTraceDetailView> {
  late Future<PromptTrace?> _trace;

  /// The per-turn SSE live-tail (§ 4.8), created once so the streaming Reply
  /// view subscribes a single time. Cold until listened — a finished turn
  /// (static reply present) never opens it.
  late final Stream<LiveStep> _liveSteps;

  @override
  void initState() {
    super.initState();
    _trace = widget.client.traceFor(widget.turnId);
    _liveSteps = widget.client.tailTurn(widget.turnId);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.turnId)),
        body: FutureBuilder<PromptTrace?>(
          future: _trace,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(child: Text('Failed to load trace: ${snapshot.error}'));
            }
            final trace = snapshot.data;
            if (trace == null) {
              return Center(child: Text('No trace for turn ${widget.turnId}.'));
            }
            return ListView(
              children: buildTraceSections(
                trace,
                onOpenLlmCall: (node) => _openLlmCall(context, node),
                onInspectScript: (run) => _openScript(context, run),
                onOpenNode: (nodeId) => _openNode(context, nodeId),
                liveReply: LiveReplyView(steps: _liveSteps),
              ),
            );
          },
        ),
      );

  void _openLlmCall(BuildContext context, LlmCallNode node) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => LlmCallDetailView(
        client: widget.client,
        turnId: widget.turnId,
        node: node,
      ),
    ));
  }

  void _openScript(BuildContext context, ProcedureRun run) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ProcedureScriptView(client: widget.client, run: run),
    ));
  }

  /// Walks from a run-tree node id into Module 2's node view (§ 4.7 / PT-7.1).
  void _openNode(BuildContext context, String nodeId) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) =>
          NodeDetailView(client: widget.memoryClient, nodeId: nodeId),
    ));
  }
}

/// The four §4.2 sections for [trace], each an independently-expandable tile.
/// Pure (no Navigator/Future) so widget tests exercise it directly.
/// [onOpenLlmCall] is invoked when an LLM-call row in the run tree is opened
/// (§ 4.5 / PT-2.4); [onInspectScript] when a run row's inspect-script action is
/// triggered (§ 4.6 / PT-3.2); [onOpenNode] when a persisted node id in the run
/// tree is tapped, deep-linking into Module 2 (§ 4.7 / PT-7.1). A `null`
/// callback makes the affordance inert.
/// [liveReply] is the streaming Reply view (§ 4.8 / PT-4.2) shown for an
/// in-flight turn (no static reply yet); when `null` an in-flight turn's Reply
/// section is simply empty.
List<Widget> buildTraceSections(
  PromptTrace trace, {
  ValueChanged<LlmCallNode>? onOpenLlmCall,
  ValueChanged<ProcedureRun>? onInspectScript,
  ValueChanged<String>? onOpenNode,
  Widget? liveReply,
}) {
  final inFlight = trace.reply == null;
  final streamReply = inFlight && liveReply != null;
  return <Widget>[
      TraceSection(
        title: 'Inbound',
        present: trace.inbound != null,
        child: _InboundBody(inbound: trace.inbound),
      ),
      TraceSection(
        title: 'Configuration',
        present: trace.configuration.entries.isNotEmpty,
        child: ConfigurationInEffectView(configuration: trace.configuration),
      ),
      TraceSection(
        title: 'Reply',
        present: trace.reply != null || streamReply,
        initiallyExpanded: streamReply,
        child: streamReply ? liveReply : _ReplyBody(reply: trace.reply),
      ),
      TraceSection(
        title: 'Run Tree',
        present: trace.runTree != null,
        initiallyExpanded: true,
        child: trace.runTree == null
            ? const Text('(no run tree)')
            : RunTreeView(
                run: trace.runTree!,
                onOpenLlmCall: onOpenLlmCall,
                onInspectScript: onInspectScript,
                onOpenNode: onOpenNode,
              ),
      ),
    ];
}

/// The Inbound section body (§ 3.3): an envelope header, the full prompt text,
/// and the secret-redacted raw envelope as indented JSON.
class _InboundBody extends StatelessWidget {
  final Inbound? inbound;
  const _InboundBody({required this.inbound});

  @override
  Widget build(BuildContext context) {
    final i = inbound;
    if (i == null) return const Text('(no inbound envelope)');
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          <String>[
            i.channel,
            i.principalId,
            i.persona,
            'session ${i.sessionId}',
            if (i.conversationId != null) 'conv ${i.conversationId}',
            if (i.profile != null) 'profile ${i.profile}',
            formatClock(i.receivedAt),
          ].join('  ·  '),
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        SelectableText(i.text),
        const SizedBox(height: 12),
        Text('raw envelope', style: theme.textTheme.labelMedium),
        const SizedBox(height: 4),
        MonospaceBlock(
          text: const JsonEncoder.withIndent('  ').convert(i.rawEnvelope),
        ),
      ],
    );
  }
}

/// The Reply section body (§ 3.5): the verbatim final answer plus an outcome
/// chip and wall-clock.
class _ReplyBody extends StatelessWidget {
  final Reply? reply;
  const _ReplyBody({required this.reply});

  @override
  Widget build(BuildContext context) {
    final r = reply;
    if (r == null) return const Text('(no reply)');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(children: <Widget>[
          OutcomeChip(status: r.outcomeStatus),
          const SizedBox(width: 8),
          Text(formatWallClock(r.wallClockMs)),
        ]),
        const SizedBox(height: 12),
        SelectableText(r.finalAnswer ?? '(no answer)'),
      ],
    );
  }
}

/// A collapsible section tile. [present] dims+disables the header when the
/// section has no content for this turn (e.g. an in-flight turn has no run
/// tree). Public so it is reusable and testable.
class TraceSection extends StatelessWidget {
  final String title;
  final bool present;
  final bool initiallyExpanded;
  final Widget child;

  const TraceSection({
    super.key,
    required this.title,
    required this.present,
    required this.child,
    this.initiallyExpanded = false,
  });

  @override
  Widget build(BuildContext context) => ExpansionTile(
        title: Text(title),
        enabled: present,
        initiallyExpanded: present && initiallyExpanded,
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: <Widget>[Align(alignment: Alignment.centerLeft, child: child)],
      );
}
