// author_new_procedure_v1 — the authoring-loop procedure acceptance suite
// (Todo 7 / G-PR1; `procedure_specification.md` § 8.3).
//
// The brain authors its own procedures by running a fixed root procedure,
// `author_new_procedure_v1`, which:
//
//   1. recalls past procedures as drafting context (recall is the only read);
//   2. drafts a candidate with the `procedure_author` role (the LLM's text IS
//      the candidate d4rt source);
//   3. dry-runs the draft through the engine-native `validate(source)` and
//      re-drafts once against the findings on failure;
//   4. if still invalid, registers the work at `authored` and reports the run
//      failed (returning the findings) — the unbuilt state is loud, never
//      silent (§ 8.3);
//   5. critiques the (now valid) draft with the `procedure_critic` role;
//   6. persists a `Procedure` node (name/summary/requires taken from the parsed
//      header the validator surfaces), stamping `draft` on critic-accept and
//      `authored` on critic-revise, and links a revision to its predecessor
//      with a `superseded_by` edge (structural, never destructive — hard
//      principle 6).
//
// The procedure is loaded from the real `scripts/system/` store so the test
// exercises the shipped artifact through the engine, with a stub memory (records
// every persist + edge) and a role-scripted substrate (canned author drafts +
// critic verdicts) so the post-conditions are observable.

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

/// Maps each migrated `assist_user.author.*` prompt id to the authoring role its
/// stage runs under, so the role-keyed `_ScriptedSubstrate` still distinguishes
/// the author / critic stages now that the procedure resolves prompts through
/// `sub.run`.
const Map<String, String> _authorRoleById = <String, String>{
  'assist_user.author.draft': 'procedure_author',
  'assist_user.author.fix_validation': 'procedure_author',
  'assist_user.author.critique': 'procedure_critic',
};

