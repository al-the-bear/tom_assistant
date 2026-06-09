// P2.23 — a minimal, explicit single-shot background trigger for maintenance
// agents (no autonomous scheduler), proven end-to-end through the real stack.
//
// prototype_implementation_plan_2.md #23:
//   "Minimal background trigger for agents (no autonomous scheduler). A
//    `free_time_scheduler_v1` that runs a named maintenance procedure on the
//    dispatcher's background slot only when explicitly invoked (manual trigger
//    / single-shot), preserving 'no autonomous dreaming' for the prototype.
//    Test: a manual trigger runs Extractor in the background slot and is
//    preempted by a foreground request. Verify: a foreground prompt preempts an
//    in-flight background agent and resumes it after."
//
// ── What this suite proves ──────────────────────────────────────────────
//
// The deliverable is `FreeTimeScheduler.triggerMaintenance`: an explicit,
// single-shot trigger that runs a *named* maintenance procedure on the
// coordinator's background slot — only when the caller asks for it, never on a
// timer (no autonomous dreaming). Unlike `tick` (which harvests a hot-stack
// entry), the caller names the procedure and the trigger submits it as one
// engine-backed background run.
//
// The proof drives the *real* production stack: the on-disk Extractor script
// (`dream_extract_v1`) through the real `ProcedureEngine`, against a *real*
// on-disk `SqliteTomBrainMemory`, submitted to the *real* `RunCoordinator`'s
// background slot, sharing the *real* `PreemptionState` the engine yields
// against. The substrate is a gated stub so the test controls exactly when the
// background run is mid-flight.
//
//   The Test — a manual trigger runs the Extractor in the background slot. The
//     slot is occupied the moment the trigger returns.
//   The Verify — a foreground prompt arrives while the Extractor is in flight;
//     the Extractor parks at its next cooperative checkpoint
//     (`yield_if_foreground_waiting()`), the foreground runs to completion, and
//     only then does the Extractor resume and finish — leaving the full Claim
//     delta in the real store. Work done before the preemption is preserved;
//     work after it completes after the resume; nothing is lost or double-run.
//
// Like p2_15 – p2_22 these cases open the real on-disk store, which refuses to
// boot without the packaged vec0 binary (P1.1), so the group is skipped — not
// failed — when no binary is present for the platform.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show AgentRegistration, NodeDraft, PreemptionState, Scope, Vec, WriteBudget;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

/// The bootstrap embedding model dimensionality (768, nomic-embed-text).
const _bootstrapDims = 768;

/// The shared salient term every seeded Event summary carries, so the
/// Extractor's BM25 recall surfaces the whole seeded trail from a single-term
/// query (vector mode degrades without a query embedding). Mirrors p2_21.
const _salientTerm = 'project';

/// A deterministic 768-dim vector — the preemption properties under test ride
/// on the coordinator and the gated substrate, not on embedding values.
Vec _v768({required int seed}) {
  final values = Float32List(_bootstrapDims);
  for (var i = 0; i < _bootstrapDims; i++) {
    values[i] = ((seed * 31 + i) % 1000) / 1000.0;
  }
  return Vec(values);
}

