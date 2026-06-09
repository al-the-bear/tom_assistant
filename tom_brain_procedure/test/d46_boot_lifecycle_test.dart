// D.46 — boot lifecycle: sequence completion, mid-flight completion, and the
// typed startup error.
//
// Plan step D.46 (verbatim): "Tests: boot → submit → shutdown sequence
// completes; mid-flight foreground completion respected; memory-isolate crash
// surfaces as a typed startup error."
//
// Three contracts are proven through the public `BrainProcessBoot` surface:
//
//   1. boot → submit → shutdown completes (D.46-1): a process boots, an
//      accepted `Access` runs `answer_with_memory_v1` to completion against the
//      provisioned memory + substrate, and a graceful `shutdown()` then closes
//      memory and the substrate exactly once with every opened trail closed.
//   2. mid-flight foreground completion respected (D.46-2): a foreground run
//      that is still in flight when `shutdown()` is called is allowed to finish
//      — its trail closes and the exchange is persisted — *before* memory is
//      disposed. The drain (D.45) is what makes the boot lifecycle honour this;
//      D.46 pins it as a lifecycle guarantee.
//   3. memory-isolate crash → typed startup error (D.46-3): a crashing memory
//      factory (a real spawned worker isolate whose `open` throws) surfaces
//      from `boot` as `BrainStartupError(phase: BootPhase.memory, …)`, not a
//      bare transport exception — and the spawned worker is torn down, not
//      leaked. A failing substrate open surfaces as
//      `BrainStartupError(phase: BootPhase.substrate, …)` and never provisions
//      memory. Both prove the phase tagging and the failure hygiene.
//
// The procedure is loaded from the real `scripts/system/` disk store, so the
// boot wires the shipped `answer_with_memory_v1`, not an inline copy.

import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        Access,
        EdgeId,
        InboundRequest,
        NodeId,
        OutboundChunk,
        Persona,
        ResolvedIdentity,
        Session,
        StackEntryId,
        TrailId,
        Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

/// Yields the event loop so pending microtasks / timers settle before an
/// assertion observes state.
Future<void> _tick() => Future<void>.delayed(const Duration(milliseconds: 1));

/// Top-level memory factory whose construction crashes — the stand-in for a
/// "memory-isolate crash" during bring-up. Must be top-level so it can cross
/// the isolate boundary (closures captured in the spawning isolate cannot).
Future<TomBrainMemory> crashingMemoryFactory() async =>
    throw StateError('memory boot crashed inside the isolate');

