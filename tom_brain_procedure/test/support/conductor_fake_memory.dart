// Shared test double for the `recall_conductor_v1` suites.
//
// A recall-capturing `TomBrainMemory` that returns a fixed five-node Claim seed
// for every recall (seed + every re-search), captures every `RecallQuery` the
// bridge builds (so a suite can assert the read-only invariant and the ranking
// the loop drove), and models just enough of the store for the run recorder's
// writes to succeed. It deliberately needs no vec0 / no embeddings, so it lets a
// suite drive the *real* conductor procedure against either a scripted substrate
// (the unit suite) or a live local route (the §19 live-verification suite)
// without standing up a SQLite store.

import 'dart:async';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, TrailId, Vec;

/// A recall-capturing `TomBrainMemory` returning a fixed five-Claim seed for
/// every recall, capturing every issued [RecallQuery], and modelling just
/// enough of the store for the run recorder to succeed.
class ConductorFakeMemory implements TomBrainMemory {
  final ConductorFakeStacks _stacks = ConductorFakeStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

  /// Every [RecallQuery] the conductor issued, in order (seed + re-searches).
  final List<RecallQuery> recallQueries = <RecallQuery>[];
  MultiRecallQuery? lastMultiRecallQuery;

  /// The fixed seed corpus — five Claims with stable ids. The body maps each
  /// to its `node.id.value`, so [seedIds] are exactly the id strings the
  /// conductor surfaces and a KEEP line references.
  final List<Node> _seedNodes = <Node>[
    for (var i = 1; i <= 5; i++)
      Node(
        id: NodeId.fromString('n_0000000000000000000000000$i'),
        typeName: 'Claim',
        values: <String, Object?>{'statement': _seedStatements[i - 1]},
        createdAt: DateTime.utc(2026, 6, 1),
      ),
  ];

  /// Realistic, backup-themed seed statements — distinct enough that a live
  /// curation route has something meaningful to rank and keep.
  static const List<String> _seedStatements = <String>[
    'A nightly cron job rsyncs /home to the bomber NAS at 02:00.',
    'Weekly full backups are written to an external USB drive kept off-site.',
    'The user prefers automated backups over manual copies.',
    'Restic with a B2 remote was evaluated but not yet adopted.',
    'Database dumps are excluded from the rsync set and handled separately.',
  ];

  /// The id strings of the seed corpus, in order.
  List<String> get seedIds =>
      _seedNodes.map((n) => n.id.value).toList(growable: false);

  RecallResult _seedResult() => RecallResult(
        nodes: _seedNodes,
        report: const RecallReport(
          candidatesPerMode: <RecallMode, int>{RecallMode.bm25: 5},
          fusionStrategy: FusionStrategy.rrf,
          diversityStrategy: DiversityStrategy.mmr,
          elapsedMs: 3,
        ),
      );

  @override
  StackApi get stacks => _stacks;

  @override
  Future<RecallResult> recall(RecallQuery query) async {
    recallQueries.add(query);
    return _seedResult();
  }

  @override
  Future<RecallResult> recallMulti(MultiRecallQuery query) async {
    lastMultiRecallQuery = query;
    return _seedResult();
  }

  @override
  Future<ClassificationResult> classify(
    Vec embedding, {
    ClassificationTarget target = ClassificationTarget.nodeType,
  }) async =>
      const ClassificationResult.unknown();

  @override
  Future<TrailId> openTrail(ProcedureRunRef run) async {
    final id = TrailId.generate();
    _trails[id] = <TrailEntry>[];
    return id;
  }

  @override
  Future<void> appendTrail(TrailId id, TrailEntry entry) async {
    final entries = _trails[id];
    if (entries == null) {
      throw StateError('appendTrail on an unopened trail: $id');
    }
    if (_closedTrails.contains(id)) {
      throw StateError('appendTrail on a closed trail: $id');
    }
    entries.add(entry);
  }

  @override
  Future<void> closeTrail(TrailId id, TrailOutcome outcome) async {
    final entries = _trails[id];
    if (entries == null) {
      throw StateError('closeTrail on an unopened trail: $id');
    }
    entries.add(TrailEntry.outcome(outcome));
    _closedTrails.add(id);
  }

  @override
  Stream<TrailEntry> readTrail(TrailId id) {
    final entries = _trails[id];
    if (entries == null) {
      return Stream<TrailEntry>.error(
        StateError('readTrail on an unknown trail: $id'),
      );
    }
    return Stream<TrailEntry>.fromIterable(List<TrailEntry>.of(entries));
  }

  @override
  Future<NodeId> persist(NodeDraft draft, {required Scope scope}) async {
    final id = NodeId.generate();
    _nodes[id] = Node(
      id: id,
      typeName: draft.typeName,
      values: Map<String, Object?>.of(draft.values),
      createdAt: DateTime.now().toUtc(),
    );
    return id;
  }

  @override
  Future<Node?> get(NodeId id) async => _nodes[id];

  @override
  Future<EdgeId> edge(
    NodeId from,
    EdgeType type,
    NodeId to, {
    required Scope scope,
    double weight = 1.0,
    Map<String, Object?>? attrs,
  }) async =>
      EdgeId.generate();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// An in-memory `StackApi` sufficient for the conductor's stack pushes.
class ConductorFakeStacks implements StackApi {
  final Map<String, List<StackEntry>> _stacks = <String, List<StackEntry>>{};

  @override
  Future<StackEntryId> push(
    String name,
    NodeId entry, {
    double priority = 0.0,
    Map<String, Object?>? attrs,
    Scope? scope,
  }) async {
    final id = StackEntryId.generate();
    (_stacks[name] ??= <StackEntry>[]).add(
      StackEntry(
        id: id,
        stackName: name,
        nodeId: entry,
        priority: priority,
        pushedAt: DateTime.now().toUtc(),
        attrs: attrs ?? const <String, Object?>{},
      ),
    );
    return id;
  }

  @override
  Future<List<StackEntry>> peek(String name, {int k = 16}) async {
    final entries = _stacks[name] ?? const <StackEntry>[];
    final active = entries
        .where((e) => e.status == StackEntryStatus.active)
        .toList(growable: false);
    return active.length <= k ? active : active.sublist(0, k);
  }

  @override
  Future<void> remove(String name, NodeId entry) async {
    _stacks[name]?.removeWhere((e) => e.nodeId == entry);
  }

  @override
  Future<StackEntry?> pop(String name) async {
    final entries = _stacks[name];
    if (entries == null || entries.isEmpty) return null;
    return entries.removeLast();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