void main() {
  late _CapturingMemory memory;
  late _ScriptedSubstrate substrate;
  late MemoryBridge memoryBridge;
  late SubstrateBridge substrateBridge;

  setUp(() {
    memory = _CapturingMemory();
    substrate = _ScriptedSubstrate();
    memoryBridge = MemoryBridge(memory);
    final prompts = StubPromptResolver(
      roleForId: (id) => _authorRoleById[id] ?? 'assistant_to_user',
    );
    substrateBridge = SubstrateBridge(
      substrate,
      promptResolver: prompts.resolver,
      routeChainOf: prompts.routeChainOf,
    );
  });

  ProcedureEngine engineFor(Iterable<LoadedProcedure> procedures) =>
      ProcedureEngine(
        resolver: ProcedureResolver(procedures),
        memory: memory,
        memoryBridge: memoryBridge,
        substrateBridge: substrateBridge,
        now: () => DateTime.utc(2026, 6, 2, 12, 0, 0),
      );

  Future<ProcedureResolver> systemResolver() async {
    final store = DiskProcedureStore(systemDir: Directory('scripts/system'));
    return ProcedureResolver.fromStore(store);
  }

  Future<ProcedureOutcome> runAuthor(Map<String, Object?> args) async {
    final resolver = await systemResolver();
    final engine = engineFor(resolver.ids.map(resolver.resolve).toList());
    return engine
        .invoke(ProcedureInvocation(
          procedureId: 'author_new_procedure_v1',
          arguments: args,
        ))
        .outcome;
  }

  /// The single `Procedure` node the authoring run persisted (the run recorder
  /// persists `ProcedureRun` nodes, never `Procedure`, so this is unambiguous).
  ({NodeId id, NodeDraft draft}) authoredProcedure() =>
      memory.persistedOfType('Procedure').single;

  group('G-PR1-1 happy path — valid draft, critic accepts → draft status', () {
    test('persists a Procedure node carrying the parsed header facts', () async {
      substrate.authorDrafts = <String>[_validCandidate];
      substrate.criticVerdicts = <String>['accept'];

      final outcome = await runAuthor(<String, Object?>{
        'intent': 'greet the user by name',
      });

      expect(outcome.status, TrailOutcomeStatus.accepted);

      final procedure = authoredProcedure();
      expect(procedure.draft.values['name'], 'greet_user_v1');
      expect(procedure.draft.values['summary'],
          'Greets the user by their stored name.');
      expect(procedure.draft.values['code'], _validCandidate);
      expect(procedure.draft.values['status'], 'draft');
      expect(procedure.draft.values['requires'], <String>['recall', 'note']);
    });

    test('reports the authored node id and produces it', () async {
      substrate.authorDrafts = <String>[_validCandidate];

      final outcome = await runAuthor(<String, Object?>{'intent': 'x'});

      final procedureId = authoredProcedure().id;
      expect(outcome.result!.output<String>('procedure'), procedureId.value);

      // The Procedure is this run's produced node — the recorder draws a
      // produced_by edge from it to the authoritative final ProcedureRun.
      final producedBy = memory.recordedEdges.where(
        (e) => e.type == EdgeType.producedBy && e.from == procedureId,
      );
      expect(producedBy, hasLength(1));
    });
  });

  group('G-PR1-2 critic revise — valid draft, critic asks for revision', () {
    test('records the draft at authored (not greenlit) but the run succeeds',
        () async {
      substrate.authorDrafts = <String>[_validCandidate];
      substrate.criticVerdicts = <String>['revise: tighten the success check'];

      final outcome = await runAuthor(<String, Object?>{'intent': 'x'});

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(authoredProcedure().draft.values['status'], 'authored');
    });
  });

  group('G-PR1-3 re-draft — first draft invalid, second valid', () {
    test('the fix pass salvages the draft and it lands at draft status',
        () async {
      // First draft reaches outside the sandbox (dart:io) → invalid; the fix
      // pass returns a clean source.
      substrate.authorDrafts = <String>[_sandboxViolatingCandidate, _validCandidate];
      substrate.criticVerdicts = <String>['accept'];

      final outcome = await runAuthor(<String, Object?>{'intent': 'x'});

      expect(outcome.status, TrailOutcomeStatus.accepted);
      final procedure = authoredProcedure();
      expect(procedure.draft.values['code'], _validCandidate);
      expect(procedure.draft.values['status'], 'draft');
    });
  });

  group('G-PR1-4 unmakeable — invalid after the fix pass', () {
    test('registers the work at authored and the run is loud (errored, '
        'carrying the findings)', () async {
      // Both drafts violate the sandbox: the body can never be made valid.
      substrate.authorDrafts = <String>[
        _sandboxViolatingCandidate,
        _sandboxViolatingCandidate,
      ];

      final outcome = await runAuthor(<String, Object?>{'intent': 'x'});

      // The run is loud: a script signals failure by throwing, so the engine
      // closes the run `errored` rather than silently dropping the work.
      expect(outcome.status, TrailOutcomeStatus.errored);

      // The work is not lost — the draft is registered at `authored` before the
      // throw (the persist is a committed side effect).
      final procedure = authoredProcedure();
      expect(procedure.draft.values['status'], 'authored');

      // The thrown error carries the findings so the caller knows why — the
      // sandbox-violation code surfaces in the error text.
      expect('${outcome.error}', contains('procedure.sandbox.violation'));
    });
  });

  group('G-PR1-5 revision — a predecessor is linked with superseded_by', () {
    test('the new revision points back to its predecessor (structural, never '
        'destructive)', () async {
      final predecessor = NodeId.fromString('n_00000000000000000000000077');
      substrate.authorDrafts = <String>[_validCandidate];
      substrate.criticVerdicts = <String>['accept'];

      await runAuthor(<String, Object?>{
        'intent': 'x',
        'predecessor': predecessor.value,
        'revision': 2,
      });

      final newId = authoredProcedure().id;
      expect(authoredProcedure().draft.values['revision'], 2);

      final superseded = memory.recordedEdges.where(
        (e) => e.type == EdgeType.supersededBy && e.from == predecessor,
      );
      expect(superseded, hasLength(1));
      expect(superseded.single.to, newId);
    });

    test('no superseded_by edge when there is no predecessor (a fresh id)',
        () async {
      substrate.authorDrafts = <String>[_validCandidate];

      await runAuthor(<String, Object?>{'intent': 'x'});

      final superseded = memory.recordedEdges
          .where((e) => e.type == EdgeType.supersededBy);
      expect(superseded, isEmpty);
    });
  });
}