void main() {
  late _LifecycleMemory memory;
  late _FakeSubstrate substrate;

  setUp(() {
    memory = _LifecycleMemory();
    substrate = _FakeSubstrate();
  });

  BrainProcessConfig inProcessConfig({SubstrateConfig? substrateConfig}) =>
      BrainProcessConfig(
        substrate: substrate,
        substrateConfig: substrateConfig,
        memoryProvisioning: MemoryProvisioningConfig.inProcess(
          client: memory,
          memoryConfig: MemoryConfig.forTesting(root: 'ztmp/d46_boot'),
        ),
      );

  Access userPrompt(String text) => Access(
        // The entry router is the only routable procedure after the route-flip
        // (§ 4.0.1); the two-phase route runs the answer branch it selects.
        envelope:
            InboundRequest(text: text, kindHint: SystemProcedures.promptAnalyzerV1),
        identity: ResolvedIdentity(principalId: 'p1'),
        session: Session(sessionId: 's1'),
        persona: Persona.assistant(),
        deliver: (chunk) => Stream<OutboundChunk>.value(chunk),
      );

  group('D.46-1 boot → submit → shutdown sequence completes', () {
    test('an accepted prompt runs end-to-end, then shutdown closes cleanly',
        () async {
      substrate.answerChunks = <String>['a complete answer.'];
      final booted = await BrainProcessBoot.boot(inProcessConfig());

      // Submit: the prompt runs `answer_with_memory_v1` to completion.
      await booted.dispatcher.accept(userPrompt('what is a pulsar?'));

      expect(memory.persistedOfType('Event').single.draft.values['summary'],
          'what is a pulsar?');
      expect(
          memory.persistedOfType('Conclusion').single.draft.values['statement'],
          'a complete answer.');

      // Shutdown: the whole sequence winds down with no leaked resources and
      // every opened trail closed.
      await booted.shutdown();
      expect(memory.closeCount, 1);
      expect(substrate.closeCount, 1);
      expect(memory.allTrailsClosed, isTrue,
          reason: 'every opened run trail was closed before memory disposal');
    });

    test('shutdown is idempotent across the completed sequence', () async {
      final booted = await BrainProcessBoot.boot(inProcessConfig());
      await booted.dispatcher.accept(userPrompt('hello?'));

      await booted.shutdown();
      await booted.shutdown();

      expect(memory.closeCount, 1);
      expect(substrate.closeCount, 1);
    });
  });

  group('D.46-2 mid-flight foreground completion is respected', () {
    test('a run in flight at shutdown finishes before memory is disposed',
        () async {
      substrate.answerChunks = <String>['mid-flight answer'];
      substrate.llmGate = Completer<void>();
      final booted = await BrainProcessBoot.boot(inProcessConfig());

      // Admit a prompt; the route occupies the foreground slot synchronously
      // and the run parks at the gated `llm` step.
      final accept = booted.dispatcher.accept(userPrompt('a slow question?'));
      await _tick();
      expect(memory.persistedOfType('Conclusion'), isEmpty,
          reason: 'the run is parked at the gated llm step');

      // Shut down while the run is mid-flight: the drain must wait for it, so
      // memory is not closed yet.
      var shutdownDone = false;
      final shutdownFuture = booted.shutdown().then((_) => shutdownDone = true);
      await _tick();
      expect(shutdownDone, isFalse,
          reason: 'shutdown is draining the in-flight foreground run');
      expect(memory.closeCount, 0,
          reason: 'memory is not disposed while a run is still in flight');

      // Release the run: it finishes (trail closed, exchange persisted), and
      // only then does shutdown proceed to close memory.
      substrate.releaseLlm();
      await accept;
      await shutdownFuture;

      expect(shutdownDone, isTrue);
      expect(memory.persistedOfType('Event').single.draft.values['summary'],
          'a slow question?');
      expect(
          memory.persistedOfType('Conclusion').single.draft.values['statement'],
          'mid-flight answer');
      expect(memory.allTrailsClosed, isTrue);
      expect(memory.closeCount, 1);
      expect(substrate.closeCount, 1);
    });
  });

  group('D.46-3 a bring-up crash surfaces as a typed startup error', () {
    test('a crashing memory factory → BrainStartupError(phase: memory)',
        () async {
      // Isolate transport with a real spawned worker; the factory throws when
      // boot opens the memory inside the isolate.
      final crashSubstrate = _FakeSubstrate();
      final config = BrainProcessConfig(
        substrate: crashSubstrate,
        memoryProvisioning: MemoryProvisioningConfig.isolate(
          factory: crashingMemoryFactory,
          memoryConfig: MemoryConfig.forTesting(root: 'ztmp/d46_crash'),
        ),
      );

      await expectLater(
        BrainProcessBoot.boot(config),
        throwsA(
          isA<BrainStartupError>()
              .having((e) => e.phase, 'phase', BootPhase.memory)
              .having((e) => e.cause, 'cause', isNotNull),
        ),
      );

      // Failure hygiene: no substrate was opened (none configured), and boot's
      // teardown still closed it. The spawned worker isolate was torn down by
      // the provisioner's open-failure path (not asserted here directly — the
      // test process not hanging on a leaked isolate is the observable proof).
      expect(crashSubstrate.closeCount, 1);
    });

    test('a failing substrate open → BrainStartupError(phase: substrate), '
        'memory never provisioned', () async {
      substrate.openError = StateError('substrate open failed');

      await expectLater(
        BrainProcessBoot.boot(
          inProcessConfig(substrateConfig: _minimalSubstrateConfig()),
        ),
        throwsA(
          isA<BrainStartupError>()
              .having((e) => e.phase, 'phase', BootPhase.substrate)
              .having((e) => e.cause, 'cause', isA<StateError>()),
        ),
      );

      // The substrate failed before memory provisioning was reached, so the
      // in-process memory client was never opened.
      expect(substrate.openCount, 1);
      expect(memory.openCount, 0);
    });
  });
}

