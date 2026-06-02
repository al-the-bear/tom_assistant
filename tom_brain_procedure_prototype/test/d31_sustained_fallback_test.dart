// D.31 — sustained-fallback `AutomationIdea` push tests.
//
// Plan step D.31: "Implement the `AutomationIdea: revise procedure X` push to
// the `automation_ideas` stack on sustained fallback (≥ 3 within 24 h for the
// same id)." Plan step D.32 (the dedicated test step) asks for "idea-push
// triggered exactly at threshold"; these tests pin that contract now, on the
// code D.31 builds.
//
// The `SustainedFallbackMonitor` is a windowed counter over the
// `ProcedureFallback` stream the `FallbackExecutor` emits (D.30). The suite
// drives it directly through `record`, controlling each event's `occurredAt`
// so the 24 h window is exercised deterministically without a wall clock, and
// reads the live membership of the `automation_ideas` bootstrap stack through
// a membership-modeling memory double (the same shape the D.28 suite uses for
// `inflight` / `recent_runs`).

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
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart'
    show
        FallbackTrigger,
        ProcedureFallback,
        SustainedFallbackMonitor,
        automationIdeaNodeType,
        automationIdeasStackName,
        defaultSustainedFallbackThreshold,
        defaultSustainedFallbackWindow;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, TrailId;
import 'package:test/test.dart';

