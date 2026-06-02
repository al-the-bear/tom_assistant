// D.26 — `inflight` integration (dispatcher half) tests.
//
// Plan step D.26: "On every run start, push a `ProcedureRun` node to
// `inflight` via the memory client." Two layers are covered:
//
//   1. `RunRegistry.recordStart` in isolation — it persists a
//      `status: running` `ProcedureRun` marker and pushes its id onto the
//      `inflight` bootstrap stack, returning the marker id, with the right
//      node shape, scope, and injected start timestamp.
//   2. `RunCoordinator` wiring — a coordinator handed a registry pushes the
//      marker the moment a run occupies a slot (foreground and background),
//      assigns and threads a run id into the `PreemptionController` slot
//      events, and pushes nothing for an opaque body (no procedure id) or when
//      no registry is wired. Concurrent foreground + background appear as two
//      distinct `inflight` entries (the D.28 invariant, proved on the push
//      side here).
//
// Removal from `inflight` / push to `recent_runs` at run end is D.27 and is
// asserted there. The wiring tests below hold their runs live (a gated body)
// so every assertion observes the start-side push in isolation, before the
// D.27 run-end close-out can fire.

import 'dart:async';

import 'package:tom_brain_memory/tom_brain_memory.dart'
    show
        EdgeType,
        NodeDraft,
        ProcedureRunRef,
        Scope,
        StackApi,
        TomBrainMemoryClient,
        TrailEntry,
        TrailOutcome;
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart'
    show
        PreemptionEvent,
        RunCoordinator,
        RunRegistration,
        RunRegistry,
        RunSlot,
        RunSlotEntered,
        inflightStackName,
        procedureRunNodeType;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, TrailId;
import 'package:test/test.dart';

void main() {
  group('D.26 — RunRegistry.recordStart', () {
    late _StubStacks stacks;
    late _StubMemory memory;
    final frozenNow = DateTime.utc(2026, 6, 2, 9, 30);

    setUp(() {
      stacks = _StubStacks();
      memory = _StubMemory(stacks);
    });

    RunRegistry buildRegistry() => RunRegistry(memory, now: () => frozenNow);

    test('persists a running ProcedureRun marker and returns its id',
        () async {
      final registry = buildRegistry();

      final markerId = await registry.recordStart(
        const RunRegistration(
          runId: 'r_1',
          procedureId: 'answer_with_memory_v1',
          slot: RunSlot.foreground,
        ),
      );

      expect(memory.persisted, hasLength(1));
      final draft = memory.persisted.single;
      expect(draft.typeName, procedureRunNodeType);
      expect(draft.values['status'], 'running');
      expect(draft.values['procedureId'], 'answer_with_memory_v1');
      expect(draft.values['runId'], 'r_1');
      expect(draft.values['version'], 1);
      expect(draft.values['slot'], 'foreground');
      expect(draft.values['startedAt'], frozenNow.toIso8601String());
      // The returned id is the persisted node's id.
      expect(markerId, memory.persistedIds.single);
    });

    test('pushes the marker onto the inflight stack with an attributing scope',
        () async {
      final registry = buildRegistry();

      final markerId = await registry.recordStart(
        const RunRegistration(
          runId: 'r_2',
          procedureId: 'answer_with_memory_v1',
          version: 3,
          slot: RunSlot.background,
        ),
      );

      expect(stacks.pushes, hasLength(1));
      final push = stacks.pushes.single;
      expect(push.stackName, inflightStackName);
      expect(push.nodeId, markerId);
      expect(push.scope!.producer, 'dispatcher:answer_with_memory_v1:r_2');
      expect(push.scope!.runId, 'r_2');
      // version flowed through to the node.
      expect(memory.persisted.single.values['version'], 3);
    });

    test('records the parent run id when supplied', () async {
      final registry = buildRegistry();

      await registry.recordStart(
        const RunRegistration(
          runId: 'child',
          procedureId: 'p',
          slot: RunSlot.foreground,
          parentRunId: 'parent',
        ),
      );

      expect(memory.persisted.single.values['parentRunId'], 'parent');
    });

    test('omits parentRunId for a top-level run', () async {
      final registry = buildRegistry();

      await registry.recordStart(
        const RunRegistration(
          runId: 'top',
          procedureId: 'p',
          slot: RunSlot.foreground,
        ),
      );

      expect(memory.persisted.single.values.containsKey('parentRunId'), isFalse);
    });
  });

  group('D.26 — RunCoordinator wiring', () {
    late _StubStacks stacks;
    late _StubMemory memory;

    setUp(() {
      stacks = _StubStacks();
      memory = _StubMemory(stacks);
    });

    test('a foreground run with a procedure id pushes one inflight marker',
        () async {
      final coordinator = RunCoordinator(runRegistry: RunRegistry(memory));
      // Hold the run live so the assertion observes the start-side push in
      // isolation, before the D.27 run-end close-out can fire.
      final gate = Completer<int>();

      final run = coordinator.submitForeground<int>(
        () => gate.future,
        procedureId: 'answer_with_memory_v1',
      );
      await pumpEventQueue();

      expect(stacks.pushes, hasLength(1));
      expect(stacks.pushes.single.stackName, inflightStackName);
      final draft = memory.persisted.single;
      expect(draft.values['status'], 'running');
      expect(draft.values['procedureId'], 'answer_with_memory_v1');
      expect(draft.values['slot'], 'foreground');

      gate.complete(0);
      await run;
    });

    test('a background run with a procedure id pushes one inflight marker',
        () async {
      final coordinator = RunCoordinator(runRegistry: RunRegistry(memory));
      final gate = Completer<int>();

      final run = coordinator.submitBackground<int>(
        () => gate.future,
        procedureId: 'free_time_scheduler_v1',
      );
      await pumpEventQueue();

      expect(stacks.pushes, hasLength(1));
      expect(memory.persisted.single.values['slot'], 'background');

      gate.complete(0);
      await run;
    });

    test('no registry wired ⇒ no inflight push (run id still minted)',
        () async {
      final events = <PreemptionEvent>[];
      final coordinator = RunCoordinator();
      coordinator.preemptionEvents().listen(events.add);

      await coordinator.submitForeground<int>(
        () async => 1,
        procedureId: 'answer_with_memory_v1',
      );
      await pumpEventQueue();

      // No memory client involved, so nothing pushed — but the run id is
      // assigned and threaded into the slot events.
      final entered = events.whereType<RunSlotEntered>().single;
      expect(entered.runId, isNotNull);
      expect(entered.runId, startsWith('disp-foreground-run-'));
    });

    test('an opaque body (no procedure id) is not pushed to inflight',
        () async {
      final coordinator = RunCoordinator(runRegistry: RunRegistry(memory));

      await coordinator.submitForeground<int>(() async => 1);
      await pumpEventQueue();

      expect(stacks.pushes, isEmpty);
      expect(memory.persisted, isEmpty);
    });

    test('the minted run id is threaded into the slot enter event', () async {
      final events = <PreemptionEvent>[];
      final coordinator = RunCoordinator(runRegistry: RunRegistry(memory));
      coordinator.preemptionEvents().listen(events.add);
      final gate = Completer<int>();

      final run = coordinator.submitForeground<int>(
        () => gate.future,
        procedureId: 'p',
      );
      await pumpEventQueue();

      final entered = events.whereType<RunSlotEntered>().single;
      expect(entered.runId, memory.persisted.single.values['runId']);

      gate.complete(0);
      await run;
    });

    test('an injected RunIdMint overrides the default counter', () async {
      final events = <PreemptionEvent>[];
      final coordinator = RunCoordinator(
        runRegistry: RunRegistry(memory),
        runIdMint: (slot) => 'custom-${slot.name}',
      );
      coordinator.preemptionEvents().listen(events.add);
      final gate = Completer<int>();

      final run =
          coordinator.submitForeground<int>(() => gate.future, procedureId: 'p');
      await pumpEventQueue();

      expect(memory.persisted.single.values['runId'], 'custom-foreground');
      expect(
        events.whereType<RunSlotEntered>().single.runId,
        'custom-foreground',
      );

      gate.complete(0);
      await run;
    });

    test('concurrent foreground + background ⇒ two distinct inflight entries',
        () async {
      final coordinator = RunCoordinator(runRegistry: RunRegistry(memory));
      final fgGate = Completer<int>();
      final bgGate = Completer<int>();

      // Hold both runs live concurrently.
      final bg = coordinator.submitBackground<int>(
        () => bgGate.future,
        procedureId: 'free_time_scheduler_v1',
      );
      final fg = coordinator.submitForeground<int>(
        () => fgGate.future,
        procedureId: 'answer_with_memory_v1',
      );
      await pumpEventQueue();

      // Both markers are on inflight before either run finishes.
      expect(stacks.pushes, hasLength(2));
      final slots = memory.persisted
          .map((d) => d.values['slot'] as String)
          .toSet();
      expect(slots, <String>{'foreground', 'background'});
      // Two distinct marker node ids.
      expect(stacks.pushes.map((p) => p.nodeId).toSet(), hasLength(2));
      // Distinct run ids.
      expect(
        memory.persisted.map((d) => d.values['runId']).toSet(),
        hasLength(2),
      );

      fgGate.complete(0);
      bgGate.complete(0);
      await fg;
      await bg;
    });
  });
}

