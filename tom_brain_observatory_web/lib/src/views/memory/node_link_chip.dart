// The one node reference used everywhere a node is named — node detail's edge
// endpoints (§ 5.3), recall results (§ 5.4), and stack entries (§ 5.5). Tapping
// it pushes that node's [NodeDetailView], which is how a viewer "walks hop by
// hop" through the graph. Extracted so every node mention is the same affordance
// (Phase 6 review gate).

import 'package:flutter/material.dart';

import '../../api/memory_api_client.dart';
import 'node_detail_view.dart';

/// A tappable chip naming the node [nodeId]; opens its detail over [client]. An
/// optional [typeName] is shown as a prefix (`Question · n42`).
class NodeLinkChip extends StatelessWidget {
  final MemoryApiClient client;
  final String nodeId;
  final String? typeName;

  const NodeLinkChip({
    super.key,
    required this.client,
    required this.nodeId,
    this.typeName,
  });

  @override
  Widget build(BuildContext context) => ActionChip(
        key: ValueKey<String>('node-link:$nodeId'),
        avatar: const Icon(Icons.account_tree, size: 16),
        label: Text(typeName == null ? nodeId : '$typeName · $nodeId'),
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => NodeDetailView(client: client, nodeId: nodeId),
          ),
        ),
      );
}
