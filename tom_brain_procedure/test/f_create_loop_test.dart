// Todo 9 (G-C1…G-C6) — the `create_v1` creation-loop acceptance suite
// (`tom_brain_completion_plan.md` Todo 9; `creation_specification.md`
// § 4, § 5, § 9, § 10, § 12.1 decision 5).
//
// Plan step 9.2 (verbatim): "Tests: `create_v1` runs the loop and writes an
// artifact only on success (no silent writes); `vagueIntent` refusal when
// intent / observable success criterion is missing; the file-scope sandbox
// blocks out-of-root paths, network, and direct memory writes; a
// `CreationEvent` trail + `Artifact` node (`satisfied-by` linkage) are
// persisted."
//
// This is the *procedure-side* proof of the creation loop. It drives the
// shipped `scripts/system/create_v1.dart` through the engine with:
//
//   - a **role-aware** substrate double returning a fresh `draft #N` per
//     `creator` call and driving the accept / revise decision off a queue of
//     `reviewer` verdicts, so the test controls how many times the loop
//     re-enters; and
//   - the consolidated `_BrainMemory` double (the gt1 shape) so the recall →
//     persist(Question) → persist(Artifact) → edge(satisfied_by) post-
//     conditions can be read off one object; and
//   - a real on-disk file-scope root (a temp dir) wired through the engine's
//     `toolFileScope`, so the single `file.write` actually lands a file
//     (and an escaping `target` actually raises `FileScopeViolation`).
//
// The behaviours the plan pins:
//
//   F-C-1  vagueIntent refusal — a blank/absent intent OR success criterion
//          (and a blank target) refuses *before any draft is composed*: the
//          run errors, the error names `vagueIntent`, and nothing is drafted,
//          written, or persisted.
//   F-C-2  write-on-accept — an ACCEPT on the first critique writes the draft
//          to disk, persists a Question + an Artifact, ties them with an
//          Artifact → satisfied_by → Question edge, returns written=true /
//          incomplete=false, and never surfaces the reserved producedNodeIds
//          channel as an output.
//   F-C-3  re-entry on revise — a REVISE then an ACCEPT yields two creator
//          drafts and two reviewer critiques; the *second* (accepted) draft is
//          the one written.
//   F-C-4  no silent write on exhaustion — an always-revising reviewer
//          exhausts the bounded re-entry: nothing is written, written=false /
//          incomplete=true, the Question is still recorded (so the dreaming
//          process can revisit it) but no Artifact is.
//   F-C-5  the sandbox is not negotiable — an escaping `target` raises
//          `FileScopeViolation`, which closes the run errored, and no file is
//          written outside the root.
//
// And the 9.5 gap-hunt guards on the *shape* of the loop (none re-tested by
// F-C-1…F-C-5):
//
//   F-C-6  no network — creation's declared capability surface contains no
//          network primitive, so a creation run provably cannot reach out.
//   F-C-7  the deadline backstop — the header budget is a wall-clock-only
//          runaway-stop (§ 7.4), declaring no count cap that would throttle the
//          loop's persists / writes; the *enforcement* of that wall clock is
//          proven generically in `c51_budget_enforcement_test.dart`.
//   F-C-8  test-first + check run for code kind — a `kind: 'code'` request
//          drafts a test first (the `tester` role), runs it through the
//          allow-listed process surface, and on each iteration writes the draft,
//          runs the `analyze.*` check against the written file, and folds the
//          check into the critique. The capability surface stays unchanged: the
//          checks route through the single `tool.invoke` primitive, so `requires`
//          still names no `analyze.*` / `test.*` bridge (the sandbox did not
//          widen, § 5.4).
//   F-C-9  the check gates acceptance — a failing analyzer (non-zero exit)
//          blocks acceptance even when the reviewer says ACCEPT, so every draft
//          is rolled back (`file.delete`) and the run ends incomplete with
//          nothing on disk (§ 4.6 `accept requires successSatisfied`, § 4.7).
//   F-C-10 per-iteration write → rollback → re-enter — a code-kind REVISE,
//          REVISE, ACCEPT writes and rolls back two drafts before keeping the
//          third; only the accepted draft survives on disk (§ 4.4–§ 4.7).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, TrailId, Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

