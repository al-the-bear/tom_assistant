// Todos 13–15 (history_compaction_plan.md) — dreaming lanes are fed their own
// "what has already been done" history so a dream procedure can skip work a
// prior run already did (13), each lane sizes its own window (14), and that
// window bounds by drop-oldest rather than by compaction (15).
//
// `FreeTimeScheduler.triggerMaintenance(procedureId)` is the single seam every
// dream firing flows through (the production `dream_cadence_wiring`'s `fire`
// callback and the r34 live cognitive-agent test both call it). Before this
// step it fired each dream with empty inputs; now it reads the global
// `recent_runs` stack, keeps only the completed `ProcedureRun` records that
// belong to the *firing lane* (same `procedureId`), and binds them into the
// invocation under `recentRunsArgumentKey` — but only when the lane has a
// resolvable prior run, so a first-ever run's inputs are byte-identical to the
// no-history case (mirroring the answer lane's `priorTurns` / `compactedSummary`
// discipline).
//
// ── What this suite proves ──────────────────────────────────────────────
//
//   1. A lane with a prior run that already handled the source receives that
//      run under `inputs.get('recentRuns')` and the procedure *skips* the work.
//   2. A first-ever run of a lane receives no `recentRuns` context — and a
//      prior run belonging to a *different* lane is filtered out, so the lane
//      does the work rather than skipping on another lane's history.
//
// These run on the in-memory `_StatefulMemory` double (mirroring c51 /
// procedure_engine_test), so the suite needs no on-disk vec0 store.

import 'dart:async';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, EdgeType, HistoryConfig, HistorySizing, NodeDraft, NodeId,
        ProcedureRunRef, Scope, StackEntry, StackEntryId, TrailEntry, TrailId,
        TrailOutcome, foregroundAnswerLaneId;
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show TomBrainSubstrateClient;

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

/// The lane under test — a stub dreaming agent that consults its prior-run
/// history and skips when a previous run already handled the source.
const _laneId = 'dream_stub_v1';

