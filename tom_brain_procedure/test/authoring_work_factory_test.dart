// authoring_work_factory — the § 5.3 "author" routing arm, end-to-end
// (`tom_brain_procedure_specification.md` § 10.5; `procedure_specification.md`
// § 8.3; def § 5.3).
//
// UB4 closes a concrete gap: `author_new_procedure_v1` persists a real
// `Procedure` memory node, but nothing routed an inbound to it, so no
// `Procedure` node was ever created in practice — the precondition OT2's
// run-header → node deep-link waits on. [authoringWorkFactory] is the
// `FreeTimeScheduler`'s § 5.3 *author* arm: a hot `automation_ideas` pick
// becomes an engine-backed `author_new_procedure_v1` run whose `intent` is the
// popped idea's salient text.
//
// This suite proves the full route end-to-end against the *shipped* procedure
// (loaded from the real `scripts/system/` store): one `FreeTimeScheduler.tick()`
// over a hot `automation_ideas` stack pops the seeded `AutomationIdea`, the
// author arm reads its `description` as the authoring intent, runs the loop
// through the engine, and a real `Procedure` node lands in memory — reachable
// via a `produced_by` edge (Module 2's deep-link precondition). A stub memory
// records every persist + edge; a role-scripted substrate supplies the canned
// author draft + critic verdict so the post-conditions are observable.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, TrailId, Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

import 'stub_prompt_resolver.dart';

/// Maps each `assist_user.author.*` prompt id to the authoring role its stage
/// runs under, so the role-keyed [_ScriptedSubstrate] distinguishes the author
/// / critic stages (mirrors `author_new_procedure_v1_test.dart`).
const Map<String, String> _authorRoleById = <String, String>{
  'assist_user.author.draft': 'procedure_author',
  'assist_user.author.fix_validation': 'procedure_author',
  'assist_user.author.critique': 'procedure_critic',
};

void main() {
  late _RoutingMemory memory;
  late _ScriptedSubstrate substrate;
  late MemoryBridge memoryBridge;
  late SubstrateBridge substrateBridge;
  late RunCoordinator coordinator;

  setUp(() {
    memory = _RoutingMemory();
    substrate = _ScriptedSubstrate();
    memoryBridge = MemoryBridge(memory);
    coordinator = RunCoordinator();
    final prompts = StubPromptResolver(
      roleForId: (id) => _authorRoleById[id] ?? 'assistant_to_user',
    );
    substrateBridge = SubstrateBridge(
      substrate,
      promptResolver: prompts.resolver,
      routeChainOf: prompts.routeChainOf,
    );
  });

  Future<ProcedureEngine> systemEngine() async {
    final store = DiskProcedureStore(systemDir: Directory('scripts/system'));
    final resolver = await ProcedureResolver.fromStore(store);
    return ProcedureEngine(
      resolver: resolver,
      memory: memory,
      memoryBridge: memoryBridge,
      substrateBridge: substrateBridge,
      now: () => DateTime.utc(2026, 6, 2, 12, 0, 0),
    );
  }

  /// The single `Procedure` node any authoring run persisted (the run recorder
  /// persists `ProcedureRun` nodes, never `Procedure`, so this is unambiguous).
  ({NodeId id, NodeDraft draft}) authoredProcedure() =>
      memory.persistedOfType('Procedure').single;

  group('UB4 — author arm routes automation_ideas → a Procedure node', () {
    test('a hot automation_ideas pick authors a real Procedure node reachable '
        'via produced_by', () async {
      substrate.authorDrafts = <String>[_validCandidate];
      substrate.criticVerdicts = <String>['accept'];

      // An AutomationIdea on the automation_ideas work stack: the brain's note
      // that some intent recurs often enough to deserve a procedure.
      memory.seedIdea(
        'automation_ideas',
        <String, Object?>{'description': 'greet the user by their stored name'},
        priority: 9,
      );

      final engine = await systemEngine();
      final scheduler = FreeTimeScheduler(
        coordinator: coordinator,
        memory: memory,
        workFactory: authoringWorkFactory(engine: engine, memory: memory),
      );

      // No Procedure exists before the route runs.
      expect(memory.persistedOfType('Procedure'), isEmpty);

      final tick = await scheduler.tick();

      // The author arm claimed the pick and submitted a background run.
      expect(tick.decision, FreeTimeDecision.scheduled);
      expect(tick.pick!.stackName, 'automation_ideas');
      await tick.runFuture;
      await pumpEventQueue();

      // The precondition OT2 waits on: a real Procedure node landed, carrying
      // the parsed header facts, reachable via a produced_by edge.
      final procedure = authoredProcedure();
      expect(procedure.draft.values['name'], 'greet_user_v1');
      expect(procedure.draft.values['status'], 'draft');

      final producedBy = memory.recordedEdges.where(
        (e) => e.type == EdgeType.producedBy && e.from == procedure.id,
      );
      expect(producedBy, hasLength(1));
    });

    test("the idea's description becomes the authoring intent", () async {
      substrate.authorDrafts = <String>[_validCandidate];
      substrate.criticVerdicts = <String>['accept'];
      memory.seedIdea(
        'automation_ideas',
        <String, Object?>{'description': 'summarise my unread mail each morning'},
        priority: 9,
      );

      final engine = await systemEngine();
      final scheduler = FreeTimeScheduler(
        coordinator: coordinator,
        memory: memory,
        workFactory: authoringWorkFactory(engine: engine, memory: memory),
      );

      final tick = await scheduler.tick();
      await tick.runFuture;
      await pumpEventQueue();

      // The author stage ran under an intent carrying the idea's text — the
      // scripted substrate records the drafting call's user text.
      expect(substrate.authorUserTexts.single,
          contains('summarise my unread mail each morning'));
    });

    test('an idea with no salient text still authors under a node-scoped '
        'intent (never crashes the cycle)', () async {
      substrate.authorDrafts = <String>[_validCandidate];
      substrate.criticVerdicts = <String>['accept'];
      // A textless idea node: the arm degrades to a traceable default intent.
      final ideaId = memory.seedIdea(
        'automation_ideas',
        <String, Object?>{'unrelated': 42},
        priority: 9,
      );

      final engine = await systemEngine();
      final scheduler = FreeTimeScheduler(
        coordinator: coordinator,
        memory: memory,
        workFactory: authoringWorkFactory(engine: engine, memory: memory),
      );

      final tick = await scheduler.tick();
      await tick.runFuture;
      await pumpEventQueue();

      // Authoring still ran and still produced a Procedure — the run is
      // traceable to its idea (the node id rides in the default intent).
      expect(memory.persistedOfType('Procedure'), hasLength(1));
      expect(substrate.authorUserTexts.single, contains(ideaId.value));
    });

    test('a pick from a non-authoring stack is declined (idle cycle)', () async {
      // The author arm claims automation_ideas only: a questions_open pick is
      // declined so the arm composes with the scheduler's other routing arms.
      memory.seedIdea(
        'questions_open',
        <String, Object?>{'statement': 'an open question'},
        priority: 9,
      );

      final engine = await systemEngine();
      final scheduler = FreeTimeScheduler(
        coordinator: coordinator,
        memory: memory,
        workFactory: authoringWorkFactory(engine: engine, memory: memory),
      );

      final tick = await scheduler.tick();

      expect(tick.decision, FreeTimeDecision.idle);
      expect(tick.didSchedule, isFalse);
      expect(memory.persistedOfType('Procedure'), isEmpty);
    });
  });
}

