// D.53 — API conformance tests.
//
// Plan step D.53 (verbatim): "**API conformance tests**: black-box test suite
// driving `Dispatcher` only. Drive synthetic `Access` objects (no real
// channel). Cover: success, foreground preempting background, hard deadline,
// fallback, queue overflow, unknown procedure kind, isolate-mode +
// in-process-mode parity."
//
// This suite is the black-box conformance the plan calls for: every scenario
// goes through `Dispatcher.accept(Access)` (PE-11) — the single entry point —
// and asserts the dispatcher-half *contract*, never reaching into a stage.
// Synthetic `Access` objects stand in for a real channel (no Phase-E wire).
//
// ── Two harness shapes, one entry point ─────────────────────────────────
//
// The seven scenarios split by what they pin:
//
//   * **success** and **isolate/in-process parity** pin the *real production
//     wiring*. They boot the whole process through `BrainProcessBoot.boot`
//     (the § 12 bring-up: substrate → memory → engine → dispatcher) and accept
//     an `Access` end-to-end against the shipped `answer_with_memory_v1` disk
//     procedure. Parity boots the same probe memory over both transports and
//     proves an identical `accept` yields an identical post-state across the
//     isolate boundary (the D.43-3 claim, now driven through the dispatcher).
//
//   * **queue overflow**, **hard deadline**, **foreground-preempts-background**,
//     and **fallback** pin the *coordinator / fallback contract* the boot route
//     composes. They wire a real `Dispatcher` over a real `RunCoordinator`
//     (with the relevant knob — queue depth, hard-step deadline + a manual
//     timer, the shared preemption state) or a real `FallbackExecutor`, behind
//     a route that schedules a *controllable* body. This is the same
//     `DispatchRoute` seam the d17 accept-and-route suite used (Q-D.14.1): it
//     drives the dispatcher's behaviour deterministically without sleeping for
//     a 65 s wall-clock deadline or hanging on a real substrate.
//
// ── What this suite makes explicit about the prototype boot route ───────
//
// The boot route (`brain_process_boot.dart` `_buildRoute`) schedules
// `engine.invoke(...).outcome` on the foreground slot. Two consequences shape
// the harness choices here, both flagged in
// `prototype_implementation_questions.md` (Q-D.53.1, Q-D.53.2):
//
//   1. The engine *captures* a procedure crash into a `ProcedureOutcome`
//      (`status: errored`) — it does not throw. So the boot route never sees a
//      thrown `ClassifiedFailure`, and therefore never steps the fallback
//      chain. The fallback scenario drives the `FallbackExecutor` directly
//      behind the dispatcher to pin its contract; that it is not on the boot
//      accept path is the substance of Q-D.53.1.
//   2. The boot route uses the coordinator's *default* hard-step deadline
//      (~65 s) with a real timer; `BrainProcessConfig` exposes no knob for it.
//      The hard-deadline scenario builds a coordinator with a small deadline +
//      a manual timer to fire the force-yield deterministically (Q-D.53.2).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        Access,
        DeliverCallback,
        EdgeId,
        InboundRequest,
        NodeId,
        OutboundChunk,
        Persona,
        ResolvedIdentity,
        Session,
        StackEntryId,
        TrailId,
        Vec,
        WriteBudget;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

// ─── Top-level probe memory + factory (top-level so it is sendable across
//     the isolate boundary; see d43_memory_provisioning_test.dart) ────────

/// The factory the isolate transport hands the spawned worker. Returns a fresh
/// [ProbeMemory] constructed *inside* the spawned isolate. Must be a top-level
/// function so its reference can cross the isolate boundary.
Future<TomBrainMemory> spawnProbeMemory() async => ProbeMemory();

/// A `TomBrainMemory` double that records every node it persists (by type and
/// draft) and reports those counts through [stats], so a run's post-state is
/// observable both directly (in-process) and across the isolate boundary
/// (`stats()` round-trip). Every other method is a benign no-op.
///
/// One fake serves both transports: in-process scenarios inspect [persisted]
/// directly; the isolate-parity scenario compares [stats] across the boundary.
final class ProbeMemory implements TomBrainMemory {
  final Map<String, int> _nodeCounts = <String, int>{};

