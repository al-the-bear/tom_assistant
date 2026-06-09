// PT-6.1 node browser. Browse by `typeName` across the closed vocabulary (§ 5.2)
// — pick a type, run the composed browse (`GET /api/memory/nodes?type=`), and
// list the returned nodes as [NodeLinkChip]s. The result is never exhaustive
// (the read surface samples), so the count and the contributing `sources` are
// shown plainly rather than implying a full enumeration.

import 'package:flutter/material.dart';

import '../../api/memory_api_client.dart';
import '../../model/memory_nodes.dart';
import 'memory_status.dart';
import 'node_link_chip.dart';

/// The closed node-type vocabulary (§ 5.2). Browsing is constrained to these.
const List<String> memoryNodeTypes = <String>[
  'Event',
  'Claim',
  'Concept',
  'Conclusion',
  'Question',
  'Pattern',
  'Contradiction',
  'Source',
  'Plan',
  'PlanStep',
  'Artifact',
  'Procedure',
  'ProcedureRun',
  'AutomationIdea',
  'InterestItem',
  'Session',
  'Trail',
  'Stack',
  'StackEntry',
  'Tombstone',
];

/// The browse-by-type page over [client].
class NodeBrowserView extends StatefulWidget {
  final MemoryApiClient client;

  const NodeBrowserView({super.key, required this.client});

  @override
  State<NodeBrowserView> createState() => _NodeBrowserViewState();
}

class _NodeBrowserViewState extends State<NodeBrowserView> {
  String _type = memoryNodeTypes.first;
  Future<TypeBrowseResult>? _result;

  void _browse() {
    setState(() {
      _result = widget.client.browseNodes(_type);
    });
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _type,
                    decoration: const InputDecoration(
                      labelText: 'node type',
                      border: OutlineInputBorder(),
                    ),
                    items: <DropdownMenuItem<String>>[
                      for (final type in memoryNodeTypes)
                        DropdownMenuItem<String>(value: type, child: Text(type)),
                    ],
                    onChanged: (value) {
                      if (value != null) setState(() => _type = value);
                    },
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: _browse,
                  icon: const Icon(Icons.search),
                  label: const Text('Browse'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(child: _results()),
          ],
        ),
      );

  Widget _results() {
    final result = _result;
    if (result == null) {
      return const Center(child: Text('Pick a type and browse.'));
    }
    return FutureBuilder<TypeBrowseResult>(
      future: result,
      builder: (context, snapshot) {
        final status = memoryStatus(context, snapshot);
        if (status != null) return status;
        final browse = snapshot.data!;
        return _BrowseResults(client: widget.client, browse: browse);
      },
    );
  }
}

/// The non-exhaustive header (count + sources) plus the node chips.
class _BrowseResults extends StatelessWidget {
  final MemoryApiClient client;
  final TypeBrowseResult browse;

  const _BrowseResults({required this.client, required this.browse});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sources =
        browse.sources.isEmpty ? '—' : browse.sources.join(', ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '${browse.nodes.length} ${browse.typeName} nodes '
          '(sample, not exhaustive)  ·  sources: $sources',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        if (browse.nodes.isEmpty)
          Text('no nodes', style: theme.textTheme.bodySmall)
        else
          Expanded(
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final node in browse.nodes)
                    NodeLinkChip(
                      client: client,
                      nodeId: node.id,
                      typeName: node.typeName,
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
