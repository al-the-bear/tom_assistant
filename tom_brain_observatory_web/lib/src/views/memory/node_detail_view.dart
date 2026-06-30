// PT-6.1 node detail + PT-6.2 edge traversal. Shows a node's id / typeName /
// status / createdAt / values (§ 5.2), with the embedding rendered as
// dimensionality + L2 norm and only expanded to the raw vector on demand (never
// the 768 floats by default). Below it, the node's incident edges (§ 5.3): each
// endpoint is a [NodeLinkChip], so tapping one walks to the next node — the
// hop-by-hop traversal of § 5.3.

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../api/memory_api_client.dart';
import '../../model/memory_nodes.dart';
import '../monospace_block.dart';
import 'memory_status.dart';
import 'node_link_chip.dart';

/// The detail page for the node [nodeId], read over [client].
class NodeDetailView extends StatefulWidget {
  final MemoryApiClient client;
  final String nodeId;

  const NodeDetailView({super.key, required this.client, required this.nodeId});

  @override
  State<NodeDetailView> createState() => _NodeDetailViewState();
}

class _NodeDetailViewState extends State<NodeDetailView> {
  late final Future<MemoryNode?> _node = widget.client.node(widget.nodeId);

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('Node ${widget.nodeId}')),
        body: FutureBuilder<MemoryNode?>(
          future: _node,
          builder: (context, snapshot) {
            final status = memoryStatus(context, snapshot);
            if (status != null) return status;
            final node = snapshot.data;
            if (node == null) {
              return Center(child: Text('No node ${widget.nodeId}.'));
            }
            return ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                _NodeFacts(node: node),
                const SizedBox(height: 16),
                _EmbeddingTile(node: node),
                const SizedBox(height: 24),
                _EdgesSection(client: widget.client, nodeId: widget.nodeId),
              ],
            );
          },
        ),
      );
}

/// The scalar facts of a node plus its `values` map as pretty JSON (§ 5.2).
class _NodeFacts extends StatelessWidget {
  final MemoryNode node;
  const _NodeFacts({required this.node});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(node.typeName, style: theme.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          'id ${node.id}  ·  ${node.status}  ·  ${node.createdAt}',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Text('values', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        MonospaceBlock(
          text: const JsonEncoder.withIndent('  ').convert(node.values),
          maxHeight: 320,
        ),
      ],
    );
  }
}

/// The embedding rendered as dimensionality + norm, expandable to the raw vector
/// (§ 5.2: never the raw floats by default). Absent embedding → a quiet note.
class _EmbeddingTile extends StatelessWidget {
  final MemoryNode node;
  const _EmbeddingTile({required this.node});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dim = node.embeddingDimension;
    if (dim == null) {
      return Text(
        'no embedding',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );
    }
    final norm = node.embeddingNorm ?? 0.0;
    return Card(
      margin: EdgeInsets.zero,
      child: ExpansionTile(
        key: const ValueKey<String>('embedding-tile'),
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        leading: const Icon(Icons.scatter_plot),
        title: const Text('embedding'),
        subtitle: Text('$dim dims  ·  norm ${norm.toStringAsFixed(3)}'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: <Widget>[
          MonospaceBlock(
            text: (node.embedding ?? const <double>[]).join(', '),
            maxHeight: 200,
          ),
        ],
      ),
    );
  }
}

/// The node's incident edges (§ 5.3), with a direction filter and each endpoint
/// rendered as a [NodeLinkChip] for hop-by-hop walking. Owns its own fetch so a
/// failed *node* load never orphans an edges request.
class _EdgesSection extends StatefulWidget {
  final MemoryApiClient client;
  final String nodeId;

  const _EdgesSection({required this.client, required this.nodeId});

  @override
  State<_EdgesSection> createState() => _EdgesSectionState();
}

class _EdgesSectionState extends State<_EdgesSection> {
  EdgeDirection _direction = EdgeDirection.both;
  late Future<List<MemoryEdge>> _edges = _fetch();

  Future<List<MemoryEdge>> _fetch() =>
      widget.client.edges(widget.nodeId, direction: _direction);

  void _setDirection(EdgeDirection direction) {
    setState(() {
      _direction = direction;
      _edges = _fetch();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Text('edges', style: theme.textTheme.titleSmall),
            SegmentedButton<EdgeDirection>(
              segments: const <ButtonSegment<EdgeDirection>>[
                ButtonSegment<EdgeDirection>(
                    value: EdgeDirection.both, label: Text('both')),
                ButtonSegment<EdgeDirection>(
                    value: EdgeDirection.outgoing, label: Text('out')),
                ButtonSegment<EdgeDirection>(
                    value: EdgeDirection.incoming, label: Text('in')),
              ],
              selected: <EdgeDirection>{_direction},
              onSelectionChanged: (s) => _setDirection(s.first),
            ),
          ],
        ),
        const SizedBox(height: 8),
        FutureBuilder<List<MemoryEdge>>(
          future: _edges,
          builder: (context, snapshot) {
            final status = memoryStatus(context, snapshot);
            if (status != null) {
              return SizedBox(height: 120, child: status);
            }
            final list = snapshot.data ?? const <MemoryEdge>[];
            if (list.isEmpty) {
              return Text(
                'no edges',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              );
            }
            return Column(
              children: <Widget>[
                for (final edge in list)
                  _EdgeRow(
                      client: widget.client, edge: edge, here: widget.nodeId),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// One edge: the `from` and `to` endpoints as chips around its type + weight.
/// The endpoint equal to the current node carries the "you are here" target
/// marker but stays tappable, so every node on the page is inspectable.
class _EdgeRow extends StatelessWidget {
  final MemoryApiClient client;
  final MemoryEdge edge;
  final String here;

  const _EdgeRow({required this.client, required this.edge, required this.here});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 4,
        children: <Widget>[
          _endpoint(edge.from),
          Text('—${edge.type} (${edge.weight.toStringAsFixed(2)})→',
              style: theme.textTheme.bodySmall),
          _endpoint(edge.to),
        ],
      ),
    );
  }

  Widget _endpoint(String id) =>
      NodeLinkChip(client: client, nodeId: id, isCurrent: id == here);
}
