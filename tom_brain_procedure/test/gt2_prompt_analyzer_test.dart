// G-T2 — `prompt_analyzer_v1` entry-router acceptance suite
// (`tom_brain_completion_plan.md` Todo 5; `thinking_specification.md` § 4.0).
//
// Plan step 5.2 (verbatim): "Tests: analyser routes a plain prompt → normal
// branch and a 'think about …' prompt → thinking branch; researcher role is
// registered and its template carries the assistant-dedication anchor." Plan
// step 5.5 (gap-hunt): "Add tests for ambiguous prompts (router must still pick
// a branch deterministically) and for the anchor being present on every
// analyser call."
//
// The researcher-role registration + anchor obligation is proven in the
// substrate package (`b22_role_registry_test.dart` / `b23_anchor_injection_
// test.dart`). This suite is the *procedure-side* half: it drives the shipped
// `scripts/system/prompt_analyzer_v1.dart` through the engine with a stub
// substrate that returns a canned classification verdict, and pins:
//
//   1. Branch selection — a "NORMAL" verdict yields branch `normal` → target
//      `answer_with_memory_v1`; a "THINKING" verdict yields branch `thinking`
//      → target `think_v1` (the § 4.0 placeholder until Todo 6 lands
//      `answer_with_thinking_v1`).
//   2. The classification call is an `analyser`-role call whose prompt is
//      supplied as the role-template *input* (never a pre-assembled wire
//      prompt) — the structural guarantee that the assistant-dedication anchor
//      is prepended at substrate assembly time (§ 4.0 / PE-7).
//   3. Determinism — an unparseable / empty / ambiguous verdict resolves to a
//      branch every time (default `normal`, the spec's default; first verdict
//      token wins on a chatty completion).
//   4. Route-flip deferred (§ 4.0 blockquote, Todo 6) — the body *selects* the
//      branch and returns it; it does not run it. The classification is the
//      only substrate call the run makes.
//
// The procedure is loaded from the real `scripts/system/` store+resolver path
// so the test exercises the shipped artifact, not an inline copy (mirrors
// d36–d42).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, TrailId, Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

