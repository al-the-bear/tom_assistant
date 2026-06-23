// Todos 13–15 (history_compaction_plan.md) — dreaming lanes are fed their own
// "what has already been done" history so a dream procedure can skip work a
// prior run already did (13), each lane sizes its own window (14), and a
// dreaming lane is *one long session* that keeps its own persistent,
// compactable activity history across firings (15).
//
// `FreeTimeScheduler.triggerMaintenance(procedureId)` is the single seam every
// dream firing flows through (the production `dream_cadence_wiring`'s `fire`
// callback and the r34 live cognitive-agent test both call it). Before todos
// 13/14 it fired each dream with empty inputs; now it reads the global
// `recent_runs` stack, keeps only the completed `ProcedureRun` records that
// belong to the *firing lane* (same `procedureId`), and binds them into the
// invocation under `recentRunsArgumentKey` — but only when the lane has a
// resolvable prior run, so a first-ever run's inputs are byte-identical to the
// no-history case (mirroring the answer lane's `priorTurns` / `compactedSummary`
// discipline).
//
// Todo 15 adds the *narrative* half on top of that run-bookkeeping view: a
// dreaming lane carries its own [ConversationHistory] in a [DreamLaneSessions]
// registry. Each firing appends one turn (its trigger + the run's summary), the
// next firing is fed the accumulated turns under `priorTurns` (and the bounded
// `compactedSummary` once the lane has folded), and when the lane's `pending`
// batch crosses its `compactionThreshold` the lane compacts its own activity
// history through the same [HistoryCompactor] the answer lane uses. The two
// views answer different questions and are not a second source of truth:
// `recentRuns` is "which runs already touched this source" (bookkeeping over
// the graph); the session history is "what have I been doing while dreaming"
// (a continuous narrative). See decisions HC-60…HC-65 (supersede HC-57…HC-59).
//
// ── What this suite proves ──────────────────────────────────────────────
//
//   1. (todo 13) A lane with a prior run that already handled the source
//      receives it under `inputs.get('recentRuns')` and *skips* the work; a
//      first-ever run and another lane's history are filtered out.
//   2. (todo 14) A lane's configured `rawCount` caps its prior-run window,
//      independently of the answer lane.
//   3. (todo 15) A lane remembers prior firings (persistence across firings),
//      compacts its own activity history at the threshold, and the registry
//      round-trips through `toJson` / `restore`.
//
// These run on the in-memory `_StatefulMemory` double (mirroring c51 /
// procedure_engine_test), so the suite needs no on-disk vec0 store.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, EdgeType, HistoryConfig, HistorySizing, NodeDraft, NodeId,
        ProcedureRunRef, Scope, StackEntry, StackEntryId, TrailEntry, TrailId,
        TrailOutcome, conversationHistoriesEqual, foregroundAnswerLaneId;
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show TomBrainSubstrateClient;

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

