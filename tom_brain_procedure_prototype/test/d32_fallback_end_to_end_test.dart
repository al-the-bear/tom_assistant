// D.32 — fallback events emitted + idea-push triggered exactly at threshold.
//
// Plan step D.32 (the dedicated test step for "D.8 — Fallback executor (v0)"):
// "Tests: fallback events emitted; idea-push triggered exactly at threshold."
//
// D.30 unit-tested the `ProcedureFallback` emission against a synthetic sink,
// and D.31 unit-tested the `SustainedFallbackMonitor` window by driving
// `record` directly. D.32 closes the loop: it wires a real `FallbackExecutor`
// to a real `SustainedFallbackMonitor` through `monitor.asSink` and proves the
// two halves *together*, end-to-end —
//
//   1. **fallback events emitted** — every fallback-class run-failure that
//      walks the chain surfaces exactly one `ProcedureFallback` out of the
//      executor (a tee sink captures them); successes and environmental
//      failures emit nothing;
//   2. **idea-push triggered exactly at threshold** — those emitted events,
//      fed into the monitor by `asSink`, push exactly one
//      `AutomationIdea: revise procedure X` onto `automation_ideas` on the
//      threshold-th fallback within the window, never before and never twice.
//
// The executor's *what-a-version-does* stays a synthetic `VersionAttempt`
// (engine-independent, as in D.29/D.30); a deterministic advancing clock stamps
// each emitted event so the monitor's 24 h window is exercised without a wall
// clock. The `automation_ideas` membership is read through a membership-modeling
// memory double, the same shape the D.28 and D.31 suites use.

import 'dart:async';

import 'package:tom_brain_memory/tom_brain_memory.dart'
    show
        EdgeType,
        NodeDraft,
        ProcedureRunRef,
        Scope,
        StackApi,
        StackEntry,
        TomBrainMemoryClient,
        TrailEntry,
        TrailOutcome;
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, TrailId;
import 'package:test/test.dart';

/// A typed failure carrying an explicit [failureKind] (matches the D.30 fake).
final class _ClassifiedError implements Exception, ClassifiedFailure {
  const _ClassifiedError(this.failureKind);
  @override
  final String failureKind;
}

/// A failure caused by the environment (substrate-down, network, billing).
final class _EnvError implements Exception, EnvironmentalFailure {
  const _EnvError();
}

LoadedProcedure _loaded(String id, int version) => LoadedProcedure(
      ref: ProcedureRef.system('/$id.v$version.dart'),
      header: ProcedureHeader(
        id: id,
        version: version,
        summary: 'summary of $id v$version',
        successCriterion: 'it works',
        budget: ProcedureBudget(const {'wallClockMs': 1000}),
      ),
      source: '/// @procedure\n/// id: $id\n/// version: $version\n// body',
    );

/// The prototype's singleton chain: one version `[v1]` per id.
ProcedureResolver _singletonResolver(String id) =>
    ProcedureResolver([_loaded(id, 1)]);