void main() {
  late _StatefulMemory memory;

  setUp(() {
    memory = _StatefulMemory();
  });

  ProcedureEngine engineWith(LoadedProcedure procedure) => ProcedureEngine(
        resolver: ProcedureResolver(<LoadedProcedure>[procedure]),
        memory: memory,
        memoryBridge: MemoryBridge(memory),
        substrateBridge: SubstrateBridge(_NoopSubstrate()),
        now: () => DateTime.utc(2026, 6, 1, 12, 0, 0),
      );

  FreeTimeScheduler schedulerWith(
    LoadedProcedure procedure, {
    HistoryConfig historyConfig = const HistoryConfig.standard(),
  }) =>
      FreeTimeScheduler(
        coordinator: RunCoordinator(),
        memory: memory,
        workFactory: (_) => null,
        engine: engineWith(procedure),
        historyConfig: historyConfig,
      );

  /// Seeds one completed `ProcedureRun` node for [procedureId] with [summary]
  /// and pushes it onto the global `recent_runs` stack, exactly as the recorder
  /// does at run completion.
  Future<void> seedPriorRun({
    required String procedureId,
    required String summary,
  }) async {
    final id = await memory.persist(
      NodeDraft(
        typeName: procedureRunNodeType,
        values: <String, Object?>{
          'procedureId': procedureId,
          'runId': 'run-${memory.runSeq++}',
          'status': 'accepted',
          'summary': summary,
          'producedNodeIds': const <String>['claim-1'],
        },
      ),
      scope: const Scope(producer: 'test'),
    );
    await memory.stacks.push(recentRunsStackName, id);
  }

  group('todo 13 — a dreaming lane is fed its own prior-run history', () {
    test('a lane that already handled the source skips the repeated work',
        () async {
      await seedPriorRun(
        procedureId: _laneId,
        summary: 'extracted claims for alpha',
      );

      final outcome = await schedulerWith(_laneStub()).triggerMaintenance(
        _laneId,
        arguments: const <String, Object?>{'source': 'alpha'},
      );

      expect(outcome.status, TrailOutcomeStatus.accepted);
      // The procedure saw its prior-run context …
      expect(outcome.result!.output<int>('priorRunCount'), 1);
      // … and used it to skip the already-done work.
      expect(outcome.result!.output<bool>('skipped'), isTrue);
      expect(outcome.result!.output<bool>('didWork'), isFalse);
    });

    test(
        'a first-ever run gets no context, and another lane\'s history is '
        'filtered out, so the lane does the work', () async {
      // A prior run exists — but for a *different* lane. The firing lane must
      // not see it (per-lane filtering), so it has no reason to skip.
      await seedPriorRun(
        procedureId: 'dream_other_v1',
        summary: 'connected claims for alpha',
      );

      final outcome = await schedulerWith(_laneStub()).triggerMaintenance(
        _laneId,
        arguments: const <String, Object?>{'source': 'alpha'},
      );

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result!.output<int>('priorRunCount'), 0);
      expect(outcome.result!.output<bool>('skipped'), isFalse);
      expect(outcome.result!.output<bool>('didWork'), isTrue);
    });
  });

  group('todo 14 — a dreaming lane sizes its own prior-run window', () {
    /// Seeds [count] completed runs for the firing lane so the cap (not the
    /// seed count) is what bounds the window the lane is handed.
    Future<void> seedLaneRuns(int count) async {
      for (var i = 0; i < count; i++) {
        await seedPriorRun(procedureId: _laneId, summary: 'run #$i');
      }
    }

    test(
        "a lane's configured rawCount caps its window — honoured independently "
        'of the answer lane', () async {
      // 15 prior runs exist for the firing lane …
      await seedLaneRuns(15);

      // … but the lane configures its own window at 12, while the answer lane
      // is sized at 50 and the code default is 10. The lane must see exactly
      // its own 12 — not the answer lane's 50, not the default 10, and not the
      // uncapped 15.
      final outcome = await schedulerWith(
        _laneStub(),
        historyConfig: const HistoryConfig(
          lanes: <String, HistorySizing>{
            foregroundAnswerLaneId: HistorySizing(rawCount: 50),
            _laneId: HistorySizing(rawCount: 12),
          },
        ),
      ).triggerMaintenance(
        _laneId,
        arguments: const <String, Object?>{'source': 'gamma'},
      );

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result!.output<int>('priorRunCount'), 12);
    });

    test(
        'a lane with no override inherits the defaults window, ignoring the '
        'answer lane override', () async {
      await seedLaneRuns(15);

      // The lane has no entry of its own; only the answer lane is overridden
      // (to 50). The lane must fall back to the code-default window (10) — the
      // answer lane's 50 must not bleed across.
      final outcome = await schedulerWith(
        _laneStub(),
        historyConfig: const HistoryConfig(
          lanes: <String, HistorySizing>{
            foregroundAnswerLaneId: HistorySizing(rawCount: 50),
          },
        ),
      ).triggerMaintenance(
        _laneId,
        arguments: const <String, Object?>{'source': 'gamma'},
      );

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result!.output<int>('priorRunCount'), 10);
    });
  });

  // Todo 15 (history_compaction_plan.md) — a dreaming lane's activity history is
  // a bounded drop-oldest window, NOT a compactable `ConversationHistory`. The
  // answer lane compacts because its `pending` batch grows unbounded and older
  // turns carry irreplaceable context; a dreaming lane reads a window over the
  // already-bounded `recent_runs` stack, so crossing a "threshold" drops the
  // oldest runs rather than folding them — and nothing is lost, because what a
  // dream produced lives durably in the graph. Activity-history compaction is
  // therefore declined by design (memory_specification.md § 9.8 "Resolved
  // (Phase D todo 15)"). This group is the tripwire that pins that decision.
  group('todo 15 — a dreaming lane bounds activity history by drop-oldest, '
      'never by compaction', () {
    Future<void> seedLaneRuns(int count) async {
      for (var i = 0; i < count; i++) {
        await seedPriorRun(procedureId: _laneId, summary: 'run #$i');
      }
    }

    test(
        'crossing both rawCount and compactionThreshold stays bounded to '
        'rawCount and yields no compacted activity summary', () async {
      // 50 runs — far past both the default rawCount (10) and the default
      // compactionThreshold (40). If the lane modelled a compactable history it
      // would fold the older 40 into a summary; instead it drops them.
      await seedLaneRuns(50);

      final outcome = await schedulerWith(_laneStub()).triggerMaintenance(
        _laneId,
        arguments: const <String, Object?>{'source': 'gamma'},
      );

      expect(outcome.status, TrailOutcomeStatus.accepted);
      // Bounded by the window, not grown toward a fold: exactly rawCount.
      expect(outcome.result!.output<int>('priorRunCount'), 10);
      // No activity-history compaction path exists: the lane is handed no
      // compacted/activity summary, however many runs it has accumulated. If
      // this flips, someone wired activity compaction — revisit the § 9.8
      // decision deliberately rather than let it land silently.
      expect(outcome.result!.output<bool>('hasActivitySummary'), isFalse);
    });
  });
}