// ── The canned candidate source the procedure_author role "writes" ──────────
//
// A minimal, valid candidate the validate chain passes clean. Its header is the
// single source of truth the authoring loop reads name/summary/requires from.
const String _validCandidate = '''
/// @procedure
/// id: greet_user_v1
/// version: 1
/// summary: Greets the user by their stored name.
/// successCriterion: returns a succeeded ProcedureResult naming the user.
/// budget: { wallClockMs: 5000 }
/// requires: [ recall, note ]
import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure/src/api/procedure_result.dart';
import 'package:tom_brain_procedure/src/bridges/memory_bridge.dart';
import 'package:tom_brain_procedure/src/primitives_native/primitives_native.dart';

Future<ProcedureResult> run(ProcedureInputs inputs) async {
  await mem.recall('user name', modes: ['bm25'], k: 1);
  note('progress', {});
  return ProcedureResult.succeeded();
}
''';

// ── A persist + edge capturing `TomBrainMemory` with a schedulable stack API ─
//
// Combines the author suite's capturing memory (records every persist + edge,
// models trails, assigns fresh ids) with a priority-ordered stack API the
// `FreeTimeScheduler` can `list` / `pop`. `seedIdea` places an `AutomationIdea`
// node into the store *and* onto a work stack, so a `tick()` pops the entry and
// the author arm resolves its node text through `get`.
class _RoutingMemory implements TomBrainMemory {
  final _RoutingStacks _stacks = _RoutingStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

  final List<({NodeId id, NodeDraft draft})> persisted =
      <({NodeId id, NodeDraft draft})>[];

  final List<({NodeId from, EdgeType type, NodeId to})> recordedEdges =
      <({NodeId from, EdgeType type, NodeId to})>[];

  final RecallResult recallResult = const RecallResult(
    nodes: <Node>[],
    report: RecallReport(
      candidatesPerMode: <RecallMode, int>{},
      fusionStrategy: FusionStrategy.rrf,
      diversityStrategy: DiversityStrategy.mmr,
      elapsedMs: 0,
    ),
  );

