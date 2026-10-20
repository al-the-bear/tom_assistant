// D.38c — `answer_with_memory_v1` tool-catalogue awareness
// (access spec § 7.2; procedure spec § 21.4).
//
// Regression suite for the live "which tools do you have?" defect: the model
// could not name its tools because the live answer path never told it any
// existed. `answer_with_memory_v1` runs under the `assistant_to_user` role and
// does not *call* tools (callable end-to-end invocation is the deferred
// `call_llm_v1` path), but it should still be *aware* of them — a memoryless
// substrate can only name a tool that appears in its prompt.
//
// The fix threads the default tool catalogue into the procedure as a
// `toolCatalogue` input (the dispatcher route injects `defaultToolCatalogue()`)
// and the procedure renders it as a "Tools available to you" block into the
// assembled prompt, ahead of the recall block and the live prompt.
//
// What this proves, against the shipped `scripts/system/` artifact:
//
//   1. TOOLS ARE RENDERED — each descriptor surfaces in the assembled prompt by
//      name (and group + description), so the model can answer "which tools do
//      you have?" from the prompt alone.
//   2. COLD — with no `toolCatalogue` input the prompt carries no tool block
//      (PE-9 regression guard): the prompt is exactly what it was before.
//
// The doubles mirror D.38b's recall/substrate stubs; only the invocation
// arguments differ (a `toolCatalogue` list alongside `text`).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, TrailId, Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

import 'answer_parity_prompts.dart';