void main() {
  group('D.32 — fallback events emitted + idea-push exactly at threshold', () {
    late _RecordingMemory memory;
    late SustainedFallbackMonitor monitor;
    late List<ProcedureFallback> emitted;
    late FallbackEventSink tee;
    late DateTime base;
    late int emitCount;

    setUp(() {
      memory = _RecordingMemory();
      monitor = SustainedFallbackMonitor(memory);
      emitted = <ProcedureFallback>[];
      base = DateTime.utc(2026, 6, 2, 9);
      emitCount = 0;
      // A tee sink: capture every emitted event (half 1) AND feed the monitor
      // (half 2). This is exactly the composition-root wiring the prototype
      // will use, with an event-bus tap added.
      final toMonitor = monitor.asSink;
      tee = (event) {
        emitted.add(event);
        toMonitor(event);
      };
    });

    /// A clock that stamps each emitted event 1 h after the previous one, so a
    /// burst of fallbacks lands inside the monitor's 24 h window in a stable,
    /// strictly increasing order.
    DateTime advancingClock() => base.add(Duration(hours: emitCount++));

    /// An executor over the singleton `[v1]` chain for [id], wired to the tee
    /// sink and the deterministic clock.
    FallbackExecutor executorFor(String id) => FallbackExecutor(
          _singletonResolver(id),
          onFallback: tee,
          clock: advancingClock,
        );

    /// Runs [id] once with an attempt that throws [error]; returns the outcome.
    Future<FallbackOutcome<String>> runOnce(String id, Object error) {
      return executorFor(id).run<String>(
        procedureId: id,
        attempt: (_) async => throw error,
      );
    }

    /// The `AutomationIdea` nodes currently on `automation_ideas`.
    Future<List<NodeDraft>> ideaNodes() async {
      final entries =
          await memory.stacks.peek(automationIdeasStackName, k: 1000);
      return entries.map((e) {
        final node = memory.nodeFor(e.nodeId);
        expect(node.typeName, automationIdeaNodeType);
        return node;
      }).toList();
    }

    test('a fallback-class run emits exactly one surfaced ProcedureFallback',
        () async {
      final outcome = await runOnce(
        'answer_with_memory_v1',
        const _ClassifiedError('procedure.contract.violation'),
      );
      await pumpEventQueue();

      // Half 1: the executor emitted one event for the chain walk.
      expect(outcome.isSuccess, isFalse);
      expect(emitted, hasLength(1));
      final event = emitted.single;
      expect(event.procedureId, 'answer_with_memory_v1');
      expect(event.fromVersion, 1);
      expect(event.toVersion, isNull, reason: 'singleton chain surfaces');
      expect(event.surfaced, isTrue);
      expect(event.trigger, FallbackTrigger.contractViolation);

      // Below threshold ⇒ no idea yet.
      expect(await ideaNodes(), isEmpty);
    });

    test('no idea is pushed before the threshold (2 fallback-class runs)',
        () async {
      await runOnce('proc_a', const _ClassifiedError('procedure.runtime.crash'));
      await runOnce('proc_a', const _ClassifiedError('procedure.runtime.crash'));
      await pumpEventQueue();

      // Half 1: two events emitted.
      expect(emitted, hasLength(2));
      // Half 2: still below threshold ⇒ nothing pushed.
      expect(await ideaNodes(), isEmpty);
      expect(memory.pushedStacks, isEmpty);
    });

    test('the idea is pushed exactly at the threshold (the 3rd fallback)',
        () async {
      await runOnce('proc_a', const _ClassifiedError('procedure.runtime.crash'));
      await pumpEventQueue();
      expect(await ideaNodes(), isEmpty, reason: '1st: below threshold');

      await runOnce('proc_a', const _ClassifiedError('procedure.runtime.crash'));
      await pumpEventQueue();
      expect(await ideaNodes(), isEmpty, reason: '2nd: below threshold');

      // The 3rd fallback-class failure crosses the threshold end-to-end.
      await runOnce(
          'proc_a', const _ClassifiedError('procedure.critique.rejected'));
      await pumpEventQueue();

      // Half 1: three events emitted (one per chain walk).
      expect(emitted, hasLength(3));
      // Half 2: exactly one idea pushed, exactly once, at the 3rd edge.
      final ideas = await ideaNodes();
      expect(ideas, hasLength(1));
      expect(ideas.single.values['description'], 'revise procedure proc_a');
      expect(memory.pushedStacks, <String>[automationIdeasStackName]);
    });

    test('further fallbacks in the same episode do not re-push the idea',
        () async {
      // Five fallback-class runs in one 24 h burst: fires once on the 3rd, then
      // the 4th and 5th must not re-push (the "exactly once" half of D.32).
      for (var i = 0; i < 5; i++) {
        await runOnce(
            'proc_a', const _ClassifiedError('procedure.runtime.crash'));
        await pumpEventQueue();
      }

      expect(emitted, hasLength(5));
      expect(await ideaNodes(), hasLength(1));
      expect(memory.pushedStacks, <String>[automationIdeasStackName]);
    });

    test('a successful run emits no event and does not count toward threshold',
        () async {
      // Two real failures, with a success interleaved that must be invisible to
      // both the event stream and the window.
      await runOnce('proc_a', const _ClassifiedError('procedure.runtime.crash'));
      await executorFor('proc_a')
          .run<String>(procedureId: 'proc_a', attempt: (_) async => 'ok');
      await runOnce('proc_a', const _ClassifiedError('procedure.runtime.crash'));
      await pumpEventQueue();

      // Only the two failures emitted events; the success emitted nothing, so
      // the window holds two edges ⇒ below threshold ⇒ no idea.
      expect(emitted, hasLength(2));
      expect(await ideaNodes(), isEmpty);
    });

    test('environmental failures emit nothing and never reach the threshold',
        () async {
      // Three environmental failures: a newer version cannot fix the
      // environment, so none emit a ProcedureFallback and none count.
      for (var i = 0; i < 3; i++) {
        await runOnce('proc_a', const _EnvError());
        await pumpEventQueue();
      }

      expect(emitted, isEmpty);
      expect(await ideaNodes(), isEmpty);
      expect(memory.pushedStacks, isEmpty);
    });

    test('distinct procedure ids cross their thresholds independently',
        () async {
      // Interleave proc_a and proc_b; each fires only at its own 3rd fallback.
      for (var i = 0; i < 3; i++) {
        await runOnce(
            'proc_a', const _ClassifiedError('procedure.runtime.crash'));
        await runOnce(
            'proc_b', const _ClassifiedError('procedure.deadline.exceeded'));
        await pumpEventQueue();
      }

      // Half 1: six events (three per id).
      expect(emitted, hasLength(6));
      // Half 2: two distinct ideas, one per id.
      final ideas = await ideaNodes();
      expect(ideas, hasLength(2));
      expect(
        ideas.map((n) => n.values['description']).toSet(),
        <String>{'revise procedure proc_a', 'revise procedure proc_b'},
      );
    });
  });
}

