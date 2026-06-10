// PT-6.1..6.4 (widget) — the Module-2 memory views over a stubbed
// [MemoryApiClient] (no live brain). Covers: the shared node-link chip pushing
// node detail; node detail's collapsible embedding (dim + norm by default, raw
// vector only on expand) and edge endpoints as chips; the browser's
// non-exhaustive header; single- and multi-seed recall with the cost report and
// provenance; stacks + stats + classify; and the deferred-connector banner.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_brain_observatory_web/src/model/memory_nodes.dart';
import 'package:tom_brain_observatory_web/src/views/memory/memory_status.dart';
import 'package:tom_brain_observatory_web/src/views/memory/node_browser_view.dart';
import 'package:tom_brain_observatory_web/src/views/memory/node_detail_view.dart';
import 'package:tom_brain_observatory_web/src/views/memory/node_link_chip.dart';
import 'package:tom_brain_observatory_web/src/views/memory/memory_home_view.dart';
import 'package:tom_brain_observatory_web/src/views/memory/recall_view.dart';
import 'package:tom_brain_observatory_web/src/views/memory/stacks_stats_view.dart';

import '../../support/stub_memory_api_client.dart';

const RecallReport _report = RecallReport(
  candidatesPerMode: <String, int>{'bm25': 4, 'vector': 6},
  fusionStrategy: 'rrf',
  diversityStrategy: 'mmr',
  elapsedMs: 42,
  embeddingsCallouts: 1,
  reRankInvoked: true,
  degraded: false,
);