void main() {
  late _RecallCapturingMemory memory;
  late _AnsweringSubstrate substrate;
  late MemoryBridge memoryBridge;
  late SubstrateBridge substrateBridge;
  late AnswerParityPrompts parity;

  setUp(() {
    memory = _RecallCapturingMemory();
    substrate = _AnsweringSubstrate();
    memoryBridge = MemoryBridge(memory);
    parity = AnswerParityPrompts();
    substrateBridge = SubstrateBridge(
      substrate,
      promptResolver: parity.resolver,
      routeChainOf: parity.routeChainOf,
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

  Future<ProcedureOutcome> runWith(
    String text, {
    List<Map<String, Object?>>? toolCatalogue,
  }) async {
    // Increment 6 (§7.4): the tool set is no longer a procedure input — it is
    // resolved from the answer prompt's tool policy. The parity resolver
    // surfaces whatever [AnswerParityPrompts.tools] holds, so a suite that wants
    // the substrate to see a catalogue sets it here.
    if (toolCatalogue != null) parity.tools = toolCatalogue;
    final resolver = await systemResolver();
    final engine = engineFor(resolver.ids.map(resolver.resolve).toList());
    return engine
        .invoke(
          ProcedureInvocation(
            procedureId: 'answer_with_memory_v1',
            arguments: <String, Object?>{'text': text},
          ),
        )
        .outcome;
  }

  group('D.38c-1 the tool catalogue is rendered into the assembled prompt', () {
    test('a tools question can be answered from the prompt alone', () async {
      await runWith(
        'which tools do you have?',
        toolCatalogue: defaultToolCatalogue(),
      );

      final prompt = substrate.lastCall!.inputs['prompt']! as String;
      // The model can name its tools because every descriptor reaches it.
      expect(prompt, contains('memory.read'));
      expect(prompt, contains('file.write'));
      expect(prompt, contains('procedure.run'));
      // Rendered under a tools header with the descriptor's description.
      expect(prompt, contains('Tools available to you'));
      expect(prompt, contains('Recalls nodes from memory'));
    });

    test('the tool block precedes the live user prompt', () async {
      await runWith(
        'which tools do you have?',
        toolCatalogue: defaultToolCatalogue(),
      );

      final prompt = substrate.lastCall!.inputs['prompt']! as String;
      expect(
        prompt.indexOf('Tools available to you'),
        lessThan(prompt.indexOf('which tools do you have?')),
      );
    });

    test(
      'the block explains how to invoke a tool with a call: example',
      () async {
        await runWith(
          'which tools do you have?',
          toolCatalogue: defaultToolCatalogue(),
        );

        final prompt = substrate.lastCall!.inputs['prompt']! as String;
        // The model must be told the exact, parseable call format — without it
        // (the live bug) it guesses its provider's native chat-template dialect.
        expect(prompt, contains('To use a tool'));
        expect(prompt, contains('call:'));
        // The how-to-call guidance follows the catalogue listing.
        expect(
          prompt.indexOf('Tools available to you'),
          lessThan(prompt.indexOf('To use a tool')),
        );
      },
    );
  });

  group('D.38c-3 each tool renders its argument schema (§ 9.1)', () {
    test(
      'todo.add / todo.remove / memory.read show their real arg keys',
      () async {
        await runWith(
          'which tools do you have?',
          toolCatalogue: defaultToolCatalogue(),
        );

        final prompt = substrate.lastCall!.inputs['prompt']! as String;
        // The live trail showed the model guessing `{item: …}` / `{description: …}`
        // for todo.add instead of the schema's `{text: …}`. The catalogue now
        // renders the exact key + type + required marker per tool, so the model
        // can copy the parameter names rather than guess them.
        expect(prompt, contains('args: {text: string (required)}'));
        expect(prompt, contains('args: {id: string (required)}'));
        expect(prompt, contains('args: {text: string (required), k: integer}'));
      },
    );

    test('a no-argument tool is rendered as taking no arguments', () async {
      await runWith(
        'which tools do you have?',
        toolCatalogue: defaultToolCatalogue(),
      );

      final prompt = substrate.lastCall!.inputs['prompt']! as String;
      // todo.list / procedure.list / file.readableRoots carry an empty
      // properties map — they render with empty `args: {}` braces (matching the
      // "empty braces" call instruction) rather than leaving the model to invent
      // some. Pinned to todo.list's full line so it cannot pass by coincidence.
      expect(prompt, contains('Lists the run-scoped todo entries. args: {}'));
    });

    test(
      'the worked call example uses a schema-correct parameter key',
      () async {
        await runWith(
          'which tools do you have?',
          toolCatalogue: defaultToolCatalogue(),
        );

        final prompt = substrate.lastCall!.inputs['prompt']! as String;
        // memory.read's schema requires `text`, not `query` — the single
        // authoritative example must match a real key so the model copies a
        // valid call.
        expect(prompt, contains('call:memory.read{text:'));
        expect(prompt, isNot(contains('call:memory.read{query')));
      },
    );
  });

  group(
    'D.38c-2 a run with no catalogue carries no tool block (PE-9 guard)',
    () {
      test('with no toolCatalogue the prompt holds no tool block', () async {
        await runWith('plain question');

        final prompt = substrate.lastCall!.inputs['prompt']! as String;
        expect(prompt, contains('plain question'));
        expect(prompt, isNot(contains('Tools available to you')));
      });

      test('an empty toolCatalogue list is treated as no tools', () async {
        await runWith(
          'plain question',
          toolCatalogue: const <Map<String, Object?>>[],
        );

        final prompt = substrate.lastCall!.inputs['prompt']! as String;
        expect(prompt, isNot(contains('Tools available to you')));
      });
    },
  );
}

// ── An answer-capturing `TomBrainSubstrateClient` ───────────────────
class _AnsweringSubstrate implements TomBrainSubstrateClient {
  LlmCall? lastCall;
  List<String> answerChunks = <String>['ok'];

  /// The opening line of the completion-confirmation prompt (agent-loop
  /// completion plan § 3.1, revision 2026-06-14). The trailing `sub.llm`
  /// confirmation call must NOT be captured as the answer call.
  static const String _confirmationSentinel =
      'You have just produced an answer for the user.';

  @override
  Stream<LlmEvent> completeStream(LlmCall call) {
    final rawPrompt = call.inputs['prompt'];
    final isConfirmation =
        call.roleId == 'assistant_to_user' &&
        rawPrompt is String &&
        rawPrompt.trimLeft().startsWith(_confirmationSentinel);
    // The confirmation call terminates the loop with `DONE`; only the answer
    // call is captured for assertion.
    if (isConfirmation) {
      return Stream<LlmEvent>.fromIterable(<LlmEvent>[
        const LlmTextDelta('DONE'),
        const LlmRunCompleted(
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
    lastCall = call;
    return Stream<LlmEvent>.fromIterable(<LlmEvent>[
      for (final chunk in answerChunks) LlmTextDelta(chunk),
      const LlmRunCompleted(
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ── A recall-capturing `TomBrainMemoryClient` ───────────────────────
//
// Returns an empty recall (this suite pins tool rendering, not recall) and
// models just enough of the store for the run recorder's writes to succeed.
// Mirrors the D.38b double.
class _RecallCapturingMemory implements TomBrainMemory {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

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
  Future<RecallResult> recall(RecallQuery query) async => recallResult;

  @override
  Future<RecallResult> recallMulti(MultiRecallQuery query) async =>
      recallResult;

  @override
  Future<ClassificationResult> classify(
    Vec embedding, {
    ClassificationTarget target = ClassificationTarget.nodeType,
  }) async => classifyResult;

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
  }) async => EdgeId.generate();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