void main() {
  late _RecorderMemory memory;
  late _VerdictSubstrate substrate;
  late MemoryBridge memoryBridge;
  late SubstrateBridge substrateBridge;

  setUp(() {
    memory = _RecorderMemory();
    substrate = _VerdictSubstrate();
    memoryBridge = MemoryBridge(memory);
    substrateBridge = SubstrateBridge(substrate);
  });

  ProcedureEngine engineFor(Iterable<LoadedProcedure> procedures) =>
      ProcedureEngine(
        resolver: ProcedureResolver(procedures),
        memory: memory,
        memoryBridge: memoryBridge,
        substrateBridge: substrateBridge,
        now: () => DateTime.utc(2026, 6, 9, 12, 0, 0),
      );

  Future<ProcedureResolver> systemResolver() async {
    final store = DiskProcedureStore(systemDir: Directory('scripts/system'));
    return ProcedureResolver.fromStore(store);
  }

  Future<ProcedureOutcome> routeWith(String text) async {
    final resolver = await systemResolver();
    final engine = engineFor(resolver.ids.map(resolver.resolve).toList());
    return engine
        .invoke(ProcedureInvocation(
          procedureId: 'prompt_analyzer_v1',
          arguments: <String, Object?>{'text': text},
        ))
        .outcome;
  }

  group('G-T2-1 branch selection follows the analyser verdict', () {
    test('a NORMAL verdict routes to the normal branch '
        '(answer_with_memory_v1)', () async {
      substrate.verdict = 'NORMAL';

      final outcome = await routeWith('what time is it in Tokyo?');

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result!.output<String>('branch'), 'normal');
      expect(outcome.result!.output<String>('target'), 'answer_with_memory_v1');
    });

    test('a THINKING verdict routes to the thinking branch '
        '(answer_with_thinking_v1)', () async {
      substrate.verdict = 'THINKING';

      final outcome = await routeWith('think about the ethics of AI memory');

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result!.output<String>('branch'), 'thinking');
      // § 4.0: the thinking-branch target is answer_with_thinking_v1, the
      // recursive thinking loop (Todo 6); think_v1 is superseded.
      expect(
        outcome.result!.output<String>('target'),
        'answer_with_thinking_v1',
      );
    });
  });

  group('G-T2-2 the classification is an analyser-role call', () {
    test('the call names the analyser role', () async {
      substrate.verdict = 'NORMAL';

      await routeWith('plain question');

      expect(substrate.lastCall!.roleId, 'analyser');
    });

    test('the prompt is supplied as the role-template input (the anchor '
        'guarantee, § 4.0 / PE-7) and embeds the user text + verdict '
        'instruction', () async {
      substrate.verdict = 'NORMAL';

      await routeWith('how do I rotate my SSH keys?');

      // The body hands the substrate a `prompt` *input*, never a wire prompt —
      // so the substrate prepends the anchor at assembly time. The captured
      // input carries the user text and the one-token verdict instruction.
      final prompt = substrate.lastCall!.inputs['prompt']! as String;
      expect(prompt, contains('how do I rotate my SSH keys?'));
      expect(prompt, contains('THINKING'));
      expect(prompt, contains('NORMAL'));
    });
  });

  group('G-T2-3 the router always picks a branch deterministically '
      '(gap-hunt § 5.5)', () {
    test('an unparseable verdict defaults to normal', () async {
      substrate.verdict = 'I am not sure how to classify this prompt.';

      final outcome = await routeWith('ambiguous prompt');

      expect(outcome.result!.output<String>('branch'), 'normal');
      expect(outcome.result!.output<String>('target'), 'answer_with_memory_v1');
    });

    test('an empty completion defaults to normal', () async {
      substrate.verdict = '';

      final outcome = await routeWith('ambiguous prompt');

      expect(outcome.result!.output<String>('branch'), 'normal');
    });

    test('a chatty completion naming THINKING first resolves to thinking',
        () async {
      substrate.verdict = 'This looks like THINKING, definitely not just '
          'a NORMAL request.';

      final outcome = await routeWith('reason carefully about X');

      expect(outcome.result!.output<String>('branch'), 'thinking');
    });

    test('a chatty completion naming NORMAL first resolves to normal',
        () async {
      substrate.verdict = 'This is a NORMAL request, no THINKING required.';

      final outcome = await routeWith('what is 2 + 2?');

      expect(outcome.result!.output<String>('branch'), 'normal');
    });

    test('the same ambiguous prompt resolves identically across runs',
        () async {
      substrate.verdict = 'unreadable verdict';

      final first = await routeWith('ambiguous prompt');
      final second = await routeWith('ambiguous prompt');

      expect(first.result!.output<String>('branch'),
          second.result!.output<String>('branch'));
      expect(first.result!.output<String>('branch'), 'normal');
    });
  });

  group('G-T2-4 the router selects but does not run the branch '
      '(route-flip deferred to Todo 6)', () {
    test('the classification is the only substrate call the run makes',
        () async {
      substrate.verdict = 'NORMAL';

      await routeWith('plain question');

      // answer_with_memory_v1 (had it been run) would make further llm / embed
      // calls; the router makes exactly one — the classification.
      expect(substrate.callCount, 1);
    });

    test('the verdict output mirrors the chosen branch', () async {
      substrate.verdict = 'THINKING';

      final outcome = await routeWith('ponder this deeply');

      expect(outcome.result!.output<String>('verdict'), 'thinking');
    });
  });
}

// ── A verdict-emitting `TomBrainSubstrateClient` ────────────────────
//
// Captures the `LlmCall` the bridge constructs (so the test can assert the
// analyser role and the prompt input) and emits the configured [verdict] as a
// single completion chunk. Counts calls so the route-flip-deferred test can
// prove the body issues exactly one completion (the classification) and never
// runs the chosen branch. Mirrors the d38 answer-capturing double.
class _VerdictSubstrate implements TomBrainSubstrateClient {
  LlmCall? lastCall;
  int callCount = 0;
  String verdict = 'NORMAL';

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) {
    lastCall = call;
    callCount++;
    return Stream<LlmStreamEvent>.fromIterable(<LlmStreamEvent>[
      LlmStreamChunk(callId: 'c', text: verdict),
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

// ── A recorder-only `TomBrainMemory` ────────────────────────────────
//
// prompt_analyzer_v1 touches no memory primitive — but the engine's run
// recorder still opens/appends/closes a trail and persists the ProcedureRun
// node. This double models just that recorder surface (trails are entry logs,
// stacks are push/peek containers, persisted nodes are resolvable by id).
// Mirrors the C.18 / D.8 / D.37 / D.38 doubles.
class _RecorderMemory implements TomBrainMemory {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

  @override
  StackApi get stacks => _stacks;

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
