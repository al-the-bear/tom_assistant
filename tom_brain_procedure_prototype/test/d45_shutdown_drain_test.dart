// D.45 — shutdown drain orchestration.
//
// Plan step D.45 (verbatim): "Implement shutdown orchestration: drain queues,
// finish current foreground (best-effort), close trails, close memory isolate
// cleanly."
//
// Two surfaces are proven:
//
//   1. `RunCoordinator.drain({timeout})` — the quiesce primitive. It flips
//      `isDraining` on (refusing new `submitForeground` / `submitBackground`
//      with `CoordinatorDraining`) and best-effort waits for the coordinator to
//      fall fully `isIdle`: the in-flight foreground run finishes, the FIFO
//      foreground queue drains to completion, and any live background run
//      finishes. A `timeout` bounds the wait so a genuinely-hung body cannot
//      hold shutdown hostage.
//   2. `BootedBrain.shutdown({drainTimeout})` — the boot-level orchestration.
//      A foreground run that is mid-flight when shutdown is called runs to
//      completion (its `RunRecorder` closes its trail) *before* memory is
//      disposed, so the exchange is persisted, not dropped.

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

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';

/// Yields the event loop so pending microtasks / timers settle before an
/// assertion observes state.
Future<void> _tick() => Future<void>.delayed(const Duration(milliseconds: 1));