// ── Canned candidate sources the procedure_author role "writes" ─────────────

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

// A candidate that parses a clean header but reaches outside the sandbox
// (`dart:io`): the header layer passes, the sandbox layer faults. Used to drive
// the re-draft and the unmakeable paths.
const String _sandboxViolatingCandidate = '''
/// @procedure
/// id: greet_user_v1
/// version: 1
/// summary: Greets the user by their stored name.
/// successCriterion: returns a succeeded ProcedureResult naming the user.
/// budget: { wallClockMs: 5000 }
/// requires: [ note ]
import 'dart:io';
import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure/src/api/procedure_result.dart';
import 'package:tom_brain_procedure/src/primitives_native/primitives_native.dart';

Future<ProcedureResult> run(ProcedureInputs inputs) async {
  stdout.writeln('hi');
  note('progress', {});
  return ProcedureResult.succeeded();
}
''';

// ── A persist + edge capturing `TomBrainMemory` ─────────────────────────────
//
// Returns a configurable (empty by default) recall, assigns a fresh id to every
// persisted node and records the (id, draft) pair, records every edge's
// (from, type, to), and models enough of the store for the run recorder's trail
// + stack writes to succeed. Mirrors the D.39 double.
class _CapturingMemory implements TomBrainMemory {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

  final List<({NodeId id, NodeDraft draft})> persisted =
      <({NodeId id, NodeDraft draft})>[];

  final List<({NodeId from, EdgeType type, NodeId to})> recordedEdges =
      <({NodeId from, EdgeType type, NodeId to})>[];

  RecallResult recallResult = const RecallResult(
    nodes: <Node>[],
    report: RecallReport(
      candidatesPerMode: <RecallMode, int>{},
      fusionStrategy: FusionStrategy.rrf,
      diversityStrategy: DiversityStrategy.mmr,
      elapsedMs: 0,
    ),
  );

  ClassificationResult classifyResult = const ClassificationResult.unknown();

  Iterable<({NodeId id, NodeDraft draft})> persistedOfType(String typeName) =>
      persisted.where((p) => p.draft.typeName == typeName);

  @override
  StackApi get stacks => _stacks;

  @override
  Future<RecallResult> recall(RecallQuery query) async => recallResult;

  @override
  Future<RecallResult> recallMulti(MultiRecallQuery query) async => recallResult;

  @override
  Future<ClassificationResult> classify(
    Vec embedding, {
    ClassificationTarget target = ClassificationTarget.nodeType,
  }) async =>
      classifyResult;

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

// ── A role-scripted `TomBrainSubstrateClient` ───────────────────────────────
//
// Branches on `LlmCall.roleId`: the `procedure_author` role gets the next canned
// draft (the LLM's text is the candidate d4rt source), the `procedure_critic`
// role gets the next canned verdict. A drained queue repeats its last entry so a
// loop that calls a role one more time than expected still terminates.
class _ScriptedSubstrate implements TomBrainSubstrateClient {
  List<String> authorDrafts = <String>['ok'];
  List<String> criticVerdicts = <String>['accept'];
  int _authorIdx = 0;
  int _criticIdx = 0;

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) {
    final String text;
    switch (call.roleId) {
      case 'procedure_author':
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