  /// Every node draft persisted, in order, with its type. Only meaningful for
  /// the in-process transport (the isolate-side instance lives elsewhere).
  final List<({String typeName, Map<String, Object?> values})> persisted =
      <({String typeName, Map<String, Object?> values})>[];

  /// Captured `root` of the config the provisioner opened with.
  String? openedWithRoot;

  /// Number of times `close()` has been called.
  int closeCount = 0;

  /// The drafts persisted with [typeName], for in-process post-condition checks.
  Iterable<({String typeName, Map<String, Object?> values})> persistedOfType(
          String typeName) =>
      persisted.where((p) => p.typeName == typeName);

  @override
  Future<void> open(MemoryConfig config) async {
    openedWithRoot = config.root;
  }

  @override
  Future<void> close() async {
    closeCount++;
  }

  @override
  Future<void> checkpoint() async {}

  @override
  Future<MemoryStats> stats() async => MemoryStats(
        nodeCountByType: Map<String, int>.of(_nodeCounts),
        edgeCountByType: const <String, int>{},
        stackSizes: const <String, int>{},
        trailCount: 0,
        trailBytes: 0,
        recallLatencyPerMode: const <String, LatencyHistogram>{},
        classificationConfidenceHistogram: const <String, int>{},
        migrationProgress: const <String, double>{},
      );

  @override
  Future<NodeId> persist(NodeDraft draft, {required Scope scope}) async {
    _nodeCounts.update(draft.typeName, (n) => n + 1, ifAbsent: () => 1);
    persisted.add((
      typeName: draft.typeName,
      values: Map<String, Object?>.of(draft.values),
    ));
    return NodeId.generate();
  }

  @override
  Future<RecallResult> recall(RecallQuery query) async => const RecallResult(
        nodes: <Node>[],
        report: RecallReport(
          candidatesPerMode: <RecallMode, int>{},
          fusionStrategy: FusionStrategy.rrf,
          diversityStrategy: DiversityStrategy.mmr,
          elapsedMs: 0,
          embeddingsCallouts: 0,
          reRankInvoked: false,
          degraded: false,
        ),
      );

  // ─── Trail + run lifecycle: benign no-ops sufficient for the recorder ──

  @override
  Future<void> beginRun({
    required String runId,
    required WriteBudget budget,
  }) async {}

  @override
  Future<void> endRun(String runId) async {}

  @override
  Future<WriteBudget?> remainingBudget(String runId) async => null;

  @override
  Future<TrailId> openTrail(ProcedureRunRef run) async => TrailId.generate();

  @override
  Future<void> appendTrail(TrailId id, TrailEntry entry) async {}

  @override
  Future<void> closeTrail(TrailId id, TrailOutcome outcome) async {}

  @override
  Stream<TrailEntry> readTrail(TrailId id) => const Stream<TrailEntry>.empty();

  @override
  StackApi get stacks => _NoopStackApi();

  // ─── Every other surface is an unused no-op ────────────────────────────

  @override
  Future<Node?> get(NodeId id) async => null;

  @override
  Future<List<Node>> getMany(List<NodeId> ids) async => const <Node>[];

  @override
  Future<void> demote(NodeId id, DemotionReason reason) async {}

  @override
  Future<void> forget(NodeId id, ForgetReason reason) async {}

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
  Future<List<Edge>> edgesOf(
    NodeId id, {
    EdgeDirection direction = EdgeDirection.both,
    Set<EdgeType>? types,
  }) async =>
      const <Edge>[];

  @override
  Future<void> registerNodeType(NodeTypeDecl decl) async {}

  @override
  Future<List<NodeTypeDecl>> listNodeTypes() async => const <NodeTypeDecl>[];

  @override
  Future<NodeTypeDecl?> getNodeType(String typeName) async => null;

  @override
  Stream<Node> stream(StreamQuery query) => const Stream<Node>.empty();

  @override
  Future<ClassificationResult> classify(
    Vec embedding, {
    ClassificationTarget target = ClassificationTarget.nodeType,
  }) async =>
      const ClassificationResult.unknown();

  @override
  Future<void> updateCentroid(String forKey, Vec centroid) async {}

