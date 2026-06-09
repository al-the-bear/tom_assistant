// Module 2 entry — the memory-monitoring home (§ 5, PT-6). Three tabs over the
// read-only `/api/memory/*` surface: Browse (node browser + detail + edge
// traversal), Recall (the interactive four-mode console), and Stacks & Stats
// (the inventory, the point-in-time snapshot, the classify probe, the view-only
// profile switcher). Depends only on [MemoryApiClient] so tests drive a stub.

import 'package:flutter/material.dart';

import '../../api/memory_api_client.dart';
import 'node_browser_view.dart';
import 'recall_view.dart';
import 'stacks_stats_view.dart';

/// The tabbed memory-monitoring page over [client].
class MemoryHomeView extends StatelessWidget {
  final MemoryApiClient client;

  const MemoryHomeView({super.key, required this.client});

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 3,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Tom Brain Observatory — Memory'),
            bottom: const TabBar(
              tabs: <Widget>[
                Tab(text: 'Browse'),
                Tab(text: 'Recall'),
                Tab(text: 'Stacks & Stats'),
              ],
            ),
          ),
          body: TabBarView(
            children: <Widget>[
              NodeBrowserView(client: client),
              RecallView(client: client),
              StacksStatsView(client: client),
            ],
          ),
        ),
      );
}
