// PT-6.4 stacks, stats, classification probe, profile switcher. The stack
// inventory (`GET /api/memory/stacks`) with per-stack peek (`/stacks/{name}`,
// § 5.5); a point-in-time stats snapshot derived from that inventory (a snapshot,
// not a time series — there is no TSDB); the centroid classification probe
// (`POST /api/memory/classify`, § 5.6); and a *view-only* profile switcher
// (`GET /api/memory/profiles`, § 5.6) — changing the viewed profile never
// switches the brain's profile (there is no write route to do so).

import 'package:flutter/material.dart';

import '../../api/memory_api_client.dart';
import '../../model/memory_nodes.dart';
import 'memory_status.dart';
import 'node_link_chip.dart';

/// The stacks / stats / classify / profiles page over [client].
///
/// [selectedProfile] is the home-owned viewed profile (the switcher reflects it
/// as selected); [onProfileChanged] raises a new selection so the home re-scopes
/// every tab's reads (§ 5.6). When [onProfileChanged] is omitted the switcher is
/// inert (used by tests that drive the page in isolation).
class StacksStatsView extends StatefulWidget {
  final MemoryApiClient client;
  final String? selectedProfile;
  final ValueChanged<String?>? onProfileChanged;

  const StacksStatsView({
    super.key,
    required this.client,
    this.selectedProfile,
    this.onProfileChanged,
  });

  @override
  State<StacksStatsView> createState() => _StacksStatsViewState();
}

class _StacksStatsViewState extends State<StacksStatsView> {
  late Future<List<MemoryStackSummary>> _stacks;

  @override
  void initState() {
    super.initState();
    _stacks = widget.client.stacks();
  }

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          FutureBuilder<List<MemoryStackSummary>>(
            future: _stacks,
            builder: (context, snapshot) {
              final status = memoryStatus(context, snapshot);
              if (status != null) return SizedBox(height: 160, child: status);
              final stacks = snapshot.data ?? const <MemoryStackSummary>[];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _StatsSnapshot(stacks: stacks),
                  const SizedBox(height: 16),
                  Text('stacks', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  if (stacks.isEmpty)
                    const Text('no stacks')
                  else
                    for (final stack in stacks)
                      _StackTile(client: widget.client, stack: stack),
                ],
              );
            },
          ),
          const Divider(height: 32),
          _ClassifyProbe(client: widget.client),
          const Divider(height: 32),
          _ProfileSwitcher(
            client: widget.client,
            selectedProfile: widget.selectedProfile,
            onProfileChanged: widget.onProfileChanged,
          ),
        ],
      );
}

/// A point-in-time snapshot over the current stack inventory (§ 5.5) — a
/// snapshot, not a series.
class _StatsSnapshot extends StatelessWidget {
  final List<MemoryStackSummary> stacks;
  const _StatsSnapshot({required this.stacks});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totalEntries = stacks.fold<int>(0, (sum, s) => sum + s.size);
    final bootstrap = stacks.where((s) => s.bootstrap).length;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('stats snapshot', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              '${stacks.length} stacks  ·  $totalEntries entries  ·  '
              '$bootstrap bootstrap',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// One stack: its facts, expandable to peek its top entries (§ 5.5).
class _StackTile extends StatelessWidget {
  final MemoryApiClient client;
  final MemoryStackSummary stack;

  const _StackTile({required this.client, required this.stack});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ExpansionTile(
        key: ValueKey<String>('stack:${stack.name}'),
        title: Text(stack.name),
        subtitle: Text(
          '${stack.size} entries  ·  top ${stack.topPriority.toStringAsFixed(2)}'
          '${stack.bootstrap ? "  ·  bootstrap" : ""}',
          style: theme.textTheme.bodySmall,
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: <Widget>[_StackPeek(client: client, name: stack.name)],
      ),
    );
  }
}

/// The lazily-loaded top entries of a stack — each entry's node is a chip.
class _StackPeek extends StatefulWidget {
  final MemoryApiClient client;
  final String name;

  const _StackPeek({required this.client, required this.name});

  @override
  State<_StackPeek> createState() => _StackPeekState();
}

class _StackPeekState extends State<_StackPeek> {
  late final Future<List<MemoryStackEntry>> _entries =
      widget.client.stackPeek(widget.name, k: 10);

