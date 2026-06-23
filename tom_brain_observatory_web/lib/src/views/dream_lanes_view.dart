// Module 3 — the dreaming-cycle monitor (`prompt_tracing.md` § 5A). The
// dreaming-side mirror of the prompt-tracing entry → detail flow: a lane
// dropdown (§ 5A.2) chooses which cadence lane's processing to inspect, the body
// lists that lane's recent turn-less dream runs newest-first, and selecting a
// run opens its detail — the *same* recursive run-tree (§ 4.4) the prompt trace
// renders, since a dream run is just a turn-less [ProcedureRun] (§ 3.6).
//
// Read-only, like every observatory view: it issues only the three `/api/dream/*`
// GETs (§ 8.3 (14)) through [TraceApiClient]; tests drive a stub. The run-tree's
// node deep-links walk into Module 2 over [MemoryApiClient] (§ 4.7), exactly as
// the prompt-trace detail does. The LLM-call rows are inert in v1 (§ 5A.4): the
// raw-dump endpoint keys on a turnId a dream run does not have.

import 'package:flutter/material.dart';

import '../api/memory_api_client.dart';
import '../api/trace_api_client.dart';
import '../model/dream_run.dart';
import '../model/prompt_trace.dart';
import 'format.dart';
import 'memory/node_detail_view.dart';
import 'outcome_chip.dart';
import 'procedure_script_view.dart';
import 'run_tree_view.dart';

/// The sentinel lane value of the dropdown's "All lanes" entry — no `?lane=`
/// filter, every lane interleaved (§ 5A.2).
const String allDreamLanes = '*';

/// The dreaming-cycle monitor page over [client], with run-tree node deep-links
/// resolved over [memoryClient] (§ 4.7). The home of Module 3.
class DreamLanesView extends StatefulWidget {
  final TraceApiClient client;
  final MemoryApiClient memoryClient;

  const DreamLanesView({
    super.key,
    required this.client,
    required this.memoryClient,
  });

  @override
  State<DreamLanesView> createState() => _DreamLanesViewState();
}

class _DreamLanesViewState extends State<DreamLanesView> {
  late Future<List<DreamLane>> _lanes;
  late Future<List<DreamRunRow>> _runs;

  /// The selected lane id, or [allDreamLanes] for "all lanes" (the default).
  String _selectedLane = allDreamLanes;

  @override
  void initState() {
    super.initState();
    _lanes = widget.client.listDreamLanes();
    _runs = widget.client.listDreamRuns();
  }

  void _selectLane(String lane) {
    setState(() {
      _selectedLane = lane;
      _runs = widget.client.listDreamRuns(
        lane: lane == allDreamLanes ? null : lane,
      );
    });
  }

