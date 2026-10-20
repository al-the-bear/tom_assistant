// passthrough_v1 — the SC-3 / no-memory relay procedure
// (`session_configuration.md` § 5.2; plan step 7; decisions SCP-26…SCP-28).
//
// `mode: passthrough` selects `passthrough_v1`: "no memory and no
// orchestration, not no engine" (SC-3). The procedure is a thin sub-only relay
// modelled on `prompt_analyzer_v1`'s shape — it imports the substrate bridge
// and nothing from memory, issues exactly one `sub.run` carrying the user's
// text through the active role, streams the completion back, and persists
// nothing. The "no memory" guarantee is **structural**: because the script
// never imports `memory_bridge.dart`, the d4rt `SandboxValidator` makes a
// `mem.*` call impossible (overview principle 7).
//
// This suite drives the *shipped* `scripts/system/passthrough_v1.dart` through
// the engine (the real store + resolver path, mirroring gt2 / d36–d42) and
// pins the three load-bearing guarantees of plan step 7:
//
//   1. **Exactly one `sub.run`.** The relay issues a single completion — no
//      classification turn, no recall pass, no answer re-entry. `callCount` is
//      the proof (mirrors gt2's route-flip-deferred assertion).
//   2. **Persists nothing.** The only nodes the run persists are the run
//      recorder's own `ProcedureRun` markers (start + final, Q-C.31.1); the
//      *body* writes no `Event` / `Conclusion` / any other node. The recorder
//      memory records every persisted `typeName`, so the assertion is that the
//      set is exactly `{ProcedureRun}` — anything else would be a body write.
//   3. **Touches no memory at all (structural).** The shipped script does not
//      import `memory_bridge.dart`; the missing import is what the sandbox
//      enforces. A source assertion pins the import is absent so a future edit
//      that re-introduces `mem.*` trips this test, not production.
//
// The relayed answer is surfaced under the `answer` output, streamed back to
// the caller exactly like the answer procedures.

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

void main() {
  late _RecorderMemory memory;
  late _RelaySubstrate substrate;
  late MemoryBridge memoryBridge;
  late SubstrateBridge substrateBridge;

  setUp(() {
    memory = _RecorderMemory();
    substrate = _RelaySubstrate();
    memoryBridge = MemoryBridge(memory);
    // passthrough_v1 runs `sub.run('assist_user.passthrough.relay')`; the host
    // resolver assembles the wire prompt the substrate sees. The stub resolves
    // any id (so the relay prompt id resolves) and the relay substrate returns
    // the canned reply as the completion's `answer`.
    final prompts = StubPromptResolver(role: 'assistant_to_user');
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
        now: () => DateTime.utc(2026, 6, 24, 12, 0, 0),
      );

  Future<ProcedureResolver> systemResolver() async {
    final store = DiskProcedureStore(systemDir: Directory('scripts/system'));
    return ProcedureResolver.fromStore(store);
  }

  Future<ProcedureOutcome> relay(String text) async {
    final resolver = await systemResolver();
    final engine = engineFor(resolver.ids.map(resolver.resolve).toList());
    return engine
        .invoke(
          ProcedureInvocation(
            procedureId: 'passthrough_v1',
            arguments: <String, Object?>{'text': text},
          ),
        )
        .outcome;
  }

  group('d55-1 the relay streams the upstream completion back', () {
    test(
      'the run is accepted and surfaces the completion as `answer`',
      () async {
        substrate.reply = 'The capital of France is Paris.';

        final outcome = await relay('what is the capital of France?');

        expect(outcome.status, TrailOutcomeStatus.accepted);
        expect(
          outcome.result!.output<String>('answer'),
          'The capital of France is Paris.',
        );
      },
    );
  });

  group('d55-2 exactly one sub.run, no extra orchestration', () {
    test('the relay issues a single substrate completion', () async {
      substrate.reply = 'ok';

      await relay('relay this verbatim');

      // A classification turn, a recall pass, or an answer re-entry would each
      // add a completion; the relay makes exactly one (SC-3 "one relay call").
      expect(substrate.callCount, 1);
    });
  });

  group('d55-3 the body persists nothing (no memory writes)', () {
    test(
      'the only persisted nodes are the recorder ProcedureRun markers',
      () async {
        substrate.reply = 'ok';

        await relay('relay this verbatim');

        // The run recorder persists the start + final ProcedureRun markers
        // (Q-C.31.1); the body itself writes no Event / Conclusion / any node.
        // Anything other than ProcedureRun in the persisted set would be a body
        // write — the no-memory guarantee broken.
        expect(memory.persistedTypeNames.toSet(), <String>{
          procedureRunNodeType,
        });
      },
    );
  });

  group('d55-4 the no-memory guarantee is structural (missing import)', () {
    test('the shipped script does not import the memory bridge', () async {
      final source = File(
        'scripts/system/passthrough_v1.dart',
      ).readAsStringSync();

      // The sandbox enforces "no mem.*" by the *absence* of this import — pin it
      // so a future edit that re-adds memory access trips here, not production.
      // Match an actual `import …memory_bridge.dart…` statement, not a mere
      // mention of the file name in a comment (the doc header explains the
      // deliberate omission).
      final importsMemoryBridge = RegExp(
        r"^\s*import\s+[^\n]*memory_bridge\.dart",
        multiLine: true,
      );
      expect(
        importsMemoryBridge.hasMatch(source),
        isFalse,
        reason:
            'passthrough_v1 must never import the memory bridge (SC-3); '
            'the missing import is the sandbox-enforced no-memory guarantee.',
      );
    });
  });
}

// ── A relay-only `TomBrainSubstrateClient` ──────────────────────────
//
// Emits the configured [reply] as a single completion chunk and counts calls
// so the "exactly one sub.run" assertion can prove the relay issues one
// completion. Mirrors gt2's `_VerdictSubstrate`, returning a plain answer
// instead of a verdict token.
class _RelaySubstrate implements TomBrainSubstrateClient {
  LlmCall? lastCall;
  int callCount = 0;
  String reply = 'ok';

  @override
  Stream<LlmEvent> completeStream(LlmCall call) {
    lastCall = call;
    callCount++;
    return Stream<LlmEvent>.fromIterable(<LlmEvent>[
      LlmTextDelta(reply),
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

// ── A recorder-only `TomBrainMemory` ────────────────────────────────
//
// passthrough_v1 touches no memory primitive — but the engine's run recorder
// still opens/appends/closes a trail and persists the ProcedureRun marker
// nodes. This double models just that recorder surface and records every
// persisted `typeName` so the "persists nothing" assertion can prove the body
// wrote no node beyond the recorder's own markers. Mirrors gt2's
// `_RecorderMemory`.
class _RecorderMemory implements TomBrainMemory {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

  /// Every persisted node's `typeName`, in persist order.
  final List<String> persistedTypeNames = <String>[];

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
    persistedTypeNames.add(draft.typeName);
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