MemoryNode _node(String id, {List<double>? embedding}) => MemoryNode(
      id: id,
      typeName: 'Question',
      status: 'active',
      createdAt: '2026-01-01T00:00:00Z',
      values: const <String, dynamic>{'text': 'why?'},
      embedding: embedding,
    );

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('NodeLinkChip', () {
    testWidgets('tapping pushes the node detail for its id', (tester) async {
      final client = StubMemoryApiClient(
        nodes: <String, MemoryNode>{'n1': _node('n1')},
      );
      await tester.pumpWidget(
          _host(NodeLinkChip(client: client, nodeId: 'n1', typeName: 'Question')));
      await tester.pumpAndSettle();

      expect(find.text('Question · n1'), findsOneWidget);
      await tester.tap(find.byType(NodeLinkChip));
      await tester.pumpAndSettle();

      expect(find.byType(NodeDetailView), findsOneWidget);
      expect(find.widgetWithText(AppBar, 'Node n1'), findsOneWidget);
    });
  });

  group('NodeDetailView', () {
    testWidgets('shows embedding as dim + norm, raw vector only on expand',
        (tester) async {
      final client = StubMemoryApiClient(
        nodes: <String, MemoryNode>{'n1': _node('n1', embedding: <double>[3, 4])},
      );
      await tester
          .pumpWidget(_host(NodeDetailView(client: client, nodeId: 'n1')));
      await tester.pumpAndSettle();

      expect(find.text('2 dims  ·  norm 5.000'), findsOneWidget);
      expect(find.text('3.0, 4.0'), findsNothing); // collapsed by default

      await tester.tap(find.text('embedding'));
      await tester.pumpAndSettle();
      expect(find.text('3.0, 4.0'), findsOneWidget);
    });

    testWidgets('renders incident edges with endpoint chips', (tester) async {
      final client = StubMemoryApiClient(
        nodes: <String, MemoryNode>{'n1': _node('n1')},
        edgesByNode: <String, List<MemoryEdge>>{
          'n1': const <MemoryEdge>[
            MemoryEdge(
                id: 'e1', from: 'n1', type: 'supports', to: 'n2', weight: 0.9),
          ],
        },
      );
      await tester
          .pumpWidget(_host(NodeDetailView(client: client, nodeId: 'n1')));
      await tester.pumpAndSettle();

      expect(find.text('—supports (0.90)→'), findsOneWidget);
      // The other endpoint is a walkable chip; the current node is plain.
      expect(find.byKey(const ValueKey<String>('node-link:n2')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('node-link:n1')), findsNothing);
    });

    testWidgets('a missing node shows the absence note', (tester) async {
      final client = StubMemoryApiClient();
      await tester
          .pumpWidget(_host(NodeDetailView(client: client, nodeId: 'gone')));
      await tester.pumpAndSettle();
      expect(find.text('No node gone.'), findsOneWidget);
    });
  });

  group('NodeBrowserView', () {
    testWidgets('browsing shows the non-exhaustive header and node chips',
        (tester) async {
      final client = StubMemoryApiClient(
        browses: <String, TypeBrowseResult>{
          'Event': TypeBrowseResult(
            typeName: 'Event',
            exhaustive: false,
            nodes: <MemoryNode>[_node('n1')],
            sources: const <String>['recall', 'stackPeek'],
          ),
        },
      );
      await tester.pumpWidget(_host(NodeBrowserView(client: client)));
      await tester.pumpAndSettle();

      // Default type is the first of the closed vocabulary (Event).
      await tester.tap(find.text('Browse'));
      await tester.pumpAndSettle();

      expect(find.textContaining('sample, not exhaustive'), findsOneWidget);
      expect(find.textContaining('recall, stackPeek'), findsOneWidget);
    });
  });

  group('RecallView', () {
    testWidgets('single-seed recall renders the cost report and result chips',
        (tester) async {
      final client = StubMemoryApiClient(
        recallResult: RecallResult(
          nodes: <MemoryNode>[_node('n1')],
          report: _report,
        ),
      );
      await tester.pumpWidget(_host(RecallView(client: client)));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'backup');
      await tester.tap(find.text('Recall'));
      await tester.pumpAndSettle();

      expect(find.text('cost report'), findsOneWidget);
      expect(find.textContaining('42ms'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('node-link:n1')), findsOneWidget);
    });

    testWidgets('multi-seed recall surfaces per-node provenance', (tester) async {
      final client = StubMemoryApiClient(
        recallResult: RecallResult(
          nodes: <MemoryNode>[_node('n1')],
          report: _report,
          provenance: const <RecallProvenance>[
            RecallProvenance(nodeId: 'n1', seedIndexes: <int>[0, 1], fusedScore: 0.7),
          ],
        ),
      );
      await tester.pumpWidget(_host(RecallView(client: client)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('multi seed'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Recall'));
      await tester.pumpAndSettle();

      expect(find.textContaining('seeds 0,1'), findsOneWidget);
      expect(client.calls, contains('recallMulti:1'));
    });
  });

  group('StacksStatsView', () {
    testWidgets('renders the stats snapshot, stacks, and view-only profiles',
        (tester) async {
      final client = StubMemoryApiClient(
        stackList: const <MemoryStackSummary>[
          MemoryStackSummary(
              name: 'attention', size: 3, topPriority: 0.9, bootstrap: false),
        ],
        profileList: const MemoryProfiles(
            profiles: <String>['default', 'eval'], current: 'default'),
      );
      await tester.pumpWidget(_host(StacksStatsView(client: client)));
      await tester.pumpAndSettle();

      expect(find.textContaining('1 stacks  ·  3 entries'), findsOneWidget);
      expect(find.text('attention'), findsOneWidget);
      expect(find.textContaining('never switches the brain'), findsOneWidget);
      expect(find.text('brain: default'), findsOneWidget);
    });
  });

  group('MemoryHomeView — profile switcher view-scoping', () {
    testWidgets('selecting a profile re-issues the visible reads against it and '
        'never issues a write', (tester) async {
      final client = StubMemoryApiClient(
        stackList: const <MemoryStackSummary>[
          MemoryStackSummary(
              name: 'attention', size: 1, topPriority: 0.5, bootstrap: false),
        ],
        profileList: const MemoryProfiles(
            profiles: <String>['default', 'eval'], current: 'default'),
      );
      await tester.pumpWidget(_host(MemoryHomeView(client: client)));
      await tester.pumpAndSettle();

      // Move to the Stacks tab where the switcher lives; its first read is the
      // bound view (no profile suffix).
      await tester.tap(find.text('Stacks & Stats'));
      await tester.pumpAndSettle();
      expect(client.calls, contains('stacks'));

      client.calls.clear();

      // Switch the viewed profile to 'eval'.
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('eval').last);
      await tester.pumpAndSettle();

      // The tab remounted and re-read memory in the 'eval' view (OBS-2):
      // the read carried the named profile, proving the switch re-issues the
      // visible reads against it.
      expect(client.calls, contains('stacks@eval'));
      // The whole surface is read-only — no write was ever issued (OBS-2:
      // switching the view never switches the brain).
      expect(client.calls.any((c) => c.startsWith('persist')), isFalse);
    });
  });

  group('deferred connector', () {
    testWidgets('an unavailable client shows the banner, not a crash',
        (tester) async {
      final client = StubMemoryApiClient(unavailable: true);
      await tester
          .pumpWidget(_host(NodeDetailView(client: client, nodeId: 'n1')));
      await tester.pumpAndSettle();

      expect(find.byType(MemoryUnavailableBanner), findsOneWidget);
      expect(find.text('Memory unavailable'), findsOneWidget);
    });
  });
}