void main() {
  group('D.31 — sustained-fallback AutomationIdea push', () {
    late _RecordingMemory memory;
    late DateTime t0;

    setUp(() {
      memory = _RecordingMemory();
      t0 = DateTime.utc(2026, 6, 2, 9);
    });

    /// A surfaced `ProcedureFallback` (the prototype's singleton-`[v1]` shape)
    /// for [procedureId] at [at], triggered by [trigger].
    ProcedureFallback fallback(
      String procedureId,
      DateTime at, {
      FallbackTrigger trigger = FallbackTrigger.runtimeCrash,
    }) =>
        ProcedureFallback(
          occurredAt: at,
          procedureId: procedureId,
          fromVersion: 1,
          toVersion: null,
          trigger: trigger,
        );

    /// The `AutomationIdea` nodes currently living on `automation_ideas`,
    /// read through the public `StackApi.peek` surface.
    Future<List<NodeDraft>> ideaNodes() async {
      final entries =
          await memory.stacks.peek(automationIdeasStackName, k: 1000);
      return entries.map((e) {
        final node = memory.nodeFor(e.nodeId);
        expect(node.typeName, automationIdeaNodeType);
        return node;
      }).toList();
    }

    test('the default threshold and window are the Plan D.31 values (3 / 24h)',
        () {
      final monitor = SustainedFallbackMonitor(memory);
      expect(monitor.threshold, defaultSustainedFallbackThreshold);
      expect(monitor.threshold, 3);
      expect(monitor.window, defaultSustainedFallbackWindow);
      expect(monitor.window, const Duration(hours: 24));
    });

    test('no idea is pushed before the threshold is reached', () async {
      final monitor = SustainedFallbackMonitor(memory);

      expect(await monitor.record(fallback('proc_a', t0)), isNull);
      expect(
        await monitor.record(fallback('proc_a', t0.add(const Duration(hours: 1)))),
        isNull,
      );

      expect(await ideaNodes(), isEmpty);
      expect(memory.pushedStacks, isEmpty);
    });

    test('the idea is pushed exactly at the threshold (the 3rd edge)',
        () async {
      final monitor = SustainedFallbackMonitor(memory);

      expect(await monitor.record(fallback('proc_a', t0)), isNull);
      expect(
        await monitor.record(fallback('proc_a', t0.add(const Duration(hours: 1)))),
        isNull,
      );
      // The 3rd edge within the window crosses the threshold and fires once.
      final ideaId =
          await monitor.record(fallback('proc_a', t0.add(const Duration(hours: 2))));
      expect(ideaId, isNotNull);

      final ideas = await ideaNodes();
      expect(ideas, hasLength(1));
      expect(ideas.single.values['description'], 'revise procedure proc_a');
      expect(
        ideas.single.values['motivation'],
        allOf(contains('proc_a'), contains('3 times'), contains('24h')),
      );
      // Pushed onto the automation_ideas stack exactly once.
      expect(memory.pushedStacks, <String>[automationIdeasStackName]);
    });

    test('does not re-push within the same sustained episode', () async {
      final monitor = SustainedFallbackMonitor(memory);

      NodeId? firstFire;
      for (var i = 0; i < 5; i++) {
        final id =
            await monitor.record(fallback('proc_a', t0.add(Duration(minutes: i * 10))));
        if (i == 2) {
          firstFire = id;
        } else {
          // Edges 1–2 are below threshold; edges 4–5 are still sustained but
          // the episode has already fired — none of them push.
          expect(id, isNull, reason: 'edge ${i + 1} must not push');
        }
      }
      expect(firstFire, isNotNull);
      expect(await ideaNodes(), hasLength(1));
    });

    test('re-arms after activity subsides and fires again on a fresh burst',
        () async {
      final monitor = SustainedFallbackMonitor(memory);

      // First burst: 3 edges within 24h ⇒ one idea.
      await monitor.record(fallback('proc_a', t0));
      await monitor.record(fallback('proc_a', t0.add(const Duration(hours: 1))));
      expect(
        await monitor.record(fallback('proc_a', t0.add(const Duration(hours: 2)))),
        isNotNull,
      );
      expect(await ideaNodes(), hasLength(1));

      // A lone edge far in the future: its window contains only itself, so the
      // count drops below threshold and the episode re-arms.
      final later = t0.add(const Duration(days: 5));
      expect(await monitor.record(fallback('proc_a', later)), isNull);

      // A fresh burst of 2 more within 24h of `later` ⇒ a second idea.
      await monitor.record(fallback('proc_a', later.add(const Duration(hours: 1))));
      expect(
        await monitor.record(fallback('proc_a', later.add(const Duration(hours: 2)))),
        isNotNull,
      );
      expect(await ideaNodes(), hasLength(2));
    });

    test('edges older than the window do not count toward the threshold',
        () async {
      final monitor = SustainedFallbackMonitor(memory);

      // Two edges, then a third more than 24h after the first: pruning drops
      // the first, leaving only two in the window ⇒ no push.
      await monitor.record(fallback('proc_a', t0));
      await monitor.record(fallback('proc_a', t0.add(const Duration(hours: 2))));
      expect(
        await monitor.record(fallback('proc_a', t0.add(const Duration(hours: 25)))),
        isNull,
      );
      expect(await ideaNodes(), isEmpty);

      // A fourth edge within 24h of edges 2 and 3 brings the in-window count
      // back to three ⇒ the push fires.
      expect(
        await monitor.record(fallback('proc_a', t0.add(const Duration(hours: 26)))),
        isNotNull,
      );
      expect(await ideaNodes(), hasLength(1));
    });

    test('separate procedure ids are counted independently', () async {
      final monitor = SustainedFallbackMonitor(memory);

      // Interleave two ids; each fires only at its own third edge.
      expect(await monitor.record(fallback('proc_a', t0)), isNull);
      expect(await monitor.record(fallback('proc_b', t0)), isNull);
      expect(
        await monitor.record(fallback('proc_a', t0.add(const Duration(hours: 1)))),
        isNull,
      );
      expect(
        await monitor.record(fallback('proc_b', t0.add(const Duration(hours: 1)))),
        isNull,
      );
      final aFire =
          await monitor.record(fallback('proc_a', t0.add(const Duration(hours: 2))));
      expect(aFire, isNotNull);
      expect(await ideaNodes(), hasLength(1));

      final bFire =
          await monitor.record(fallback('proc_b', t0.add(const Duration(hours: 2))));
      expect(bFire, isNotNull);

      final ideas = await ideaNodes();
      expect(ideas, hasLength(2));
      expect(
        ideas.map((n) => n.values['description']).toSet(),
        <String>{'revise procedure proc_a', 'revise procedure proc_b'},
      );
    });

    test('the motivation breakdown reflects the in-window trigger mix',
        () async {
      final monitor = SustainedFallbackMonitor(memory);

      await monitor.record(
          fallback('proc_a', t0, trigger: FallbackTrigger.runtimeCrash));
      await monitor.record(fallback('proc_a', t0.add(const Duration(hours: 1)),
          trigger: FallbackTrigger.runtimeCrash));
      await monitor.record(fallback('proc_a', t0.add(const Duration(hours: 2)),
          trigger: FallbackTrigger.deadlineExceeded));

      final motivation = (await ideaNodes()).single.values['motivation'] as String;
      expect(motivation, contains('procedure.runtime.crash×2'));
      expect(motivation, contains('procedure.deadline.exceeded×1'));
    });

    test('the push write carries a dispatcher producer and an idempotency key',
        () async {
      final monitor = SustainedFallbackMonitor(memory);

      await monitor.record(fallback('proc_a', t0));
      await monitor.record(fallback('proc_a', t0.add(const Duration(hours: 1))));
      await monitor.record(fallback('proc_a', t0.add(const Duration(hours: 2))));

      final persistScope = memory.persistedScopes.single;
      expect(persistScope.producer,
          'dispatcher:sustained-fallback:proc_a');
      expect(persistScope.idempotencyKey, isNotNull);
      expect(persistScope.idempotencyKey,
          contains('automation-idea:sustained-fallback:proc_a'));
    });

    test('a custom threshold and window are honoured', () async {
      final monitor = SustainedFallbackMonitor(
        memory,
        threshold: 2,
        window: const Duration(hours: 1),
      );

      expect(await monitor.record(fallback('proc_a', t0)), isNull);
      // The 2nd edge within the 1h window crosses the custom threshold.
      expect(
        await monitor.record(fallback('proc_a', t0.add(const Duration(minutes: 30)))),
        isNotNull,
      );
      expect(await ideaNodes(), hasLength(1));
      final motivation =
          (await ideaNodes()).single.values['motivation'] as String;
      expect(motivation, allOf(contains('2 times'), contains('1h')));
    });

    test('asSink feeds record fire-and-forget and still pushes the idea',
        () async {
      final monitor = SustainedFallbackMonitor(memory);
      final sink = monitor.asSink;

      sink(fallback('proc_a', t0));
      sink(fallback('proc_a', t0.add(const Duration(hours: 1))));
      sink(fallback('proc_a', t0.add(const Duration(hours: 2))));
      await pumpEventQueue();

      expect(await ideaNodes(), hasLength(1));
      expect(memory.pushedStacks, <String>[automationIdeasStackName]);
    });
  });
}

/// A `TomBrainMemoryClient` double that records every persisted node + its
/// scope and models real `automation_ideas` membership, so a test can read the
/// pushed `AutomationIdea` nodes and assert the write provenance. Only the
/// surface D.31 exercises is implemented; the rest routes through
/// `noSuchMethod`.
class _RecordingMemory implements TomBrainMemoryClient {
  _RecordingMemory() : _stacks = _MembershipStacks();

  final _MembershipStacks _stacks;
  final Map<NodeId, NodeDraft> _nodes = <NodeId, NodeDraft>{};

  /// The scopes every `persist` was issued under, in call order.
  final List<Scope> persistedScopes = <Scope>[];

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
    persistedScopes.add(scope);
    return id;
  }

  @override
  StackApi get stacks => _stacks;

  // Unused by D.31 but part of the interface — kept explicit so signature
  // drift fails loudly rather than silently routing to noSuchMethod.
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
/// records the target stack name; [peek] returns the current entries in
/// insertion order.
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