import 'support/boot_doubles.dart' show BootSubstrate;

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
    DreamLaneSessions? dreamSessions,
  }) =>
      FreeTimeScheduler(
        coordinator: RunCoordinator(),
        memory: memory,
        workFactory: (_) => null,
        engine: engineWith(procedure),
        historyConfig: historyConfig,
        dreamSessions: dreamSessions,
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

  // Todo 15 (history_compaction_plan.md) — a dreaming lane is *one long
  // session* that continues whenever the lane is fired again. It carries its
  // own persistent [ConversationHistory] in a [DreamLaneSessions] registry: each
  // firing appends one turn (the trigger + the run's summary), the next firing
  // is fed the accumulated turns under `priorTurns`, and when the lane's
  // `pending` batch crosses its `compactionThreshold` the lane compacts its own
  // activity history through the same [HistoryCompactor] the answer lane uses —
  // derivation, not deletion (the durable record keeps every firing). This is
  // the narrative complement to todo 13/14's `recentRuns` run-bookkeeping view;
  // the two answer different questions (see HC-60…HC-65, supersede HC-57…59).
  group('todo 15 — a dreaming lane is one long session with its own '
      'persistent, compactable activity history', () {
    test(
        'a lane remembers prior firings: a firing is recorded and the next '
        'firing receives it under priorTurns', () async {
      final sessions = DreamLaneSessions();
      final scheduler =
          schedulerWith(_laneSessionStub(), dreamSessions: sessions);

      // First firing: no prior session history, so `priorTurns` is absent and
      // the lane sees a cold start (byte-stable with the no-session case).
      final first = await scheduler.triggerMaintenance(
        _laneId,
        arguments: const <String, Object?>{'source': 'alpha'},
      );
      expect(first.status, TrailOutcomeStatus.accepted);
      expect(first.result!.output<int>('priorTurnCount'), 0);

      // … and the firing was recorded as one turn in the lane's own history.
      final history = sessions.peek(_laneId);
      expect(history, isNotNull);
      expect(history!.rawWindow, hasLength(1));

      // Second firing: the lane now remembers the first firing as a prior turn.
      final second = await scheduler.triggerMaintenance(
        _laneId,
        arguments: const <String, Object?>{'source': 'beta'},
      );
      expect(second.status, TrailOutcomeStatus.accepted);
      expect(second.result!.output<int>('priorTurnCount'), 1);
    });

    test(
        'a lane crossing its compactionThreshold compacts its own activity '
        'history, and the next firing receives the compacted summary',
        () async {
      // Size this lane tiny so a few firings cross the threshold: a window of
      // one verbatim turn, fold once two pending turns accumulate.
      const tiny = HistoryConfig(
        lanes: <String, HistorySizing>{
          _laneId: HistorySizing(rawCount: 1, compactionThreshold: 2),
        },
      );
      final sessions = DreamLaneSessions(
        historyConfig: tiny,
        compactor: _stubCompactor('folded earlier dreaming'),
      );
      final scheduler = schedulerWith(_laneSessionStub(),
          dreamSessions: sessions);

      // Fire enough times to push `pending` past the threshold (rawCount 1 +
      // compactionThreshold 2 ⇒ the third firing's append crosses it).
      for (var i = 0; i < 3; i++) {
        await scheduler.triggerMaintenance(
          _laneId,
          arguments: <String, Object?>{'source': 'src-$i'},
        );
      }

      // The lane folded its pending batch into a bounded summary — derivation,
      // not deletion: the durable record still holds every firing.
      final history = sessions.peek(_laneId)!;
      expect(history.compactedSummary, 'folded earlier dreaming');
      expect(history.pending, isEmpty);
      expect(history.durableRecord, hasLength(3));

      // The next firing receives that compacted summary.
      final next = await scheduler.triggerMaintenance(
        _laneId,
        arguments: const <String, Object?>{'source': 'src-next'},
      );
      expect(next.result!.output<String?>('compactedSummary'),
          'folded earlier dreaming');
    });

    test('the registry round-trips through toJson / restore', () async {
      final sessions = DreamLaneSessions();
      final scheduler =
          schedulerWith(_laneSessionStub(), dreamSessions: sessions);
      await scheduler.triggerMaintenance(
        _laneId,
        arguments: const <String, Object?>{'source': 'alpha'},
      );

      final restored = DreamLaneSessions()..restore(sessions.toJson());

      final original = sessions.peek(_laneId)!;
      final rehydrated = restored.peek(_laneId)!;
      expect(conversationHistoriesEqual(original, rehydrated), isTrue);
    });

    // Open-ends step 5 (HC-82): a dreaming lane's activity history is *durable*
    // (survives a process restart through the on-disk store seams) and its
    // compaction runs through the *production* `SubstrateHistoryCompaction` path
    // — the anchored, budgeted `sub.llm` seam (PE-7/PE-8) the foreground answer
    // lane matured in step 4 (HC-81) — not a one-line stub. This one test pins
    // both halves of the done-when: a real over-threshold session folds through
    // the substrate, and a fresh `DreamLaneSessions` rebuilt from the same
    // on-disk file recovers the lane mid-narrative.
    test(
        'a dreaming lane persists across a restart and compacts through the '
        'real anchored sub.llm seam', () async {
      // A real temp JSON file standing in for production's
      // `JsonFileHistoryStore('<memoryRoot>/dream_lane_sessions.json')` — the
      // durable-persistence seam pair (HC-82). The seams are plain functions, so
      // the test exercises on-disk round-tripping without a tom_brain_access
      // dependency (the store's `dart:io` lives in `tom_brain_run` in
      // production).
      final dir = Directory.systemTemp.createTempSync('dream_lane_store_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File(
          '${dir.path}${Platform.pathSeparator}dream_lane_sessions.json');
      Map<String, Object?> loadStore() => file.existsSync()
          ? jsonDecode(file.readAsStringSync()) as Map<String, Object?>
          : <String, Object?>{};
      void saveStore(Map<String, Object?> snapshot) =>
          file.writeAsStringSync(jsonEncode(snapshot));

      // The compaction completion routes through the real production seam over a
      // shared `BootSubstrate` (not a stub): the `recaller`-routed call falls
      // through to the answer branch, which streams these chunks; the seam
      // concatenates them into the rewritten summary.
      final compactionSubstrate = BootSubstrate()
        ..answerChunks = <String>['folded ', 'dreaming'];
      final compactor = HistoryCompactor(
        templates: _compactionTemplates(),
        substrate: SubstrateHistoryCompaction(client: compactionSubstrate).call,
      );

      // Size the lane tiny so the third firing's append crosses the threshold
      // (rawCount 1 + compactionThreshold 2).
      const tiny = HistoryConfig(
        lanes: <String, HistorySizing>{
          _laneId: HistorySizing(rawCount: 1, compactionThreshold: 2),
        },
      );

      // ── First boot ──────────────────────────────────────────────────
      final sessions = DreamLaneSessions(
        historyConfig: tiny,
        compactor: compactor,
        loadSnapshot: loadStore,
        persistSnapshot: saveStore,
      );
      final scheduler =
          schedulerWith(_laneSessionStub(), dreamSessions: sessions);

      for (var i = 0; i < 3; i++) {
        await scheduler.triggerMaintenance(
          _laneId,
          arguments: <String, Object?>{'source': 'src-$i'},
        );
      }

      // The lane folded its pending batch through the *real* substrate seam …
      final history = sessions.peek(_laneId)!;
      expect(history.compactedSummary, 'folded dreaming');
      expect(history.pending, isEmpty);
      expect(history.durableRecord, hasLength(3));
      // … and the compaction completion actually reached the substrate: the
      // assembled `compact_history_v1` scaffolds were folded into the single
      // `prompt` input the anchored role path consumes.
      expect(compactionSubstrate.lastPrompt, isNotNull);
      expect(compactionSubstrate.lastPrompt, contains('Fold the new turns'));
      // The folded session was written through to the durable store.
      expect(file.existsSync(), isTrue);

      // ── Restart: a fresh registry rebuilt from the same on-disk file ──
      final recovered = DreamLaneSessions(
        historyConfig: tiny,
        loadSnapshot: loadStore,
      );
      final rehydrated = recovered.peek(_laneId);
      expect(rehydrated, isNotNull,
          reason: 'the lane survived the restart through the durable store');
      expect(rehydrated!.compactedSummary, 'folded dreaming');
      expect(rehydrated.durableRecord, hasLength(3));
      expect(conversationHistoriesEqual(history, rehydrated), isTrue);
    });
  });
}

