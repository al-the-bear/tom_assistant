// PT-6.3 interactive four-mode recall. Single-seed (`POST /api/memory/recall`)
// and multi-seed (`POST /api/memory/recall/multi`): pick the mode subset
// {bm25, vector, graphWalk, symbolic}, set k, run, and read the fused list back
// with the per-mode cost report (§ 5.4). Every returned node is a [NodeLinkChip]
// that deep-links to its detail; multi-seed also shows per-node seed provenance.

import 'package:flutter/material.dart';

import '../../api/memory_api_client.dart';
import '../../model/memory_nodes.dart';
import 'memory_status.dart';
import 'node_link_chip.dart';

/// The recall console over [client].
class RecallView extends StatefulWidget {
  final MemoryApiClient client;

  const RecallView({super.key, required this.client});

  @override
  State<RecallView> createState() => _RecallViewState();
}

class _RecallViewState extends State<RecallView> {
  bool _multi = false;
  final TextEditingController _text = TextEditingController();
  final TextEditingController _k = TextEditingController(text: '10');
  final Set<RecallMode> _modes = <RecallMode>{RecallMode.bm25, RecallMode.vector};
  final List<_SeedDraft> _seeds = <_SeedDraft>[_SeedDraft()];
  Future<RecallResult>? _result;

  @override
  void dispose() {
    _text.dispose();
    _k.dispose();
    for (final seed in _seeds) {
      seed.dispose();
    }
    super.dispose();
  }

  int? get _kValue => int.tryParse(_k.text.trim());

  void _run() {
    setState(() {
      if (_multi) {
        _result = widget.client.recallMulti(
          seeds: <RecallSeedSpec>[
            for (final draft in _seeds)
              RecallSeedSpec(
                mode: draft.mode,
                text: draft.text.text.trim().isEmpty ? null : draft.text.text.trim(),
                weight: double.tryParse(draft.weight.text.trim()) ?? 1.0,
              ),
          ],
          k: _kValue,
        );
      } else {
        _result = widget.client.recall(
          text: _text.text.trim().isEmpty ? null : _text.text.trim(),
          modes: _modes.isEmpty ? null : _modes,
          k: _kValue,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SegmentedButton<bool>(
              segments: const <ButtonSegment<bool>>[
                ButtonSegment<bool>(value: false, label: Text('single seed')),
                ButtonSegment<bool>(value: true, label: Text('multi seed')),
              ],
              selected: <bool>{_multi},
              onSelectionChanged: (s) => setState(() => _multi = s.first),
            ),
            const SizedBox(height: 12),
            if (_multi) _multiSeedForm() else _singleSeedForm(),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                SizedBox(
                  width: 96,
                  child: TextField(
                    controller: _k,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'k',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: _run,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Recall'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(child: _results()),
          ],
        ),
      );

  Widget _singleSeedForm() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            controller: _text,
            decoration: const InputDecoration(
              labelText: 'query text',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: <Widget>[
              for (final mode in RecallMode.values)
                FilterChip(
                  label: Text(mode.wireName),
                  selected: _modes.contains(mode),
                  onSelected: (on) => setState(() {
                    if (on) {
                      _modes.add(mode);
                    } else {
                      _modes.remove(mode);
                    }
                  }),
                ),
            ],
          ),
        ],
      );

  Widget _multiSeedForm() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (var i = 0; i < _seeds.length; i++)
            _SeedRow(
              draft: _seeds[i],
              onChanged: () => setState(() {}),
              onRemove: _seeds.length == 1
                  ? null
                  : () => setState(() => _seeds.removeAt(i).dispose()),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _seeds.add(_SeedDraft())),
              icon: const Icon(Icons.add),
              label: const Text('Add seed'),
            ),
          ),
        ],
      );

  Widget _results() {
    final result = _result;
    if (result == null) {
      return const Center(child: Text('Configure a recall and run it.'));
    }
    return FutureBuilder<RecallResult>(
      future: result,
      builder: (context, snapshot) {
        final status = memoryStatus(context, snapshot);
        if (status != null) return status;
        return _RecallResults(client: widget.client, result: snapshot.data!);
      },
    );
  }
}

/// The mutable state of one multi-seed row.
class _SeedDraft {
  RecallMode mode = RecallMode.bm25;
  final TextEditingController text = TextEditingController();
  final TextEditingController weight = TextEditingController(text: '1.0');

  void dispose() {
    text.dispose();
    weight.dispose();
  }
}

/// One editable seed (mode + text + weight) in the multi-seed form.
class _SeedRow extends StatelessWidget {
  final _SeedDraft draft;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;

  const _SeedRow({
    required this.draft,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: <Widget>[
            DropdownButton<RecallMode>(
              value: draft.mode,
              items: <DropdownMenuItem<RecallMode>>[
                for (final mode in RecallMode.values)
                  DropdownMenuItem<RecallMode>(
                      value: mode, child: Text(mode.wireName)),
              ],
              onChanged: (mode) {
                if (mode != null) {
                  draft.mode = mode;
                  onChanged();
                }
              },
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: draft.text,
                decoration: const InputDecoration(
                  labelText: 'seed text',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 80,
              child: TextField(
                controller: draft.weight,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'weight',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            IconButton(
              onPressed: onRemove,
              icon: const Icon(Icons.remove_circle_outline),
            ),
          ],
        ),
      );
}

/// The fused node list, the cost report, and (multi-seed) provenance (§ 5.4).
class _RecallResults extends StatelessWidget {
  final MemoryApiClient client;
  final RecallResult result;

  const _RecallResults({required this.client, required this.result});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final report = result.report;
    final provenanceById = <String, RecallProvenance>{
      for (final p in result.provenance ?? const <RecallProvenance>[])
        p.nodeId: p,
    };
    return ListView(
      children: <Widget>[
        _ReportCard(report: report),
        const SizedBox(height: 12),
        if (result.nodes.isEmpty)
          Text('no results', style: theme.textTheme.bodySmall)
        else
          for (final node in result.nodes)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: <Widget>[
                  NodeLinkChip(
                    client: client,
                    nodeId: node.id,
                    typeName: node.typeName,
                  ),
                  if (provenanceById[node.id] case final prov?) ...<Widget>[
                    const SizedBox(width: 8),
                    Text(
                      'seeds ${prov.seedIndexes.join(",")}  ·  '
                      '${prov.fusedScore.toStringAsFixed(3)}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ],
              ),
            ),
      ],
    );
  }
}

/// The per-mode cost report of a recall (§ 5.4).
class _ReportCard extends StatelessWidget {
  final RecallReport report;
  const _ReportCard({required this.report});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final perMode = report.candidatesPerMode.entries
        .map((e) => '${e.key}:${e.value}')
        .join('  ');
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('cost report', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'fusion ${report.fusionStrategy}  ·  diversity '
              '${report.diversityStrategy}'
              '${report.diversityLambda == null ? "" : " (λ ${report.diversityLambda})"}',
              style: theme.textTheme.bodySmall,
            ),
            Text(
              '${report.elapsedMs}ms  ·  embeddings ${report.embeddingsCallouts}'
              '  ·  re-rank ${report.reRankInvoked ? "yes" : "no"}'
              '${report.degraded ? "  ·  DEGRADED" : ""}',
              style: theme.textTheme.bodySmall,
            ),
            if (perMode.isNotEmpty)
              Text('candidates  $perMode', style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