/// Stub `TomBrainMemoryClient` capturing persists; delegates stacks to a
/// [_StubStacks]. Only the surface D.26 touches is implemented; the rest goes
/// through `noSuchMethod`.
class _StubMemory implements TomBrainMemoryClient {
  _StubMemory(this._stacks);

  final _StubStacks _stacks;

  final List<NodeDraft> persisted = <NodeDraft>[];
  final List<NodeId> persistedIds = <NodeId>[];

  @override
  Future<NodeId> persist(NodeDraft draft, {required Scope scope}) async {
    persisted.add(draft);
    final id = NodeId.generate();
    persistedIds.add(id);
    return id;
  }

  @override
  StackApi get stacks => _stacks;

  // Unused by D.26 but part of the interface — keep them explicit so a
  // signature drift fails loudly rather than silently routing to noSuchMethod.
  @override
  Future<TrailId> openTrail(ProcedureRunRef run) async => TrailId.generate();

  @override
  Future<void> appendTrail(TrailId id, TrailEntry entry) async {}

  @override
  Future<void> closeTrail(TrailId id, TrailOutcome outcome) async {}

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

/// Stub `StackApi` capturing pushes. `push` returns a fresh `StackEntryId`.
///
/// `remove` is implemented (a no-op capture) so the coordinator's D.27 run-end
/// close-out — which fires after a gated run is released — does not route
/// through `noSuchMethod` and throw. The D.26 assertions all observe the start
/// side while the run is still live, so the run-end writes never perturb them.
class _StubStacks implements StackApi {
  final List<_Push> pushes = <_Push>[];

  @override
  Future<StackEntryId> push(
    String name,
    NodeId entry, {
    double priority = 0.0,
    Map<String, Object?>? attrs,
    Scope? scope,
  }) async {
    pushes.add(_Push(name, entry, scope));
    return StackEntryId.generate();
  }

  @override
  Future<void> remove(String name, NodeId entry) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _Push {
  _Push(this.stackName, this.nodeId, this.scope);

  final String stackName;
  final NodeId nodeId;
  final Scope? scope;
}
