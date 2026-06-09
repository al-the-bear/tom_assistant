// The PromptTrace detail page (§ 4.2). Fetches one trace by turnId from the
// injected [TraceApiClient] and renders the four independently-expandable
// sections — Inbound / Configuration / Reply / Run Tree. PT-2.2 fills the
// Inbound / Configuration / Reply sections + the configuration-in-effect view
// (§ 4.3); PT-2.3 the recursive run-tree; PT-2.4 the LLM-call detail. The body
// is built by [buildTraceSections] so the section composition is testable
// without a Navigator.

import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/trace_api_client.dart';
import '../model/prompt_trace.dart';
import 'configuration_in_effect_view.dart';
import 'format.dart';
import 'llm_call_detail_view.dart';
import 'monospace_block.dart';
import 'outcome_chip.dart';
import 'run_tree_view.dart';

/// The detail page for [turnId], over [client].
class PromptTraceDetailView extends StatefulWidget {
  final TraceApiClient client;
  final String turnId;

  const PromptTraceDetailView({
    super.key,
    required this.client,
    required this.turnId,
  });

  @override
  State<PromptTraceDetailView> createState() => _PromptTraceDetailViewState();
}

class _PromptTraceDetailViewState extends State<PromptTraceDetailView> {
  late Future<PromptTrace?> _trace;

  @override
  void initState() {
    super.initState();
    _trace = widget.client.traceFor(widget.turnId);
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
}

/// The four §4.2 sections for [trace], each an independently-expandable tile.
/// Pure (no Navigator/Future) so widget tests exercise it directly.
/// [onOpenLlmCall] is invoked when an LLM-call row in the run tree is opened
/// (§ 4.5 / PT-2.4); `null` makes those rows inert (used by section tests).
List<Widget> buildTraceSections(
  PromptTrace trace, {
  ValueChanged<LlmCallNode>? onOpenLlmCall,
}) =>
    <Widget>[
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
        present: trace.reply != null,
        child: _ReplyBody(reply: trace.reply),
      ),
      TraceSection(
        title: 'Run Tree',
        present: trace.runTree != null,
        initiallyExpanded: true,
        child: trace.runTree == null
            ? const Text('(no run tree)')
            : RunTreeView(run: trace.runTree!, onOpenLlmCall: onOpenLlmCall),
      ),
    ];

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