void main() {
  group('D.45-1 RunCoordinator.drain quiesces the coordinator', () {
    test('drain waits for the in-flight foreground run, then resolves idle',
        () async {
      final coord = RunCoordinator();
      final gate = Completer<void>();
      final run = coord.submitForeground<String>(() async {
        await gate.future;
        return 'done';
      });
      expect(coord.hasForegroundRun, isTrue);

      var drained = false;
      final drainFuture = coord.drain().then((_) => drained = true);
      await _tick();
      // The live run still holds the slot, so the drain has not resolved.
      expect(drained, isFalse);
      expect(coord.isDraining, isTrue);

      gate.complete();
      expect(await run, 'done');
      await drainFuture;
      expect(drained, isTrue);
      expect(coord.isIdle, isTrue);
    });

    test('drain refuses new foreground/background work with CoordinatorDraining',
        () async {
      final coord = RunCoordinator();
      final gate = Completer<void>();
      coord.submitForeground<void>(() => gate.future);

      final drainFuture = coord.drain();
      expect(
        () => coord.submitForeground<void>(() async {}),
        throwsA(isA<CoordinatorDraining>()),
      );
      expect(
        () => coord.submitBackground<void>(() async {}),
        throwsA(isA<CoordinatorDraining>()),
      );

      gate.complete();
      await drainFuture;
      expect(coord.isIdle, isTrue);
    });

    test('drain lets the queued FIFO foreground runs finish in order', () async {
      final coord = RunCoordinator();
      final order = <String>[];
      final gate1 = Completer<void>();
      final r1 = coord.submitForeground<void>(() async {
        await gate1.future;
        order.add('r1');
      });
      // r2 is queued behind the running r1.
      final r2 = coord.submitForeground<void>(() async {
        order.add('r2');
      });
      expect(coord.foregroundQueueLength, 1);

      final drainFuture = coord.drain();
      gate1.complete();
      await Future.wait<void>(<Future<void>>[r1, r2, drainFuture]);

      // The whole chain — running plus queued — drained to completion.
      expect(order, <String>['r1', 'r2']);
      expect(coord.isIdle, isTrue);
    });

    test('drain waits for a live background run', () async {
      final coord = RunCoordinator();
      final gate = Completer<void>();
      final bg = coord.submitBackground<void>(() => gate.future);

      var drained = false;
      final drainFuture = coord.drain().then((_) => drained = true);
      await _tick();
      expect(drained, isFalse);

      gate.complete();
      await bg;
      await drainFuture;
      expect(drained, isTrue);
      expect(coord.isIdle, isTrue);
    });

    test('drain is best-effort: a timeout returns even while a body runs',
        () async {
      final coord = RunCoordinator();
      final gate = Completer<void>();
      coord.submitForeground<void>(() => gate.future);

      // The body never completes within the bound, so the drain gives up
      // waiting and returns rather than blocking shutdown forever.
      await coord.drain(timeout: const Duration(milliseconds: 30));
      expect(coord.hasForegroundRun, isTrue);
      expect(coord.isDraining, isTrue);

      // Release the body so the coordinator's hard-step-deadline timer is
      // cancelled cleanly (no lingering timer past the test).
      gate.complete();
      await _tick();
      expect(coord.isIdle, isTrue);
    });

    test('drain on an already-idle coordinator resolves immediately and is '
        'idempotent', () async {
      final coord = RunCoordinator();
      expect(coord.isIdle, isTrue);
      await coord.drain();
      await coord.drain();
      expect(coord.isDraining, isTrue);
      expect(coord.isIdle, isTrue);
    });
  });

  group('D.45-2 BootedBrain.shutdown drains before closing memory', () {
    late _DrainMemory memory;
    late _GatedSubstrate substrate;

    setUp(() {
      memory = _DrainMemory();
      substrate = _GatedSubstrate();
    });

    BrainProcessConfig config() => BrainProcessConfig(
          substrate: substrate,
          memoryProvisioning: MemoryProvisioningConfig.inProcess(
            client: memory,
            memoryConfig: MemoryConfig.forTesting(root: 'ztmp/d45_drain'),
          ),
        );

    Access userPrompt(String text) => Access(
          envelope: InboundRequest(text: text, kindHint: 'user_prompt'),
          identity: ResolvedIdentity(principalId: 'p1'),
          session: Session(sessionId: 's1'),
          persona: Persona.assistant(),
          deliver: (chunk) => Stream<OutboundChunk>.value(chunk),
        );

    test('an in-flight foreground run completes (trail closed, exchange '
        'persisted) before memory is disposed', () async {
      substrate.answerChunks = <String>['the answer'];
      final booted = await BrainProcessBoot.boot(config());

      // Admit a prompt. The route occupies the foreground slot synchronously
      // and the run parks at the gated `llm` step.
      final accept = booted.dispatcher.accept(userPrompt('a question?'));
      await _tick();
      expect(memory.persistedOfType('Conclusion'), isEmpty,
          reason: 'the run is parked at the gated llm step');

      // Shut down while the run is in-flight. The drain must wait for it.
      var shutdownDone = false;
      final shutdownFuture =
          booted.shutdown().then((_) => shutdownDone = true);
      await _tick();
      expect(shutdownDone, isFalse,
          reason: 'the drain is waiting for the in-flight foreground run');
      expect(memory.closeCount, 0, reason: 'memory is not closed mid-drain');

      // Release the run. It finishes, closing its trail and persisting the
      // exchange; only then does shutdown proceed to close memory.
      substrate.releaseGate();
      await accept;
      await shutdownFuture;

      expect(shutdownDone, isTrue);
      expect(memory.persistedOfType('Event').single.draft.values['summary'],
          'a question?');
      expect(memory.persistedOfType('Conclusion').single.draft.values['statement'],
          'the answer');
      expect(memory.allTrailsClosed, isTrue,
          reason: 'every opened trail was closed before memory disposal');
      expect(memory.closeCount, 1);
      expect(substrate.closeCount, 1);
    });

    test('shutdown is bounded: a hung run does not block shutdown past '
        'drainTimeout', () async {
      final booted = await BrainProcessBoot.boot(config());

      // Admit a prompt and leave the gate closed — the run hangs at `llm`.
      unawaited(booted.dispatcher.accept(userPrompt('hang?')));
      await _tick();

      // A short drain bound lets shutdown proceed despite the hung run.
      await booted.shutdown(drainTimeout: const Duration(milliseconds: 30));
      expect(memory.closeCount, 1);
      expect(substrate.closeCount, 1);

      // Release so the coordinator's deadline timer is cancelled cleanly.
      substrate.releaseGate();
      await _tick();
    });
  });
}

// ─── A gated `TomBrainSubstrateClient` ──────────────────────────────
//
// `completeStream` waits on a gate before emitting, so a test controls exactly
// when an in-flight `answer_with_memory_v1` run finishes its `llm` step.
class _GatedSubstrate implements TomBrainSubstrateClient {
  List<String> answerChunks = <String>['ok'];
  final Completer<void> _gate = Completer<void>();
  int closeCount = 0;

  void releaseGate() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<void> open(SubstrateConfig config) async {}

  @override
  Future<void> close() async {
    closeCount++;
  }

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) async* {
    await _gate.future;
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
class _DrainMemory implements TomBrainMemoryClient {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

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
  Future<void> open(MemoryConfig config) async {}

  @override
  Future<void> close() async {
    closeCount++;
  }

  @override
  StackApi get stacks => _stacks;

  @override
  Future<RecallResult> recall(RecallQuery query) async => recallResult;

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