  @override
  Future<List<NodeId>> findUncertain({
    required String forKey,
    required double low,
    required double high,
    int limit = 200,
  }) async =>
      const <NodeId>[];

  @override
  MigrationApi get migrations => _NoopMigrationApi();

  @override
  Stream<MemoryEvent> events() => const Stream<MemoryEvent>.empty();

  @override
  Future<RecallResult> recallMulti(MultiRecallQuery query) async =>
      const RecallResult(
        nodes: <Node>[],
        report: RecallReport(
          candidatesPerMode: <RecallMode, int>{},
          fusionStrategy: FusionStrategy.rrf,
          diversityStrategy: DiversityStrategy.mmr,
          elapsedMs: 0,
        ),
      );

  @override
  MemoryProfileRegistry get profiles => _NoopProfileRegistry();

  @override
  String? get currentProfile => null;
}

class _NoopProfileRegistry implements MemoryProfileRegistry {
  @override
  Future<List<String>> list() async => const <String>[];

  @override
  Future<bool> exists(String name) async => false;

  @override
  Future<void> createProfile(String name) async {}

  @override
  Future<void> seedProfile(
    String name,
    List<NodeDraft> drafts, {
    required Scope scope,
  }) async {}

  @override
  Future<void> dropProfile(String name) async {}
}

class _NoopStackApi implements StackApi {
  @override
  Future<List<StackSummary>> list() async => const <StackSummary>[];

  @override
  Future<StackInfo?> info(String name) async => null;

  @override
  Future<void> create(StackDecl decl) async {}

  @override
  Future<void> updatePolicy(String name, StackPolicy policy) async {}

  @override
  Future<void> delete(String name) async {}

  @override
  Future<StackEntryId> push(
    String name,
    NodeId entry, {
    double priority = 0.0,
    Map<String, Object?>? attrs,
    Scope? scope,
  }) async =>
      StackEntryId.generate();

  @override
  Future<List<StackEntry>> peek(String name, {int k = 16}) async =>
      const <StackEntry>[];

  @override
  Future<StackEntry?> pop(String name) async => null;

  @override
  Future<void> update(
    String name,
    NodeId entry, {
    double? priority,
    StackEntryStatus? status,
    Map<String, Object?>? attrs,
  }) async {}

  @override
  Future<void> remove(String name, NodeId entry) async {}

  @override
  Stream<StackEntry> streamArchived(String name, {int? limit}) =>
      const Stream<StackEntry>.empty();

  @override
  Stream<StackEvent> events(String name) => const Stream<StackEvent>.empty();
}

class _NoopMigrationApi implements MigrationApi {
  @override
  Future<void> start(MigrationDecl decl) async {}

  @override
  Future<MigrationCursor?> cursor(String migrationId) async => null;

  @override
  Future<void> saveCursor(
    String migrationId,
    Map<String, Object?> position,
  ) async {}

  @override
  Future<MigrationStatus?> status(String migrationId) async => null;

  @override
  Future<List<MigrationStatus>> listInProgress() async =>
      const <MigrationStatus>[];
}

// ─── An answer-capturing substrate (stays in the main isolate) ──────────

class _AnsweringSubstrate implements TomBrainSubstrateClient {
  List<String> answerChunks = <String>['I have no notes on that yet.'];

  @override
  Future<void> open(SubstrateConfig config) async {}