  /// Places an `AutomationIdea` node carrying [values] into the store and onto
  /// [stackName] at [priority], returning its node id.
  NodeId seedIdea(
    String stackName,
    Map<String, Object?> values, {
    double priority = 0.0,
  }) {
    final id = NodeId.generate();
    _nodes[id] = Node(
      id: id,
      typeName: 'AutomationIdea',
      values: Map<String, Object?>.of(values),
      createdAt: DateTime.now().toUtc(),
    );
    _stacks.seed(stackName, id, priority);
    return id;
  }

  Iterable<({NodeId id, NodeDraft draft})> persistedOfType(String typeName) =>
      persisted.where((p) => p.draft.typeName == typeName);

  @override
  StackApi get stacks => _stacks;

  @override
  Future<RecallResult> recall(RecallQuery query) async => recallResult;

  @override
  Future<RecallResult> recallMulti(MultiRecallQuery query) async =>
      recallResult;

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
  }) async {
    recordedEdges.add((from: from, type: type, to: to));
    return EdgeId.generate();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// A `StackApi` double that models a priority stack: `list` reports size + top
/// priority per stack, `peek` returns entries highest-priority first, and `pop`
/// removes and returns the highest-priority entry.
class _RoutingStacks implements StackApi {
  final Map<String, List<StackEntry>> _entries = <String, List<StackEntry>>{};

  /// Test seam: appends an entry without going through the budget-charged push.
  void seed(String name, NodeId node, double priority) {
    (_entries[name] ??= <StackEntry>[]).add(
      StackEntry(
        id: StackEntryId.generate(),
        stackName: name,
        nodeId: node,
        priority: priority,
        pushedAt: DateTime.now().toUtc(),
      ),
    );
  }

  List<StackEntry> _ordered(String name) {
    final list = List<StackEntry>.of(_entries[name] ?? const <StackEntry>[]);
    list.sort((a, b) => b.priority.compareTo(a.priority));
    return list;
  }

  @override
  Future<StackEntryId> push(
    String name,
    NodeId entry, {
    double priority = 0.0,
    Map<String, Object?>? attrs,
    Scope? scope,
  }) async {
    final id = StackEntryId.generate();
    (_entries[name] ??= <StackEntry>[]).add(
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
  Future<void> remove(String name, NodeId entry) async {
    _entries[name]?.removeWhere((e) => e.nodeId == entry);
  }

  @override
  Future<List<StackSummary>> list() async => <StackSummary>[
        for (final entry in _entries.entries)
          StackSummary(
            name: entry.key,
            size: entry.value.length,
            topPriority: entry.value.isEmpty
                ? 0.0
                : _ordered(entry.key).first.priority,
            bootstrap: false,
          ),
      ];

  @override
  Future<List<StackEntry>> peek(String name, {int k = 16}) async =>
      _ordered(name).take(k).toList();

  @override
  Future<StackEntry?> pop(String name) async {
    final list = _entries[name];
    if (list == null || list.isEmpty) {
      return null;
    }
    final top = _ordered(name).first;
    list.removeWhere((e) => e.id == top.id);
    return top;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

// ── A role-scripted `TomBrainSubstrateClient` ───────────────────────────────
//
// Branches on `LlmCall.roleId`: `procedure_author` gets the next canned draft
// (the LLM's text IS the candidate d4rt source), `procedure_critic` gets the
// next canned verdict. It also records the author-stage user text so a test can
// assert the resolved authoring intent flowed into the drafting prompt.
class _ScriptedSubstrate implements TomBrainSubstrateClient {
  List<String> authorDrafts = <String>['ok'];
  List<String> criticVerdicts = <String>['accept'];
  final List<String> authorUserTexts = <String>[];
  int _authorIdx = 0;
  int _criticIdx = 0;

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) {
    final String text;
    switch (call.roleId) {
      case 'procedure_author':
        authorUserTexts.add(_inputsTextOf(call));
        text = _next(authorDrafts, _authorIdx++);
      case 'procedure_critic':
        text = _next(criticVerdicts, _criticIdx++);
      default:
        text = 'ok';
    }
    return Stream<LlmStreamEvent>.fromIterable(<LlmStreamEvent>[
      LlmStreamChunk(callId: 'c', text: text),
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

  /// The concatenated string inputs of a call, so a test can assert the
  /// resolved authoring intent reached the drafting prompt's template variables.
  static String _inputsTextOf(LlmCall call) =>
      call.inputs.values.whereType<String>().join('\n');

  static String _next(List<String> queue, int index) =>
      index < queue.length ? queue[index] : queue.last;

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