  void _openRun(String runId) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => DreamRunDetailView(
        client: widget.client,
        memoryClient: widget.memoryClient,
        runId: runId,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Tom Brain Observatory — Dreaming Cycle'),
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: FutureBuilder<List<DreamLane>>(
                future: _lanes,
                builder: (context, snapshot) => DreamLaneDropdown(
                  lanes: snapshot.data ?? const <DreamLane>[],
                  selected: _selectedLane,
                  onChanged: _selectLane,
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: FutureBuilder<List<DreamRunRow>>(
                future: _runs,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return Center(
                        child: Text('Failed to load dream runs: ${snapshot.error}'));
                  }
                  final runs = snapshot.data ?? const <DreamRunRow>[];
                  if (runs.isEmpty) {
                    return const Center(child: Text('No dream runs in this lane.'));
                  }
                  return ListView.separated(
                    itemCount: runs.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) => DreamRunTile(
                      row: runs[i],
                      onTap: () => _openRun(runs[i].runId),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      );
}

/// The lane selector (§ 5A.2): an "All lanes" entry plus one entry per lane,
/// each labelled with its id and recent-run count. Kept public so it is
/// widget-testable in isolation. When [lanes] is empty (unconfigured host) the
/// dropdown still offers "All lanes" so the page never shows a broken control.
class DreamLaneDropdown extends StatelessWidget {
  final List<DreamLane> lanes;
  final String selected;
  final ValueChanged<String> onChanged;

  const DreamLaneDropdown({
    super.key,
    required this.lanes,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Row(
        children: <Widget>[
          const Text('Lane:'),
          const SizedBox(width: 12),
          DropdownButton<String>(
            key: const ValueKey<String>('dream-lane-dropdown'),
            value: selected,
            onChanged: (v) => v == null ? null : onChanged(v),
            items: <DropdownMenuItem<String>>[
              const DropdownMenuItem<String>(
                value: allDreamLanes,
                child: Text('All lanes'),
              ),
              for (final lane in lanes)
                DropdownMenuItem<String>(
                  value: lane.id,
                  child: Text('${lane.id} (${lane.runCount})'),
                ),
            ],
          ),
        ],
      );
}

/// One dream-run row (§ 5A.2) — the dreaming-side mirror of `PromptListTile`.
/// Keyed by runId; shows the agent, lane, recorded time, outcome, elapsed, and
/// the LLM-call + memory-access counts for the whole run-tree.
class DreamRunTile extends StatelessWidget {
  final DreamRunRow row;
  final VoidCallback onTap;

  const DreamRunTile({super.key, required this.row, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      key: ValueKey<String>(row.runId),
      onTap: onTap,
      leading: const Icon(Icons.bedtime),
      title: Text(
        row.procedureId,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        <String>[
          'lane ${row.laneId}',
          formatClock(row.recordedAt),
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
          Text(formatWallClock(row.elapsedMs), style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// One drilled-in dream run (§ 5A.4): fetches the run by [runId] and renders its
/// run-tree with the *same* [RunTreeView] Module 1 uses. The dreaming-side
/// analogue of `PromptTraceDetailView`, minus the Inbound / Configuration /
/// Reply sections a turn-less run has no source for.
class DreamRunDetailView extends StatefulWidget {
  final TraceApiClient client;
  final MemoryApiClient memoryClient;
  final String runId;

  const DreamRunDetailView({
    super.key,
    required this.client,
    required this.memoryClient,
    required this.runId,
  });

  @override
  State<DreamRunDetailView> createState() => _DreamRunDetailViewState();
}

class _DreamRunDetailViewState extends State<DreamRunDetailView> {
  late final Future<DreamRun?> _run = widget.client.dreamRunFor(widget.runId);

  void _openScript(ProcedureRun run) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ProcedureScriptView(client: widget.client, run: run),
    ));
  }

  void _openNode(String nodeId) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) =>
          NodeDetailView(client: widget.memoryClient, nodeId: nodeId),
    ));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.runId)),
        body: FutureBuilder<DreamRun?>(
          future: _run,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(child: Text('Failed to load dream run: ${snapshot.error}'));
            }
            final dream = snapshot.data;
            if (dream == null) {
              return Center(child: Text('No dream run ${widget.runId}.'));
            }
            return ListView(
              children: buildDreamRunSections(
                dream,
                // LLM-call rows are inert in v1 (§ 5A.4): the raw-dump endpoint
                // keys on a turnId a dream run has none of.
                onInspectScript: _openScript,
                onOpenNode: _openNode,
              ),
            );
          },
        ),
      );
}

/// The §5A.4 dream-run sections for [dream]: a one-line header (agent · lane ·
/// status · elapsed) and the run-tree. Pure (no Navigator/Future) so widget
/// tests exercise it directly. [onInspectScript] opens a run's procedure source
/// (§ 4.6); [onOpenNode] deep-links a persisted node id into Module 2 (§ 4.7); a
/// `null` callback makes the affordance inert.
List<Widget> buildDreamRunSections(
  DreamRun dream, {
  ValueChanged<ProcedureRun>? onInspectScript,
  ValueChanged<String>? onOpenNode,
}) {
  final run = dream.run;
  return <Widget>[
    Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: _DreamRunHeader(dream: dream),
    ),
    Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: RunTreeView(
        run: run,
        onOpenLlmCall: null,
        onInspectScript: onInspectScript,
        onOpenNode: onOpenNode,
      ),
    ),
  ];
}

/// The dream-run header line (§ 5A.4): `agent · lane <id> · <status>[ · <elapsed>]`
/// plus an outcome chip.
class _DreamRunHeader extends StatelessWidget {
  final DreamRun dream;
  const _DreamRunHeader({required this.dream});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final run = dream.run;
    return Row(
      children: <Widget>[
        OutcomeChip(status: run.status),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            <String>[
              dream.procedureId,
              'lane ${dream.laneId}',
              if (run.elapsedMs != null) formatWallClock(run.elapsedMs),
            ].join('  ·  '),
            style: theme.textTheme.bodyMedium,
          ),
        ),
      ],
    );
  }
}