/// Locates `<workspace>/tom_binaries/sqlite_vec`. Mirrors p2_21.
String? _findSqliteVecRoot() {
  var dir = Directory.current.absolute;
  for (var i = 0; i < 8; i++) {
    final candidate =
        Directory('${dir.path}${Platform.pathSeparator}tom_binaries'
            '${Platform.pathSeparator}sqlite_vec');
    if (candidate.existsSync()) return candidate.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

/// An Event [NodeDraft] sharing [_salientTerm] so the Extractor's BM25 recall
/// surfaces it. Mirrors p2_21.
NodeDraft _eventDraft({required String summary, required int seed}) => NodeDraft(
      typeName: 'Event',
      values: <String, Object?>{
        'summary': summary,
        'payload': const <String, Object?>{},
        'occurred_at': '2026-06-05T10:00:00.000Z',
      },
      embedding: _v768(seed: seed),
    );

/// A budget wide enough not to interfere — the run is bounded by the script's
/// own header budget, not this agent budget.
WriteBudget _unboundedBudget() =>
    WriteBudget(maxNodes: 1000, maxEdges: 1000, maxStackEntries: 1000);

/// Registers the Extractor agent with the `node:Claim` write scope.
AgentRegistration _extractorAgent() => AgentRegistration(
      agentName: 'dream_extract_v1',
      procedureId: 'dream_extract_v1',
      defaultBudget: _unboundedBudget(),
      readScopes: const <String>{AgentRegistration.globalWildcard},
      writeScopes: <String>{AgentRegistration.nodeScope('Claim')},
    );

void main() {
  final vecRoot = _findSqliteVecRoot();
  final resolver = SqliteVecBinaryResolver();

  String? resolvedPath;
  if (vecRoot != null && resolver.isSupported) {
    final path = resolver.resolve(vecRoot);
    if (File(path).existsSync()) resolvedPath = path;
  }

  final skipNoBinary = resolvedPath == null
      ? 'No packaged vec0 binary for this platform under '
          'tom_binaries/sqlite_vec (resolver.isSupported='
          '${resolver.isSupported}, vecRoot=$vecRoot).'
      : null;

  MemoryConfig freshConfig() {
    final root = Directory.systemTemp.createTempSync('tbm_p2_23_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    return MemoryConfig.forTesting(root: root.path, binariesRoot: vecRoot!);
  }

  Future<SqliteTomBrainMemory> openStore() async {
    final store = SqliteTomBrainMemory();
    await store.open(freshConfig());
    addTearDown(store.close);
    return store;
  }

  /// Seeds three episodic Events sharing [_salientTerm], unscoped (the
  /// bootstrap/system write path). Mirrors p2_21.
  Future<void> seedTrail(SqliteTomBrainMemory store) async {
    const summaries = <String>[
      'The project build was deployed to the bomber server.',
      'The project backup synced nightly to the NAS device.',
      'The project roadmap meeting set the quarterly goals.',
    ];
    for (var i = 0; i < summaries.length; i++) {
      await store.persist(
        _eventDraft(summary: summaries[i], seed: 100 + i),
        scope: Scope(producer: 'p2.23:seed', idempotencyKey: 'seed-$i'),
      );
    }
  }

  /// Builds an engine running the Extractor under its agent identity, wired
  /// over the real [store], the [substrate] stub, and the shared [preemption]
  /// state the coordinator drives — so the script's
  /// `yield_if_foreground_waiting()` checkpoint reads the same state a
  /// foreground arrival writes.
  Future<ProcedureEngine> engineFor({
    required SqliteTomBrainMemory store,
    required TomBrainSubstrateClient substrate,
    required PreemptionState preemption,
  }) async {
    final system = await ProcedureResolver.fromStore(
      DiskProcedureStore(systemDir: Directory('scripts/system')),
    );
    return ProcedureEngine(
      resolver: ProcedureResolver(
        <LoadedProcedure>[system.resolve('dream_extract_v1')],
      ),
      memory: store,
      memoryBridge: MemoryBridge(store, agentName: 'dream_extract_v1'),
      substrateBridge: SubstrateBridge(substrate),
      preemptionState: preemption,
      now: () => DateTime.utc(2026, 6, 5, 12, 0, 0),
    );
  }

  group('explicit background trigger preemption (needs vec0)', () {
    test('a manual trigger runs the Extractor in the background slot, is '
        'preempted by a foreground prompt, and resumes after', () async {
      final store = await openStore();
      await seedTrail(store);
      store.registerAgent(_extractorAgent());

      final coordinator = RunCoordinator();
      // The substrate steps the Extractor one event at a time: each `llm` call
      // announces it was entered and then blocks until the test releases it, so
      // the park/resume boundary is observed by signal, never by timing.
      final substrate = _SteppedDreamSubstrate();
      final engine = await engineFor(
        store: store,
        substrate: substrate,
        preemption: coordinator.preemption,
      );
      // The scheduler has no stack work to harvest here — `triggerMaintenance`
      // is the explicit single-shot path, so the (unused) stack-harvest factory
      // simply declines every pick.
      final scheduler = FreeTimeScheduler(
        coordinator: coordinator,
        memory: store,
        workFactory: (_) => null,
        engine: engine,
      );

      // The Test: an explicit trigger runs the Extractor on the background slot.
      final outcome = scheduler.triggerMaintenance(
        'dream_extract_v1',
        arguments: const <String, Object?>{'source': _salientTerm},
      );
      expect(coordinator.hasBackgroundRun, isTrue,
          reason: 'the named maintenance run occupies the background slot');

      // The Extractor cleared its first checkpoint (no foreground yet) and is
      // genuinely mid-flight, blocked extracting the first event.
      await substrate.reached(0);
      expect(coordinator.hasBackgroundRun, isTrue);

      // The Verify, part 1: a foreground prompt arrives. With a background run
      // live the coordinator requests cooperative preemption.
      final fgGate = Completer<void>();
      final fg = coordinator.submitForeground<void>(() => fgGate.future);
      expect(coordinator.hasForegroundRun, isTrue);
      expect(coordinator.preemption.isForegroundWaiting, isTrue);

      // Release the first event: the Extractor finishes it, then reaches the
      // *next* event's checkpoint and parks — a foreground is waiting. Even
      // after generous pumping it does NOT enter the second event's extraction:
      // it is blocked at the cooperative boundary, not merely slow.
      substrate.release(0);
      await pumpEventQueue(times: 50);
      expect(substrate.hasReached(1), isFalse,
          reason: 'parked at the yield checkpoint before the next event — the '
              'run does not advance under foreground load');
      expect(coordinator.hasBackgroundRun, isTrue);
      expect(coordinator.hasForegroundRun, isTrue);

      // The Verify, part 2: the foreground drains; the parked Extractor resumes
      // — proven by the second event's extraction now being entered — and runs
      // to completion.
      fgGate.complete();
      await fg;
      await substrate.reached(1);
      substrate.release(1);
      await substrate.reached(2);
      substrate.release(2);

      final result = await outcome;
      expect(result.status, TrailOutcomeStatus.accepted,
          reason: 'a clean resume, not a force-yield or crash');

      final claimIds = result.result!.output<List<Object?>>('claimIds');
      expect(claimIds, isNotNull);
      expect(claimIds!.length, 3, reason: 'every seeded event was extracted');

      final stats = await store.stats();
      expect(stats.nodeCountByType['Claim'], 3,
          reason: 'the resumed run finished the remaining events');
      expect(coordinator.hasBackgroundRun, isFalse,
          reason: 'the background slot is freed once the run completes');
    });

    test('a second trigger while one is in flight is refused — at most one '
        'background run (PE-5)', () async {
      final store = await openStore();
      await seedTrail(store);
      store.registerAgent(_extractorAgent());

      final coordinator = RunCoordinator();
      final substrate = _SteppedDreamSubstrate();
      final engine = await engineFor(
        store: store,
        substrate: substrate,
        preemption: coordinator.preemption,
      );
      final scheduler = FreeTimeScheduler(
        coordinator: coordinator,
        memory: store,
        workFactory: (_) => null,
        engine: engine,
      );

      final first = scheduler.triggerMaintenance(
        'dream_extract_v1',
        arguments: const <String, Object?>{'source': _salientTerm},
      );
      await substrate.reached(0);
      expect(coordinator.hasBackgroundRun, isTrue);

      // A second explicit trigger cannot occupy the busy slot.
      expect(
        () => scheduler.triggerMaintenance(
          'dream_extract_v1',
          arguments: const <String, Object?>{'source': _salientTerm},
        ),
        throwsA(isA<RunSlotBusy>()),
      );

      // Let the in-flight run drain so teardown closes a quiescent store.
      substrate.release(0);
      await substrate.reached(1);
      substrate.release(1);
      await substrate.reached(2);
      substrate.release(2);
      await first;
    });
  }, skip: skipNoBinary);
}

// ── A step-gated deterministic dream-substrate stub ─────────────────────────
//
// Mirrors p2_21's `_DreamSubstrate` but lets the test drive the Extractor's
// per-event loop one extraction at a time: the Nth `llm` call announces it was
// entered ([reached]) and then blocks until the test [release]s it. Because the
// Extractor's cooperative checkpoint sits at the top of each loop iteration,
// the call counter is a precise probe of how far the run has advanced — a
// parked run never enters the next event's `llm`, so [hasReached] of the next
// index stays false until the foreground drains and the run resumes.
class _SteppedDreamSubstrate implements TomBrainSubstrateClient {
  final List<Completer<void>> _reached = <Completer<void>>[];
  final List<Completer<void>> _release = <Completer<void>>[];
  int _llmCalls = 0;

  Completer<void> _reachedAt(int i) {
    while (_reached.length <= i) {
      _reached.add(Completer<void>());
    }
    return _reached[i];
  }

  Completer<void> _releaseAt(int i) {
    while (_release.length <= i) {
      _release.add(Completer<void>());
    }
    return _release[i];
  }

  /// Resolves once the [i]-th `llm` extraction has been entered.
  Future<void> reached(int i) => _reachedAt(i).future;

  /// Whether the [i]-th `llm` extraction has been entered yet (a synchronous
  /// probe the park assertion reads).
  bool hasReached(int i) => i < _reached.length && _reached[i].isCompleted;

  /// Unblocks the [i]-th `llm` extraction so the run advances past it.
  void release(int i) {
    final completer = _releaseAt(i);
    if (!completer.isCompleted) completer.complete();
  }

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) async* {
    final index = _llmCalls++;
    final reached = _reachedAt(index);
    if (!reached.isCompleted) reached.complete();
    await _releaseAt(index).future;
    yield const LlmStreamChunk(
      callId: 'c',
      text: 'The project claim was extracted.',
    );
    yield const LlmStreamCompleted(
      callId: 'c',
      report: LlmCallReport(
        providerId: 'p',
        modelId: 'm',
        anchorHash: 'a',
        promptHash: 'pr',
        tokensIn: 1,
        tokensOut: 1,
        retries: 0,
        wallClockMs: 1,
      ),
    );
  }

  @override
  Future<EmbeddingResult> embed(String text) async => EmbeddingResult(
        vec: _v768(seed: text.length),
        modelIdentity: const EmbeddingModelIdentity(
          providerId: 'p',
          modelId: 'nomic-embed-text',
          dims: _bootstrapDims,
          normalized: true,
        ),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
