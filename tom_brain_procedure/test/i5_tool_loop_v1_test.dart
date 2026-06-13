// Increment 5 (prompt_configuration.md §7.2 / §7.4) — the shared tool-loop
// procedure `scripts/system/tool_loop_v1.dart`.
//
// `tool_loop_v1` is the single send→parse→execute→re-send loop every prompt now
// shares. `sub.run` resolves the prompt's settings on the Dart side and delegates
// the loop here via `runProcedure`; the loop itself only ever issues `sub.send`
// completions over the *named* route it is handed, runs the proposed tool calls
// through `tool.invoke`, folds the results back, and re-enters until the model
// answers — bounded by `maxToolLoops`.
//
// What this suite pins, against the shipped `scripts/system/` artifact and the
// engine's per-run bridge bindings:
//
//   1. EXECUTE → RE-PROMPT → ANSWER — a proposed `memory.read` call reaches the
//      real `tool.invoke` surface (which calls `memory.recall`), the result is
//      folded into a later transcript, and the model then answers; the run
//      surfaces that answer with `toolLoopExhausted == false`.
//   2. `maxToolLoops` CAP — a substrate that proposes a tool on *every* turn
//      exhausts the cap: the loop stops, `toolLoopExhausted == true`, and it
//      issued exactly `maxToolLoops` completions.
//   3. NONE / EMPTY CATALOGUE — with no tools offered the model answers in one
//      turn; the answer is surfaced, no tool is invoked, `toolLoopExhausted`
//      is false.
//
// The loop calls `sub.send`, so the engine's `SubstrateBridge` is built with a
// `RouteChainResolver` bound (any non-empty chain — the stub substrate ignores
// the chain, that plumbing is pinned in `i5_substrate_bridge_send_test.dart`).

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
  late _RecallCapturingMemory memory;
  late _LoopSubstrate substrate;
  late MemoryBridge memoryBridge;
  late SubstrateBridge substrateBridge;

  setUp(() {
    memory = _RecallCapturingMemory();
    substrate = _LoopSubstrate();
    memoryBridge = MemoryBridge(memory);
    // The loop calls `sub.send`, which needs a RouteChainResolver; the stub
    // substrate ignores the resolved chain (route plumbing is pinned elsewhere).
    substrateBridge = SubstrateBridge(
      substrate,
      routeChainOf: (_) =>
          const <RouteEntry>[RouteEntry(providerId: 'p', model: 'm')],
    );
  });

  ProcedureEngine engineFor(
    Iterable<LoadedProcedure> procedures, {
    ProcedureTreeSink? procedureTreeSink,
  }) =>
      ProcedureEngine(
        resolver: ProcedureResolver(procedures),
        memory: memory,
        memoryBridge: memoryBridge,
        substrateBridge: substrateBridge,
        now: () => DateTime.utc(2026, 6, 2, 12, 0, 0),
        procedureTreeSink: procedureTreeSink,
      );

  Future<ProcedureResolver> systemResolver() async {
    final store = DiskProcedureStore(systemDir: Directory('scripts/system'));
    return ProcedureResolver.fromStore(store);
  }

  Future<ProcedureOutcome> runLoop({
    required Map<String, Object?> arguments,
    ProcedureTreeSink? procedureTreeSink,
  }) async {
    final resolver = await systemResolver();
    final engine = engineFor(
      resolver.ids.map(resolver.resolve).toList(),
      procedureTreeSink: procedureTreeSink,
    );
    return engine
        .invoke(ProcedureInvocation(
          procedureId: 'tool_loop_v1',
          arguments: arguments,
        ))
        .outcome;
  }

  // The descriptor `sub.run` would render and offer the loop: one read tool.
  const memoryReadTool = <String, Object?>{
    'name': 'memory.read',
    'group': 'memory',
    'description': 'read memory',
    'input_schema': <String, Object?>{
      'type': 'object',
      'required': <Object?>['text'],
      'properties': <String, Object?>{
        'text': <String, Object?>{'type': 'string'},
      },
    },
  };

  group('§7.2 execute → re-prompt → answer', () {
    test('a proposed memory.read reaches tool.invoke → memory.recall', () async {
      substrate
        ..proposeReadFor = 'the tool probe'
        ..answerText = 'answered after the tool ran';

      final outcome = await runLoop(arguments: <String, Object?>{
        'transcript': 'please use a tool',
        'route': 'default',
        'maxToolLoops': 4,
        'role': 'assistant_to_user',
        'tools': <Object?>[memoryReadTool],
        'temperature': 0.2,
      });

      // The loop ran the proposed tool through `tool.invoke`, which reached the
      // shipped `memory.read` tool, which called `memory.recall` with the text
      // the model proposed.
      expect(memory.recallQueries.map((q) => q.text), contains('the tool probe'));
      // The follow-up completion saw the folded-back tool result, then answered.
      final answeringPrompt = substrate.toolBearingPrompts.last;
      expect(answeringPrompt, contains('Tool results:'));
      expect(answeringPrompt, contains('memory.read'));
      // The run surfaced the model's answer and did not exhaust.
      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result!.output<String>('answer'),
          'answered after the tool ran');
      expect(outcome.result!.output<bool>('toolLoopExhausted'), false);
    });
  });

  group('§7.2 maxToolLoops cap', () {
    test('a substrate that always proposes a tool exhausts the cap', () async {
      substrate
        ..proposeReadFor = 'never stops'
        ..alwaysPropose = true;

      final outcome = await runLoop(arguments: <String, Object?>{
        'transcript': 'loop forever',
        'route': 'default',
        'maxToolLoops': 3,
        'tools': <Object?>[memoryReadTool],
      });

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result!.output<bool>('toolLoopExhausted'), true);
      // It issued exactly `maxToolLoops` completions — no more, no fewer.
      expect(substrate.completions, 3);
    });
  });

  group('§5.7.2 loop-termination reason', () {
    // The last node of the loop's tree is a note whose category states *why* the
    // loop stopped. `note(category, …)` rides the recorder → tree → NoteNode
    // path, so the category surfaces as a `ProcedureNoteNode` (no new node type).
    String? lastNoteCategory(ProcedureTreeRecord record) {
      for (final node in record.nodes.reversed) {
        if (node is ProcedureNoteNode) return node.category;
      }
      return null;
    }

    test('a plain answer emits "loop-complete: llm returned no tool call"',
        () async {
      substrate.answerText = 'plain answer';

      final records = <ProcedureTreeRecord>[];
      final outcome = await runLoop(
        arguments: <String, Object?>{
          'transcript': 'no tools needed',
          'route': 'default',
          'maxToolLoops': 4,
          'tools': <Object?>[],
        },
        procedureTreeSink: records.add,
      );

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(records, hasLength(1));
      expect(lastNoteCategory(records.single),
          'loop-complete: llm returned no tool call');
    });

    test('exhaustion on a pending tool call emits "loop-exhausted: max '
        'iterations reached"', () async {
      substrate
        ..proposeReadFor = 'never stops'
        ..alwaysPropose = true;

      final records = <ProcedureTreeRecord>[];
      final outcome = await runLoop(
        arguments: <String, Object?>{
          'transcript': 'loop forever',
          'route': 'default',
          'maxToolLoops': 2,
          'tools': <Object?>[memoryReadTool],
        },
        procedureTreeSink: records.add,
      );

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result!.output<bool>('toolLoopExhausted'), true);
      expect(records, hasLength(1));
      expect(lastNoteCategory(records.single),
          'loop-exhausted: max iterations reached');
    });
  });

  group('§7.2 none / empty catalogue answers in one turn', () {
    test('with no tools offered the model answers immediately', () async {
      substrate.answerText = 'plain answer';

      final outcome = await runLoop(arguments: <String, Object?>{
        'transcript': 'no tools needed',
        'route': 'default',
        'maxToolLoops': 4,
        'tools': <Object?>[],
      });

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result!.output<String>('answer'), 'plain answer');
      expect(outcome.result!.output<bool>('toolLoopExhausted'), false);
      // No tool was invoked, so memory saw no single-query recall.
      expect(memory.recallQueries, isEmpty);
      expect(substrate.completions, 1);
    });
  });
}