  @override
  Future<void> close() async {}

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) {
    return Stream<LlmStreamEvent>.fromIterable(<LlmStreamEvent>[
      for (final chunk in answerChunks)
        LlmStreamChunk(callId: 'c', text: chunk),
      const LlmStreamCompleted(
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
      ),
    ]);
  }

  @override
  Future<EmbeddingResult> embed(String text) async => EmbeddingResult(
        vec: Vec(Float32List.fromList(<double>[0.0])),
        modelIdentity: const EmbeddingModelIdentity(
          providerId: 'p',
          modelId: 'm',
          dims: 1,
          normalized: true,
        ),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

// ─── A manual deadline-timer seam: captures the expiry callback and fires
//     it on demand, so the coordinator's hard-step deadline can be triggered
//     deterministically (mirrors the StepDeadline timer seam, C.36) ───────

class _ManualDeadline {
  void Function()? _onExpire;
  Timer? _timer;

  Timer arm(Duration duration, void Function() onExpire) {
    _onExpire = onExpire;
    // A benign placeholder timer the StepDeadline owns; it never fires on its
    // own (we fire the captured callback manually). Cancelled on `fire` so no
    // timer outlives the test.
    return _timer = Timer(const Duration(days: 1), () {});
  }

  /// Fires the captured expiry callback — the coordinator force-yields the run.
  void fire() {
    _timer?.cancel();
    _onExpire?.call();
  }
}

/// A run-failure that names its typed class so the fallback executor steps the
/// chain on it (a `procedure.contract.violation`, one of the four triggers).
final class _ContractViolation implements Exception, ClassifiedFailure {
  const _ContractViolation();

  @override
  String get failureKind => FallbackTrigger.contractViolation.failureKind;

  @override
  String toString() => '_ContractViolation';
}

// ─── Synthetic Access (no real channel) ─────────────────────────────────

Access _accessWith({
  String text = 'what is a quasar?',
  // A confident centroid hint names the procedure id to run (Q-E.50.1).
  String? kindHint = SystemProcedures.answerWithMemoryV1,
  DeliverCallback? deliver,
}) =>
    Access(
      envelope: InboundRequest(text: text, kindHint: kindHint),
      identity: ResolvedIdentity(principalId: 'p1'),
      session: Session(sessionId: 's1'),
      persona: Persona.assistant(),
      deliver: deliver ?? (chunk) => Stream<OutboundChunk>.value(chunk),
    );

BrainProcessConfig _bootConfig({
  required TomBrainMemoryClient memory,
  required TomBrainSubstrateClient substrate,
  required String memoryRoot,
}) =>
    BrainProcessConfig(
      substrate: substrate,
      memoryProvisioning: MemoryProvisioningConfig.inProcess(
        client: memory,
        memoryConfig: MemoryConfig.forTesting(root: memoryRoot),
      ),
    );

void main() {
  group('D.53-1 success — an accepted user_prompt runs end-to-end', () {
    test('accept runs answer_with_memory_v1 against the booted process',
        () async {
      final memory = ProbeMemory();
      final substrate = _AnsweringSubstrate()
        ..answerChunks = <String>['I have no notes on that yet.'];
      final booted = await BrainProcessBoot.boot(_bootConfig(
        memory: memory,
        substrate: substrate,
        memoryRoot: 'ztmp/d53_success',
      ));
      addTearDown(booted.shutdown);

      await booted.dispatcher.accept(_accessWith(text: 'what is a quasar?'));

      // Cold path (empty recall): the prompt is persisted as an Event and the
      // answer as a Conclusion — the run completed through the entry surface.
      final event = memory.persistedOfType('Event').single;
      expect(event.values['summary'], 'what is a quasar?');
      final conclusion = memory.persistedOfType('Conclusion').single;
      expect(conclusion.values['statement'], 'I have no notes on that yet.');
    });
  });

  group('D.53-2 unknown procedure-id hint — rejected loudly through accept',
      () {
    test('an unknown procedure-id hint raises UnknownProcedureHint through '
        'accept', () async {
      // The real resolveProcedureId pipeline behind the entry surface, with a
      // schedule stage that records whether it ever ran. A confident centroid
      // hint names a procedure id (Q-E.50.1); one naming no shipped procedure
      // is rejected loudly.
      final scheduled = <String>[];
      final classifier = InboundClassifier();
      final selector = ProcedureSelector();
      final dispatcher = Dispatcher(
        route: (access) async {
          final id = resolveProcedureId(access,
              classifier: classifier, selector: selector);
          scheduled.add(id);
        },
      );

      await expectLater(
        dispatcher.accept(_accessWith(kindHint: 'background_research')),
        throwsA(
          isA<UnknownProcedureHint>()
              .having(
                  (e) => e.procedureId, 'procedureId', 'background_research')
              .having((e) => e.knownProcedureIds, 'knownProcedureIds',
                  <String>[SystemProcedures.answerWithMemoryV1]),
        ),
        reason: 'the hint names no shipped procedure and the error propagates '
            'unchanged through accept (the D.14 failure-propagation contract)',
      );
      expect(scheduled, isEmpty,
          reason: 'rejection happens at routing, before scheduling');
    });
  });

  group('D.53-3 queue overflow — backpressure surfaces through accept', () {
    test('a third foreground submission overflows a depth-1 queue', () async {
      final coordinator = RunCoordinator(foregroundQueueDepth: 1);
      final gate = Completer<String>();
      final dispatcher = Dispatcher(
        route: (access) async {
          await coordinator.submitForeground(() => gate.future,
              procedureId: 'p');
        },
      );

      // First accept occupies the foreground slot (its body hangs on the gate);
      // the second is admitted into the depth-1 FIFO queue. Neither resolves
      // until the gate completes, so they are intentionally not awaited yet.
      final first = dispatcher.accept(_accessWith());
      final second = dispatcher.accept(_accessWith());

      // The third has nowhere to go: slot busy + queue full → overflow, which
      // surfaces as a thrown ForegroundQueueFull through accept.
      await expectLater(
        dispatcher.accept(_accessWith()),
        throwsA(isA<ForegroundQueueFull>()
            .having((e) => e.depth, 'depth', 1)),
        reason: 'the running run plus one queued run is the most a depth-1 '
            'coordinator holds',
      );

      // Release the gate so the running run and the queued successor drain.
      gate.complete('ok');
      await first;
      await second;
      expect(coordinator.isIdle, isTrue);
    });
  });

  group('D.53-4 hard deadline — a hung run is force-yielded through accept',
      () {
    test('the coordinator hard-step deadline surfaces RunDeadlineExceeded',
        () async {
      final manual = _ManualDeadline();
      final coordinator = RunCoordinator(
        hardStepDeadline: const Duration(milliseconds: 50),
        deadlineTimerFactory: manual.arm,
      );
      final neverCompletes = Completer<String>();
      final dispatcher = Dispatcher(
        route: (access) async {
          await coordinator.submitForeground(() => neverCompletes.future,
              procedureId: 'p');
        },
      );

      final accepted = dispatcher.accept(_accessWith());
      await pumpEventQueue();
      // The body never completes; fire the coordinator's deadline to force-yield
      // it (the backstop the engine's own per-step deadline failed to bound).
      manual.fire();

      await expectLater(
        accepted,
        throwsA(
          isA<RunDeadlineExceeded>()
              .having((e) => e.slot, 'slot', RunSlot.foreground)
              .having((e) => e.failureKind, 'failureKind',
                  'procedure.deadline.exceeded'),
        ),
        reason: 'a hung body is force-yielded and the typed deadline failure '
            'propagates through accept',
      );
      expect(coordinator.isIdle, isTrue,
          reason: 'force-yield frees the slot even though the body runs on');
    });
  });

  group('D.53-5 foreground preempting background', () {
    test('a foreground accept preempts a live background and resumes it',
        () async {
      final coordinator = RunCoordinator();
      final fgGate = Completer<String>();
      final dispatcher = Dispatcher(
        route: (access) async {
          await coordinator.submitForeground(() => fgGate.future,
              procedureId: 'fg');
        },
      );

      // A scheduler-driven background run, submitted on the same coordinator the
      // dispatcher schedules through (background never arrives via accept).
      final bgLive = Completer<void>();
      final fgArrived = Completer<void>();
      final bgResumed = Completer<void>();
      final background = coordinator.submitBackground(() async {
        bgLive.complete();
        // Run until the test signals a foreground has arrived, then act on the
        // cooperative checkpoint: if a foreground is waiting, park on resume.
        await fgArrived.future;
        final resume = coordinator.preemption.resumeSignal;
        if (coordinator.preemption.isForegroundWaiting && resume != null) {
          await resume;
          bgResumed.complete();
        }
        return 'bg-done';
      }, procedureId: 'bg');
      await bgLive.future;
      expect(coordinator.preemption.isForegroundWaiting, isFalse);

      // A foreground prompt arrives through accept while the background is live.
      final accepted = dispatcher.accept(_accessWith());
      await pumpEventQueue();
      expect(coordinator.preemption.isForegroundWaiting, isTrue,
          reason: 'admitting a foreground while a background run is live '
              'requests cooperative preemption');

      // The background reaches its checkpoint and parks; the foreground then
      // drains, which signals resume and releases the parked background.
      fgArrived.complete();
      await pumpEventQueue();
      fgGate.complete('fg-done');
      await accepted;

      expect(await background, 'bg-done');
      expect(bgResumed.isCompleted, isTrue,
          reason: 'the background resumed once the whole foreground drained');
      expect(coordinator.preemption.isForegroundWaiting, isFalse);
    });
  });

  group('D.53-6 fallback — a fallback-class failure surfaces an event', () {
    test('a contract violation emits one FallbackTried and surfaces',
        () async {
      // The real fallback chain for the shipped procedure (a v1-only singleton
      // in the prototype), driven behind the dispatcher's schedule stage.
      final resolver = await ProcedureResolver.fromStore(
        DiskProcedureStore(systemDir: Directory('scripts/system')),
      );
      final events = <FallbackTried>[];
      final executor = FallbackExecutor(
        resolver,
        onFallback: events.add,
        clock: () => DateTime.utc(2026, 6, 2),
      );
      final dispatcher = Dispatcher(
        route: (access) async {
          final outcome = await executor.run<String>(
            procedureId: SystemProcedures.answerWithMemoryV1,
            attempt: (version) async => throw const _ContractViolation(),
          );
          // No older version to step to: the failure surfaces through accept.
          outcome.valueOrThrow;
        },
      );

      await expectLater(
        dispatcher.accept(_accessWith()),
        throwsA(isA<_ContractViolation>()),
        reason: 'the v1-only chain has nowhere to step, so the fallback-class '
            'failure surfaces through accept',
      );

      expect(events, hasLength(1),
          reason: 'every fallback-class failure emits exactly one '
              'FallbackTried (def § 6)');
      final fallback = events.single;
      expect(fallback.procedureId, SystemProcedures.answerWithMemoryV1);
      expect(fallback.trigger, FallbackTrigger.contractViolation);
      expect(fallback.fromVersion, 1);
      expect(fallback.toVersion, isNull);
      expect(fallback.surfaced, isTrue,
          reason: 'the failing version is the oldest in the chain');
    });
  });

  group('D.53-7 isolate-mode + in-process-mode parity', () {
    test('an identical accept yields an identical post-state on both '
        'transports', () async {
      // In-process: the probe memory constructed in this isolate.
      final inProcMemory = ProbeMemory();
      final inProc = await BrainProcessBoot.boot(_bootConfig(
        memory: inProcMemory,
        substrate: _AnsweringSubstrate(),
        memoryRoot: 'ztmp/d53_parity_in',
      ));
      // Isolate: the same probe memory constructed in the spawned worker.
      final iso = await BrainProcessBoot.boot(BrainProcessConfig(
        substrate: _AnsweringSubstrate(),
        memoryProvisioning: MemoryProvisioningConfig.isolate(
          factory: spawnProbeMemory,
          memoryConfig: MemoryConfig.forTesting(root: 'ztmp/d53_parity_iso'),
        ),
      ));
      try {
        // The same synthetic prompt through each booted dispatcher.
        await inProc.dispatcher.accept(_accessWith(text: 'what is a quasar?'));
        await iso.dispatcher.accept(_accessWith(text: 'what is a quasar?'));

        // The post-state crosses the isolate boundary as a stats() round-trip;
        // the two transports must agree on what the run persisted.
        final inProcStats = await inProc.memory.client.stats();
        final isoStats = await iso.memory.client.stats();
        expect(inProcStats.nodeCountByType, isNotEmpty,
            reason: 'the run actually persisted nodes (not a vacuous match)');
        expect(isoStats.nodeCountByType, equals(inProcStats.nodeCountByType),
            reason: 'the dispatcher is indifferent to the memory transport '
                '(PE-10) — the D.53 parity claim');
        expect(inProc.memory.transport, MemoryTransport.inProcess);
        expect(iso.memory.transport, MemoryTransport.isolate);
      } finally {
        await inProc.shutdown();
        await iso.shutdown();
      }
    });
  });
}