/// A `TomBrainMemoryClient` double that records every persisted node and models
/// real `automation_ideas` membership, so a test can read the pushed
/// `AutomationIdea` nodes. Only the surface D.32 exercises is implemented; the
/// rest routes through `noSuchMethod`. (Same shape as the D.31 suite's double —
/// each test file owns its own membership double, per the D.28 convention.)
class _RecordingMemory implements TomBrainMemoryClient {
  _RecordingMemory() : _stacks = _MembershipStacks();

  final _MembershipStacks _stacks;
  final Map<NodeId, NodeDraft> _nodes = <NodeId, NodeDraft>{};

  /// The stack names every `push` targeted, in call order.
  List<String> get pushedStacks => _stacks.pushedStacks;

  /// The persisted node behind [id].
  NodeDraft nodeFor(NodeId id) {
    final node = _nodes[id];
    expect(node, isNotNull, reason: 'no persisted node for $id');
    return node!;
  }

  @override
  Future<NodeId> persist(NodeDraft draft, {required Scope scope}) async {
    final id = NodeId.generate();
    _nodes[id] = draft;
    return id;
  }

  @override
  StackApi get stacks => _stacks;

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

/// A `StackApi` double modelling real membership: [push] appends an entry and
/// records the target stack name; [peek] returns entries in insertion order.
class _MembershipStacks implements StackApi {
  final Map<String, List<StackEntry>> _entries = <String, List<StackEntry>>{};
  final List<String> pushedStacks = <String>[];

  @override
  Future<StackEntryId> push(
    String name,
    NodeId entry, {
    double priority = 0.0,
    Map<String, Object?>? attrs,
    Scope? scope,
  }) async {
    final id = StackEntryId.generate();
    pushedStacks.add(name);
    (_entries[name] ??= <StackEntry>[]).add(
      StackEntry(
        id: id,
        stackName: name,
        nodeId: entry,
        priority: priority,
        pushedAt: DateTime.now(),
        attrs: attrs ?? const <String, Object?>{},
      ),
    );
    return id;
  }

  @override
  Future<List<StackEntry>> peek(String name, {int k = 16}) async {
    final list = _entries[name] ?? const <StackEntry>[];
    return list.take(k).toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