// ── A substrate that proposes a tool call, then answers ─────────────
//
// Keyed on whether the call carried a tool catalogue, mirroring D.43's double.
// With `proposeReadFor` set, the first tools-bearing call proposes
// `memory.read{text: proposeReadFor}`; subsequent tools-bearing calls answer,
// so the loop terminates — unless `alwaysPropose` is set, in which case every
// tools-bearing call proposes and the loop runs until `maxToolLoops`.
class _LoopSubstrate implements TomBrainSubstrateClient {
  String? proposeReadFor;
  bool alwaysPropose = false;
  String answerText = 'ok';

  bool _proposed = false;

  /// Total completions issued (every `sub.send` the loop made).
  int completions = 0;

  /// The prompts of every tools-bearing completion, in order.
  final List<String> toolBearingPrompts = <String>[];

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) {
    completions += 1;
    final hasTools = call.options.toolCatalogue.isNotEmpty;
    if (hasTools) {
      toolBearingPrompts.add(call.inputs['prompt']! as String);
    }

    const completed = LlmStreamCompleted(
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

    final shouldPropose =
        hasTools && proposeReadFor != null && (alwaysPropose || !_proposed);
    if (shouldPropose) {
      _proposed = true;
      return Stream<LlmStreamEvent>.fromIterable(<LlmStreamEvent>[
        LlmStreamToolCallProposed(
          callId: 'c',
          toolCallId: 'tc1',
          toolName: 'memory.read',
          arguments: <String, Object?>{'text': proposeReadFor!},
        ),
        completed,
      ]);
    }

    return Stream<LlmStreamEvent>.fromIterable(<LlmStreamEvent>[
      LlmStreamChunk(callId: 'c', text: answerText),
      completed,
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

// ── A recall-capturing `TomBrainMemory` (mirrors D.43's double) ─────
class _RecallCapturingMemory implements TomBrainMemory {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

  final List<RecallQuery> recallQueries = <RecallQuery>[];

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

  @override
  StackApi get stacks => _stacks;

  @override
  Future<RecallResult> recall(RecallQuery query) async {
    recallQueries.add(query);
    return recallResult;
  }

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