void main() {
  late _BrainMemory memory;
  late _RoleAwareSubstrate substrate;
  late MemoryBridge memoryBridge;
  late SubstrateBridge substrateBridge;
  late Directory root;

  setUp(() {
    memory = _BrainMemory();
    substrate = _RoleAwareSubstrate();
    memoryBridge = MemoryBridge(memory);
    substrateBridge = SubstrateBridge(substrate);
    root = Directory.systemTemp.createTempSync('f_create_');
  });

  tearDown(() => root.deleteSync(recursive: true));

  ProcedureEngine engineFor(
    Iterable<LoadedProcedure> procedures, {
    ToolProcessSurface? process,
  }) =>
      ProcedureEngine(
        resolver: ProcedureResolver(procedures),
        memory: memory,
        memoryBridge: memoryBridge,
        substrateBridge: substrateBridge,
        toolFileScope: FileScope(writeRoots: <String>[root.path]),
        // A hermetic, non-spawning default: the text-kind cases run no check, so
        // the surface is unused, but a fake guarantees no test ever shells out.
        toolProcessSurface: process ?? _FakeProcess(),
        now: () => DateTime.utc(2026, 6, 9, 12, 0, 0),
      );

  Future<ProcedureResolver> systemResolver() async {
    final store = DiskProcedureStore(systemDir: Directory('scripts/system'));
    return ProcedureResolver.fromStore(store);
  }

  Future<ProcedureOutcome> create(
    Map<String, Object?> arguments, {
    ToolProcessSurface? process,
  }) async {
    final resolver = await systemResolver();
    final engine = engineFor(
      resolver.ids.map(resolver.resolve).toList(),
      process: process,
    );
    return engine
        .invoke(ProcedureInvocation(
          procedureId: 'create_v1',
          arguments: arguments,
        ))
        .outcome;
  }

  /// A well-formed creation request that satisfies the entry gate; individual
  /// tests override the field under test.
  Map<String, Object?> request({
    String? intent = 'a greeting file that prints hello',
    String? successCriterion = 'the file contains the word hello',
    String? target = 'out.txt',
    String kind = 'text',
    int? maxIterations,
  }) =>
      <String, Object?>{
        'intent': ?intent,
        'successCriterion': ?successCriterion,
        'target': ?target,
        'kind': kind,
        'maxIterations': ?maxIterations,
      };

  File targetFile(String name) => File(p.join(root.path, name));

  group('F-C-1 vagueIntent refusal (§ 10, G-C5)', () {
    test('an absent intent refuses before any draft, write, or persist',
        () async {
      final outcome = await create(request(intent: null));

      expect(outcome.status, TrailOutcomeStatus.errored);
      expect(outcome.error.toString(), contains('vagueIntent'));
      // Refused before any draft is composed: no creator call, no write, no
      // Question recorded.
      expect(substrate.countOf('creator'), 0);
      expect(memory.persistedOfType('Question'), isEmpty);
      expect(targetFile('out.txt').existsSync(), isFalse);
    });

    test('a blank success criterion refuses (§ 10)', () async {
      final outcome = await create(request(successCriterion: '   '));

      expect(outcome.status, TrailOutcomeStatus.errored);
      expect(outcome.error.toString(), contains('vagueIntent'));
      expect(substrate.countOf('creator'), 0);
    });

    test('a missing target refuses (creation must know where to write)',
        () async {
      final outcome = await create(request(target: null));

      expect(outcome.status, TrailOutcomeStatus.errored);
      expect(outcome.error.toString(), contains('vagueIntent'));
      expect(substrate.countOf('creator'), 0);
    });
  });

  group('F-C-2 write-on-accept (§ 4.1, § 9, § 12.1 decision 5)', () {
    test('an accept writes the draft and persists Question + Artifact + edge',
        () async {
      substrate.reviewerVerdicts = <String>['ACCEPT'];

      final outcome = await create(request());

      // (a) The run accepted; the loop ran exactly once.
      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(substrate.countOf('creator'), 1);
      expect(substrate.countOf('reviewer'), 1);

      // (b) Outputs report a completed write to the target.
      expect(outcome.result!.output<bool>('written'), isTrue);
      expect(outcome.result!.output<bool>('incomplete'), isFalse);
      expect(outcome.result!.output<String>('target'), 'out.txt');

      // (c) The accepted draft is on disk under the file-scope root.
      final written = targetFile('out.txt');
      expect(written.existsSync(), isTrue);
      expect(written.readAsStringSync(), substrate.draftFor(1));

      // (d) The request is a Question; the product is an Artifact.
      final question = memory.persistedOfType('Question').single;
      expect(question.draft.values['text'], contains('a greeting file'));
      final artifact = memory.persistedOfType('Artifact').single;
      expect(artifact.draft.values['content_ref'], 'out.txt');

      // (e) Artifact → satisfied_by → Question (the realised-store direction of
      //     the spec's satisfied-by linkage, § 9.2).
      final satisfied = memory.recordedEdges.where(
        (e) => e.type == EdgeType.satisfiedBy && e.from == artifact.id,
      );
      expect(satisfied, hasLength(1));
      expect(satisfied.single.to, question.id);

      // (f) The reserved transport channel never surfaces as an output.
      expect(outcome.result!.outputs.containsKey(producedNodeIdsOutputKey),
          isFalse);
    });
  });

  group('F-C-3 re-entry on revise (§ 4.1)', () {
    test('a REVISE then an ACCEPT writes the second (accepted) draft',
        () async {
      substrate.reviewerVerdicts = <String>['REVISE', 'ACCEPT'];

      final outcome = await create(request());

      expect(outcome.status, TrailOutcomeStatus.accepted);
      // Two drafts, two critiques: the loop re-entered once.
      expect(substrate.countOf('creator'), 2);
      expect(substrate.countOf('reviewer'), 2);
      // The second draft is the one written.
      expect(targetFile('out.txt').readAsStringSync(), substrate.draftFor(2));
      expect(outcome.result!.output<bool>('incomplete'), isFalse);
    });
  });

  group('F-C-4 no silent write on exhaustion (§ 12.1 decision 5, P6)', () {
    test('an always-revising reviewer writes nothing and flags incomplete',
        () async {
      // No ACCEPT ever: every verdict defaults to REVISE.
      substrate.reviewerVerdicts = <String>[];
      substrate.defaultVerdict = 'REVISE';

      final outcome = await create(request());

      // The run completes (it is not an error to fail to satisfy a critique).
      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result!.output<bool>('written'), isFalse);
      expect(outcome.result!.output<bool>('incomplete'), isTrue);

      // Nothing reached disk — "writes artifacts only on success" by
      // construction (no rejected draft is ever written).
      expect(targetFile('out.txt').existsSync(), isFalse);

      // The request is still recorded so the dreaming process can revisit the
      // still-open creation; but no Artifact was produced.
      expect(memory.persistedOfType('Question'), hasLength(1));
      expect(memory.persistedOfType('Artifact'), isEmpty);
      expect(
        memory.recordedEdges
            .where((e) => e.type == EdgeType.satisfiedBy),
        isEmpty,
      );
    });
  });

  group('F-C-5 the sandbox is not negotiable (§ 5.4, P6)', () {
    test('an escaping target raises FileScopeViolation and writes nothing',
        () async {
      substrate.reviewerVerdicts = <String>['ACCEPT'];

      final outcome = await create(request(target: '../escape.txt'));

      // The escaping write closes the run errored — a write that escapes the
      // sandbox is a bug, not a soft result.
      expect(outcome.status, TrailOutcomeStatus.errored);
      expect(outcome.error, isA<FileScopeViolation>());
      // Nothing was written outside the root.
      expect(File(p.join(root.parent.path, 'escape.txt')).existsSync(), isFalse);
    });
  });

  // ── 9.5 gap-hunt (`tom_brain_completion_plan.md` § 9.5) ──────────────────

  group('F-C-6 no network during creation (§ 5.4, structural)', () {
    test('create_v1 declares an exact capability surface with no network',
        () async {
      final resolver = await systemResolver();
      final create = resolver.resolve('create_v1');

      // The complete declared primitive surface (PE-1): the SandboxValidator
      // allow-lists exactly the bridges these name, so a capability absent here
      // is structurally unreachable from the body — the file-scope write
      // (`tool.invoke`) plus memory + substrate, and nothing else.
      expect(
        create.header.requires,
        <String>[
          'recall',
          'embed',
          'llm',
          'persist',
          'edge',
          'note',
          'tool.invoke',
        ],
        reason: 'the full creation capability surface — no network capability',
      );

      // No network primitive is anywhere in that surface.
      for (final network in const <String>[
        'web',
        'web.fetch',
        'web.search',
        'fetch',
        'search',
        'http',
      ]) {
        expect(create.header.requires, isNot(contains(network)),
            reason: 'creation must not reach the network ($network)');
      }
    });
  });

  group('F-C-7 the deadline is a wall-clock-only backstop (§ 7.4)', () {
    test('create_v1 declares a wall-clock cap and no throttling count caps',
        () async {
      final resolver = await systemResolver();
      final budget = resolver.resolve('create_v1').header.budget;

      // A 24-hour runaway-stop (§ 7.4), enforced by the StepDeadline — proven
      // generically in `c51_budget_enforcement_test.dart`. A creation run
      // issues several memory writes (Question + Artifact + edge) and
      // tool/substrate calls per iteration, so any count cap would throttle the
      // loop; the budget is deliberately wall-clock-only (the c51-3 "a
      // wall-clock-only budget never refuses a tool call" case) and set very
      // high so a long creation is never artificially cut short.
      expect(budget.raw, <String, int>{'wallClockMs': 86400000});
      expect(budget.wallClockMs, 86400000);
      expect(budget.toolCalls, isNull);
      expect(budget.memoryWrites, isNull);
      expect(budget.tokenSpend, isNull);
    });
  });

  group('F-C-8 test-first + check run for code kind (§ 4.3, § 4.5)', () {
    test('a code request drafts a test, runs it, and checks the written draft',
        () async {
      // (a) Structural: the checks route through `tool.invoke`, so the declared
      //     capability surface still names no `analyze.*` / `test.*` bridge —
      //     the sandbox did not widen (§ 5.4).
      final resolver = await systemResolver();
      final requires = resolver.resolve('create_v1').header.requires;
      for (final check in const <String>[
        'analyze.dart',
        'analyze.format',
        'analyze.schema',
        'test.run',
        'test.baseline',
        'test',
      ]) {
        expect(requires, isNot(contains(check)),
            reason: 'checks route through tool.invoke, not a new bridge ($check)');
      }

      // (b) Dynamic: a code-kind ACCEPT drafts a test first (tester role), runs
      //     it through the allow-listed surface, and runs the analyzer over the
      //     written draft before keeping it.
      final process = _FakeProcess(); // exitCode 0 — test runs, analyzer clean
      substrate.reviewerVerdicts = <String>['ACCEPT'];

      final outcome = await create(
        request(target: 'lib.dart', kind: 'code'),
        process: process,
      );

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result!.output<bool>('written'), isTrue);
      expect(substrate.countOf('tester'), 1,
          reason: 'test-first drafts the success-check before the artifact');
      expect(substrate.countOf('creator'), 1);

      // The test-first run shelled `testkit :test`; the per-iteration check
      // shelled `dart analyze` over the written file — both allow-listed.
      expect(
        process.calls.where((c) => c.exe == 'testkit' && c.args.contains(':test')),
        hasLength(1),
        reason: 'the drafted test was run before the artifact existed',
      );
      expect(
        process.calls.where((c) => c.exe == 'dart' && c.args.first == 'analyze'),
        hasLength(1),
        reason: 'the analyzer checked the written draft (§ 4.5)',
      );
      expect(targetFile('lib.dart').readAsStringSync(), substrate.draftFor(1));
    });
  });

  group('F-C-9 the check gates acceptance (§ 4.6, § 4.7)', () {
    test('a failing analyzer blocks accept even on an ACCEPT verdict', () async {
      // The analyzer fails every iteration; the reviewer would accept, but the
      // unsatisfied check forbids it, so each draft is rolled back.
      final process = _FakeProcess(
        result: const ProcessRunResult(
            exitCode: 1, stdout: '', stderr: 'analysis error'),
      );
      substrate.reviewerVerdicts = <String>['ACCEPT'];
      substrate.defaultVerdict = 'ACCEPT';

      // The deliberation budget is caller-overridable (§ 4.1); pin it small
      // here so the always-failing analyzer exhausts it in a bounded,
      // observable number of passes rather than the very-high production
      // default.
      final outcome = await create(
        request(target: 'lib.dart', kind: 'code', maxIterations: 3),
        process: process,
      );

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result!.output<bool>('written'), isFalse);
      expect(outcome.result!.output<bool>('incomplete'), isTrue);
      // Every code draft was written then rolled back: nothing survives.
      expect(targetFile('lib.dart').existsSync(), isFalse);
      // The bounded loop ran to exhaustion, drafting + checking each time.
      expect(substrate.countOf('creator'), 3);
      // No Artifact was produced; the Question remains for the dreamer.
      expect(memory.persistedOfType('Artifact'), isEmpty);
      expect(memory.persistedOfType('Question'), hasLength(1));
    });
  });

  group('F-C-10 per-iteration write → rollback → re-enter (§ 4.4–§ 4.7)', () {
    test('two revised drafts are rolled back; only the accepted one survives',
        () async {
      final process = _FakeProcess(); // analyzer clean every iteration
      substrate.reviewerVerdicts = <String>['REVISE', 'REVISE', 'ACCEPT'];

      final outcome = await create(
        request(target: 'lib.dart', kind: 'code'),
        process: process,
      );

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result!.output<bool>('written'), isTrue);
      expect(substrate.countOf('creator'), 3);
      // Only the third (accepted) draft is on disk — the first two were written
      // then rolled back via file.delete.
      expect(targetFile('lib.dart').readAsStringSync(), substrate.draftFor(3));
      // The analyzer ran once per iteration over the written draft.
      expect(
        process.calls.where((c) => c.exe == 'dart' && c.args.first == 'analyze'),
        hasLength(3),
      );
    });
  });
}

