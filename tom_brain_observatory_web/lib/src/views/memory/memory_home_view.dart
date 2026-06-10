// Module 2 entry — the memory-monitoring home (§ 5, PT-6). Three tabs over the
// read-only `/api/memory/*` surface: Browse (node browser + detail + edge
// traversal), Recall (the interactive four-mode console), and Stacks & Stats
// (the inventory, the point-in-time snapshot, the classify probe, the view-only
// profile switcher). Depends only on [MemoryApiClient] so tests drive a stub.
//
// The home owns the *viewed* profile (the profile switcher, § 5.6). Selecting a
// profile re-wraps [client] in a [ProfileScopedMemoryApiClient] and remounts the
// three tab bodies (keyed on the selection) so every visible read re-issues
// against the named profile — view-scoped, never a brain switch (OBS-2).

import 'package:flutter/material.dart';

import '../../api/memory_api_client.dart';
import 'node_browser_view.dart';
import 'recall_view.dart';
import 'stacks_stats_view.dart';

/// The tabbed memory-monitoring page over [client].
class MemoryHomeView extends StatefulWidget {
  final MemoryApiClient client;

  const MemoryHomeView({super.key, required this.client});

  @override
  State<MemoryHomeView> createState() => _MemoryHomeViewState();
}

class _MemoryHomeViewState extends State<MemoryHomeView> {
  /// The viewed profile, or `null` for the brain's bound profile.
  String? _viewedProfile;

  void _onProfileChanged(String? profile) {
    if (profile == _viewedProfile) return;
    setState(() => _viewedProfile = profile);
  }

  @override
  Widget build(BuildContext context) {
    // View-scope every read of the three tabs to the selected profile (OBS-2).
    // A null selection is a transparent pass-through (the bound profile).
    final scoped = ProfileScopedMemoryApiClient(
      widget.client,
      profile: _viewedProfile,
    );
    // The tab bodies are keyed on the selection so a profile change remounts
    // them and their FutureBuilders re-issue reads against the new view.
    final tag = _viewedProfile ?? '';
    return DefaultTabController(
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
            NodeBrowserView(key: ValueKey<String>('browse:$tag'), client: scoped),
            RecallView(key: ValueKey<String>('recall:$tag'), client: scoped),
            StacksStatsView(
              key: ValueKey<String>('stacks:$tag'),
              client: scoped,
              selectedProfile: _viewedProfile,
              onProfileChanged: _onProfileChanged,
            ),
          ],
        ),
      ),
    );
  }
}
