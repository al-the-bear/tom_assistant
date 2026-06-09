// PT-2.1 — the prompt list (the entry view, § 4.1). Renders `GET /api/traces`
// rows newest-first, one row each: time, channel, principal, persona, a
// one-line preview, the outcome chip, wall-clock, and the LLM-call +
// memory-access counts for the whole turn. Selecting a row opens its
// PromptTrace detail (§ 4.2 / PT-2.2). The view depends only on [TraceApiClient]
// so tests drive a stub (no live brain).

import 'dart:async';

import 'package:flutter/material.dart';

import '../api/trace_api_client.dart';
import '../model/prompt_trace.dart';
import 'format.dart';
import 'outcome_chip.dart';
import 'prompt_trace_detail_view.dart';

/// The prompt-list page over [client].
class PromptListView extends StatefulWidget {
  final TraceApiClient client;

  const PromptListView({super.key, required this.client});

  @override
  State<PromptListView> createState() => _PromptListViewState();
}

class _PromptListViewState extends State<PromptListView> {
  late Future<List<PromptListRow>> _rows;
  StreamSubscription<void>? _changes;

  @override
  void initState() {
    super.initState();
    _rows = widget.client.listTraces();
    // The list-level live-tail (§ 4.8): re-fetch whenever a session live-trail
    // changes, so newly-arrived prompts appear without a manual refresh.
    _changes = widget.client.listChanges().listen((_) {
      if (!mounted) return;
      setState(() {
        _rows = widget.client.listTraces();
      });
    });
  }

  @override
  void dispose() {
    _changes?.cancel();
    super.dispose();
  }

  void _openDetail(String turnId) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PromptTraceDetailView(client: widget.client, turnId: turnId),
    ));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Tom Brain Observatory — Prompt Tracing')),
        body: FutureBuilder<List<PromptListRow>>(
          future: _rows,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(child: Text('Failed to load traces: ${snapshot.error}'));
            }
            final rows = snapshot.data ?? const <PromptListRow>[];
            if (rows.isEmpty) {
              return const Center(child: Text('No prompts traced yet.'));
            }
            return ListView.separated(
              itemCount: rows.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) => PromptListTile(
                row: rows[i],
                onTap: () => _openDetail(rows[i].turnId),
              ),
            );
          },
        ),
      );
}

/// One §4.1 row. Kept public so it can be widget-tested in isolation.
class PromptListTile extends StatelessWidget {
  final PromptListRow row;
  final VoidCallback onTap;

  const PromptListTile({super.key, required this.row, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      key: ValueKey<String>(row.turnId),
      onTap: onTap,
      leading: _ChannelBadge(channel: row.channel),
      title: Text(
        row.preview ?? '(no preview)',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        <String>[
          formatClock(row.receivedAt),
          if (row.principalId != null) row.principalId!,
          if (row.persona != null) row.persona!,
          'llm ${row.llmCallCount} · mem ${row.memoryAccessCount}',
        ].join('  ·  '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          OutcomeChip(status: row.outcomeStatus),
          const SizedBox(height: 4),
          Text(formatWallClock(row.wallClockMs), style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// A small channel label (e.g. `openai`, `telegram`). Absent channel → `?`.
class _ChannelBadge extends StatelessWidget {
  final String? channel;
  const _ChannelBadge({required this.channel});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CircleAvatar(
      radius: 18,
      backgroundColor: theme.colorScheme.secondaryContainer,
      child: Text(
        (channel ?? '?').characters.take(2).toString(),
        style: theme.textTheme.labelSmall
            ?.copyWith(color: theme.colorScheme.onSecondaryContainer),
      ),
    );
  }
}