/// A `compact_history_v1` template store whose scaffolds inject the two history
/// placeholders — the same shape the production `compact_history_v1.yaml` will
/// carry. Paired with the real [SubstrateHistoryCompaction] seam (not a stubbed
/// return) so a test proves a dreaming lane's compaction reaches the substrate.
HistoryCompactionTemplateStore _compactionTemplates() {
  final dir = Directory.systemTemp.createTempSync('dream_lane_compact_tpl_');
  addTearDown(() => dir.deleteSync(recursive: true));
  File('${dir.path}${Platform.pathSeparator}compact_history_v1.yaml')
      .writeAsStringSync(
    'system: |\n  Fold the new turns. Current: \${history.compacted}\n'
    'user: |\n  New turns: \${history.batch}\n',
  );
  return HistoryCompactionTemplateStore(dir);
}

/// A [HistoryCompactor] whose substrate folds the pending batch into a fixed
/// [summary] — the engine-side compaction seam, stubbed so the suite proves a
/// dreaming lane compacts its *own* activity history without a live model.
HistoryCompactor _stubCompactor(String summary) {
  final dir = Directory.systemTemp.createTempSync('dream_lane_tpl_');
  addTearDown(() => dir.deleteSync(recursive: true));
  File('${dir.path}${Platform.pathSeparator}compact_history_v1.yaml')
      .writeAsStringSync(
    'system: |\n  fold \${history.compacted}\n'
    'user: |\n  \${history.batch}\n',
  );
  return HistoryCompactor(
    templates: HistoryCompactionTemplateStore(dir),
    substrate: (_) async => summary,
  );
}

/// A stub dreaming procedure that reports the *session-history* context it was
/// handed — the count of `priorTurns` (the lane's own accumulated firings) and
/// the `compactedSummary` (set once the lane has folded). This is how the suite
/// proves a dreaming lane remembers across firings and feeds back its compacted
/// activity history; it writes nothing.
LoadedProcedure _laneSessionStub() {
  const body = r'''
Future<Object?> run(inputs) async {
  final priorTurns = inputs.getOrNull('priorTurns');
  final turns = priorTurns is List ? priorTurns : const [];
  return {
    'priorTurnCount': turns.length,
    'compactedSummary': inputs.getOrNull('compactedSummary'),
  };
}
''';
  final source = '''
/// @procedure
/// id: $_laneId
/// version: 1
/// summary: a stub dreaming lane that reports its session history
/// successCriterion: returns its prior-turn count
/// budget: { wallClockMs: 60000 }
/// inputs:
///   - { name: source, type: String, required: true }
///   - { name: priorTurns, type: List }
///   - { name: compactedSummary, type: String }
$body
''';
  return ProcedureLoader.shared.load(
    ProcedureSource(
      ref: ProcedureRef.system('/procedures/${_laneId}_session.dart'),
      source: source,
    ),
  );
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