// ── A deterministic `ToolProcessSurface` fake ───────────────────────
//
// Records each call and returns a canned [ProcessRunResult]; no process is
// spawned. exitCode 0 by default (a clean analyzer / a test that "ran"), so the
// per-iteration check is satisfied and acceptance is driven by the reviewer.
class _FakeProcess implements ToolProcessSurface {
  _FakeProcess({
    this.result =
        const ProcessRunResult(exitCode: 0, stdout: 'ok', stderr: ''),
  });

  final ProcessRunResult result;
  final List<({String exe, List<String> args, String? cwd})> calls =
      <({String exe, List<String> args, String? cwd})>[];

  @override
  Future<ProcessRunResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    calls.add((exe: executable, args: arguments, cwd: workingDirectory));
    return result;
  }
}

// ── A role-aware `TomBrainSubstrateClient` ──────────────────────────
//
// Returns a fresh `draft #N` for each `creator` call and drives the accept /
// revise decision off [reviewerVerdicts] (consumed in order; [defaultVerdict]
// once exhausted). Counts calls per role so the test can assert how many times
// the loop re-entered. Any other role degrades to plain text (PE-6).
class _RoleAwareSubstrate implements TomBrainSubstrateClient {
  final Map<String, int> _byRole = <String, int>{};