  @override
  Widget build(BuildContext context) => FutureBuilder<List<MemoryStackEntry>>(
        future: _entries,
        builder: (context, snapshot) {
          final status = memoryStatus(context, snapshot);
          if (status != null) return SizedBox(height: 80, child: status);
          final entries = snapshot.data ?? const <MemoryStackEntry>[];
          if (entries.isEmpty) return const Text('empty');
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (final entry in entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: <Widget>[
                      NodeLinkChip(client: widget.client, nodeId: entry.nodeId),
                      const SizedBox(width: 8),
                      Text(entry.priority.toStringAsFixed(2),
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
            ],
          );
        },
      );
}

/// The centroid classification probe (§ 5.6): a comma-separated embedding plus a
/// target, run against the live centroids.
class _ClassifyProbe extends StatefulWidget {
  final MemoryApiClient client;
  const _ClassifyProbe({required this.client});

  @override
  State<_ClassifyProbe> createState() => _ClassifyProbeState();
}

class _ClassifyProbeState extends State<_ClassifyProbe> {
  final TextEditingController _embedding = TextEditingController();
  ClassifyTarget _target = ClassifyTarget.nodeType;
  Future<MemoryClassification>? _result;

  @override
  void dispose() {
    _embedding.dispose();
    super.dispose();
  }

  void _run() {
    final vec = <double>[
      for (final part in _embedding.text.split(',')) ?double.tryParse(part.trim()),
    ];
    setState(() {
      _result = widget.client.classify(vec, target: _target);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('classification probe', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        TextField(
          controller: _embedding,
          decoration: const InputDecoration(
            labelText: 'embedding (comma-separated floats)',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            DropdownButton<ClassifyTarget>(
              value: _target,
              items: <DropdownMenuItem<ClassifyTarget>>[
                for (final target in ClassifyTarget.values)
                  DropdownMenuItem<ClassifyTarget>(
                      value: target, child: Text(target.wireName)),
              ],
              onChanged: (target) {
                if (target != null) setState(() => _target = target);
              },
            ),
            const SizedBox(width: 12),
            FilledButton(onPressed: _run, child: const Text('Classify')),
          ],
        ),
        const SizedBox(height: 8),
        if (_result != null)
          FutureBuilder<MemoryClassification>(
            future: _result,
            builder: (context, snapshot) {
              final status = memoryStatus(context, snapshot);
              if (status != null) return SizedBox(height: 60, child: status);
              final c = snapshot.data!;
              return Text(
                '${c.decision}  ·  best ${c.bestMatch ?? "—"} '
                '(${c.bestSimilarity.toStringAsFixed(3)})  ·  '
                'second ${c.secondSimilarity.toStringAsFixed(3)}',
                style: theme.textTheme.bodySmall,
              );
            },
          ),
      ],
    );
  }
}

/// The view-only profile switcher (§ 5.6). Lists the profiles and the brain's
/// current binding; selecting one raises [onProfileChanged] so the home
/// re-scopes every tab's reads to that profile's *view* — it never switches the
/// brain's profile (there is no write route, OBS-2). [selectedProfile] is the
/// home-owned selection the dropdown reflects.
class _ProfileSwitcher extends StatefulWidget {
  final MemoryApiClient client;
  final String? selectedProfile;
  final ValueChanged<String?>? onProfileChanged;

  const _ProfileSwitcher({
    required this.client,
    required this.selectedProfile,
    required this.onProfileChanged,
  });

  @override
  State<_ProfileSwitcher> createState() => _ProfileSwitcherState();
}

class _ProfileSwitcherState extends State<_ProfileSwitcher> {
  late final Future<MemoryProfiles> _profiles = widget.client.profiles();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('profiles (view-only)', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Switching the viewed profile re-reads memory in that profile’s view '
          '— it never switches the brain’s profile.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        FutureBuilder<MemoryProfiles>(
          future: _profiles,
          builder: (context, snapshot) {
            final status = memoryStatus(context, snapshot);
            if (status != null) return SizedBox(height: 60, child: status);
            final profiles = snapshot.data!;
            final selected = widget.selectedProfile ?? profiles.current;
            return Row(
              children: <Widget>[
                DropdownButton<String>(
                  value: profiles.profiles.contains(selected) ? selected : null,
                  hint: const Text('profile'),
                  items: <DropdownMenuItem<String>>[
                    for (final p in profiles.profiles)
                      DropdownMenuItem<String>(value: p, child: Text(p)),
                  ],
                  onChanged: widget.onProfileChanged,
                ),
                const SizedBox(width: 12),
                if (profiles.current != null)
                  Text('brain: ${profiles.current}',
                      style: theme.textTheme.bodySmall),
              ],
            );
          },
        ),
      ],
    );
  }
}