/// A stub dreaming procedure that consults `recentRuns` (the lane's own
/// prior-run history) and skips when a prior run's summary already mentions the
/// source it was asked to process. It writes nothing — the skip decision is
/// reported through the returned outputs, which is all the seam proof needs.
LoadedProcedure _laneStub() {
  const body = r'''
Future<Object?> run(inputs) async {
  final source = inputs.get('source');
  final recentRuns = inputs.getOrNull('recentRuns');
  final priorRuns = recentRuns is List ? recentRuns : const [];
  var alreadyDone = false;
  for (final run in priorRuns) {
    if (run is Map) {
      final summary = run['summary'];
      if (summary is String && summary.contains(source as String)) {
        alreadyDone = true;
        break;
      }
    }
  }
  // A dreaming lane is never handed a compacted activity summary (todo #15:
  // activity-history compaction is declined by design). The lane reports
  // whether one reached it so the suite can pin that absence as a tripwire.
  final activitySummary =
      inputs.getOrNull('compactedSummary') ?? inputs.getOrNull('activitySummary');
  return {
    'priorRunCount': priorRuns.length,
    'skipped': alreadyDone,
    'didWork': !alreadyDone,
    'hasActivitySummary': activitySummary != null,
  };
}
''';
  final source = '''
/// @procedure
/// id: $_laneId
/// version: 1
/// summary: a stub dreaming lane that skips already-done work
/// successCriterion: returns its skip decision
/// budget: { wallClockMs: 60000 }
/// inputs:
///   - { name: source, type: String, required: true }
///   - { name: recentRuns, type: List }
///   - { name: compactedSummary, type: String }
///   - { name: activitySummary, type: String }
$body
''';
  return ProcedureLoader.shared.load(
    ProcedureSource(
      ref: ProcedureRef.system('/procedures/$_laneId.dart'),
      source: source,
    ),
  );
}

// ── A substrate double the stub never calls ─────────────────────────────────
class _NoopSubstrate implements TomBrainSubstrateClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

// ── A stateful in-memory `TomBrainMemoryClient` ─────────────────────────────
//
// Models just enough of the store for the recorder's writes plus the prior-run
// seeding (`persist` + `recent_runs` push) and the scheduler's read-back
// (`stacks.peek` + `get`). Mirrors the double in c51 / procedure_engine_test.
class _StatefulMemory implements TomBrainMemoryClient {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

  /// Monotonic counter for deterministic seeded run ids.
  int runSeq = 0;

  @override
  StackApi get stacks => _stacks;

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

class _InMemoryStacks implements StackApi {
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