  /// The reviewer verdicts to emit, in order. A REVISE forces a re-entry; an
  /// ACCEPT exits the loop. When exhausted, [defaultVerdict] is used.
  List<String> reviewerVerdicts = <String>['ACCEPT'];

  /// The verdict emitted once [reviewerVerdicts] is exhausted.
  String defaultVerdict = 'ACCEPT';

  int _reviewerCalls = 0;

  /// How many times [roleId] was called.
  int countOf(String roleId) => _byRole[roleId] ?? 0;

  /// The draft text the `creator` returns on its [n]-th call (1-based).
  String draftFor(int n) => 'draft #$n';

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) {
    final role = call.roleId;
    _byRole[role] = (_byRole[role] ?? 0) + 1;
    final text = _textFor(role);
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

  String _textFor(String role) {
    switch (role) {
      case 'creator':
        return draftFor(_byRole['creator']!);
      case 'reviewer':
        final n = _reviewerCalls++;
        return n < reviewerVerdicts.length
            ? reviewerVerdicts[n]
            : defaultVerdict;
      default:
        return 'ok';
    }
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

// ── A consolidated stateful `TomBrainMemory` ────────────────────────
//
// The gt1 `_BrainMemory` shape: recall-configurable, persist/edge-capturing,
// trail + stack modelling — enough for the run recorder's writes to succeed
// and for the loop's persist post-conditions to be read off one object.
class _BrainMemory implements TomBrainMemory {
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