/// A minimal valid-shape [SubstrateConfig] for the open pass-through / failure
/// tests. The fake substrate's `open` records the call (and optionally throws);
/// the config only needs to construct — it is never validated here.
SubstrateConfig _minimalSubstrateConfig() => const SubstrateConfig(
      providers: <ProviderProfile>[],
      roleRoutes: <String, List<RoleRouteEntryConfig>>{},
      embedding: EmbeddingChoice(
        providerId: 'p',
        model: 'm',
        dims: 1,
        normalize: true,
      ),
      webSearch: WebSearchConfig(
        defaultProvider: 'none',
        providers: <String, WebSearchProviderConfig>{},
      ),
      webFetch: WebFetchConfig(),
      mcpClient: McpClientConfigBlock(),
    );

// ─── A configurable `TomBrainSubstrateClient` ───────────────────────
//
// Records its open/close lifecycle, optionally throws from `open` (substrate
// bring-up failure), and optionally gates `completeStream` on a completer so a
// test controls exactly when an in-flight `answer_with_memory_v1` run finishes
// its `llm` step.
class _FakeSubstrate implements TomBrainSubstrateClient {
  List<String> answerChunks = <String>['ok'];

  /// When set, `open` throws this — the substrate bring-up failure path.
  Object? openError;

  /// When set, `completeStream` parks on this gate until [releaseLlm].
  Completer<void>? llmGate;

  int openCount = 0;
  int closeCount = 0;

  void releaseLlm() {
    final gate = llmGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  Future<void> open(SubstrateConfig config) async {
    openCount++;
    final err = openError;
    if (err != null) throw err;
  }

  @override
  Future<void> close() async {
    closeCount++;
  }

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) async* {
    final gate = llmGate;
    if (gate != null) await gate.future;
    for (final chunk in answerChunks) {
      yield LlmStreamChunk(callId: 'c', text: chunk);
    }
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

// ─── A stateful in-process `TomBrainMemoryClient` ───────────────────
//
// Records open/close, persists nodes/edges, models the run trails and the
// `interests` stack — enough for the recorder's trail + stack writes and for
// asserting the procedure's post-conditions and that every trail was closed.
class _LifecycleMemory implements TomBrainMemory {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

  int openCount = 0;
  int closeCount = 0;

  final List<({NodeId id, NodeDraft draft})> persisted =
      <({NodeId id, NodeDraft draft})>[];

  RecallResult recallResult = const RecallResult(
    nodes: <Node>[],
    report: RecallReport(
      candidatesPerMode: <RecallMode, int>{},
      fusionStrategy: FusionStrategy.rrf,
      diversityStrategy: DiversityStrategy.mmr,
      elapsedMs: 0,
    ),
  );

  bool get allTrailsClosed =>
      _trails.isNotEmpty && _closedTrails.length == _trails.length;

  Iterable<({NodeId id, NodeDraft draft})> persistedOfType(String typeName) =>
      persisted.where((p) => p.draft.typeName == typeName);

  @override
  Future<void> open(MemoryConfig config) async {
    openCount++;
  }

  @override
  Future<void> close() async {
    closeCount++;
  }

  @override
  StackApi get stacks => _stacks;

  @override
  Future<RecallResult> recall(RecallQuery query) async => recallResult;

  @override
  Future<RecallResult> recallMulti(MultiRecallQuery query) async => recallResult;

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
    persisted.add((id: id, draft: draft));
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
