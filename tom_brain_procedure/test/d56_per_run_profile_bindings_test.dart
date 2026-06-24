// d56 — per-run profile bindings: role / overlay / MCP / budget
// (`session_configuration.md` § 3.3 / § 3.4 / § 3.6 / § 5.3 / § 5.4; plan
// step 8; decisions SCP-30…SCP-34).
//
// Step 8 threads `Access.profile` (a `ResolvedProfile`) onto the run so the
// engine binds four behavioural knobs per run, each sourced from the profile
// and inert (today's behaviour) when the profile is absent:
//
//   (a) role     — the profile's pinned role fills the substrate call's role
//                  *only when the procedure names none* (an empty `ResolvedPrompt
//                  .role`); a procedure that names its own role keeps it.
//   (b) overlay  — `LayeredPromptResolver(base, overlay)` shadows the base
//                  registry with a profile overlay, falling through to base on a
//                  missing overlay id, and re-reading the overlay live per call.
//   (c) MCP      — the run's offered-server set is the profile's already-composed
//                  allowlist intersected with the dynamic global liveness gate;
//                  an empty allowlist is the "all globally-exposed" sentinel.
//   (d) budget   — the entry procedure's header budget tightened (never loosened)
//                  by the profile's per-dimension overrides.
//
// These suites pin the load-bearing guarantees of plan step 8. The unit groups
// (d56-1…d56-3) drive the three new pure seams directly; the engine groups
// (d56-4…d56-6) drive a real run through `ProcedureEngine` (mirroring c51 /
// memory_write_guard / d55) to prove the bindings are wired, not just present.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        EdgeId,
        NodeId,
        ProfileBudget,
        ProfileMode,
        ResolvedProfile,
        StackEntryId,
        TrailId,
        Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

import 'stub_prompt_resolver.dart';

void main() {
  // ── d56-1 LayeredPromptResolver: shadow / fall-through / live edit ──
  group('d56-1 LayeredPromptResolver overlays the base registry', () {
    PromptResolver mapResolver(Map<String, ResolvedPrompt> backing) =>
        (String id, Map<String, Object?> inputs) async => backing[id];

    ResolvedPrompt prompt(String role) =>
        ResolvedPrompt(role: role, llmRoute: 'r', templateBody: 'body');

    test('an overlay-defined id shadows the base prompt', () async {
      final layered = LayeredPromptResolver(
        base: mapResolver(<String, ResolvedPrompt>{'p': prompt('base')}),
        overlay: mapResolver(<String, ResolvedPrompt>{'p': prompt('overlay')}),
      );

      final resolved = await layered.resolve('p', const <String, Object?>{});
      expect(resolved!.role, 'overlay');
    });

    test('a missing overlay id falls through to the base prompt', () async {
      final layered = LayeredPromptResolver(
        base: mapResolver(<String, ResolvedPrompt>{'p': prompt('base')}),
        overlay: mapResolver(const <String, ResolvedPrompt>{}),
      );

      final resolved = await layered.resolve('p', const <String, Object?>{});
      expect(resolved!.role, 'base');
    });

    test('an id absent from both layers resolves to null (still fatal)',
        () async {
      final layered = LayeredPromptResolver(
        base: mapResolver(const <String, ResolvedPrompt>{}),
        overlay: mapResolver(const <String, ResolvedPrompt>{}),
      );

      expect(await layered.resolve('missing', const <String, Object?>{}),
          isNull);
    });

    test('the overlay is re-read live — an edit between calls is seen',
        () async {
      final overlayBacking = <String, ResolvedPrompt>{};
      final layered = LayeredPromptResolver(
        base: mapResolver(<String, ResolvedPrompt>{'p': prompt('base')}),
        overlay: mapResolver(overlayBacking),
      );

      // First call: overlay has no 'p' → fall through to base.
      expect((await layered.resolve('p', const <String, Object?>{}))!.role,
          'base');

      // Edit the overlay backing — the next resolve must shadow live.
      overlayBacking['p'] = prompt('edited');
      expect((await layered.resolve('p', const <String, Object?>{}))!.role,
          'edited');
    });

    test('asResolver exposes the layered lookup as a PromptResolver', () async {
      final layered = LayeredPromptResolver(
        base: mapResolver(<String, ResolvedPrompt>{'p': prompt('base')}),
        overlay: mapResolver(<String, ResolvedPrompt>{'p': prompt('overlay')}),
      );
      final PromptResolver asResolver = layered.asResolver;

      final resolved = await asResolver('p', const <String, Object?>{});
      expect(resolved!.role, 'overlay');
    });
  });

  // ── d56-2 composeMcpGate: allowlist ∩ global liveness gate ──────────
  group('d56-2 composeMcpGate composes the offered-server set', () {
    test('an empty allowlist + no global gate → null (all-exposed sentinel)',
        () {
      expect(composeMcpGate(const <String>[], null), isNull);
    });

    test('an empty allowlist keeps the global gate verbatim', () {
      // exposeToLlms:false (or dead) servers fail the global gate and are
      // never offered even under the all-exposed sentinel.
      bool global(String s) => s != 'closed';
      final gate = composeMcpGate(const <String>[], global)!;

      expect(gate('closed'), isFalse);
      expect(gate('open'), isTrue);
    });

    test('a profile allowlist restricts to its own members', () {
      final gate = composeMcpGate(const <String>['profSrv'], null)!;

      expect(gate('profSrv'), isTrue); // profile-defined server offered
      expect(gate('other'), isFalse); // outside the allowlist
    });

    test('the allowlist is intersected with the global liveness gate', () {
      bool global(String s) => s != 'closed';
      final gate = composeMcpGate(const <String>['profSrv', 'closed'], global)!;

      expect(gate('profSrv'), isTrue); // allow-listed + globally open
      expect(gate('closed'), isFalse); // exposeToLlms:false → never offered
      expect(gate('stranger'), isFalse); // not in the allowlist
    });
  });

  // ── d56-3 effectiveProcedureBudget: tighten + clamp ─────────────────
  group('d56-3 effectiveProcedureBudget tightens the header budget', () {
    test('a profile cap tighter than the header wins (min)', () {
      final eff = effectiveProcedureBudget(
        ProcedureBudget(<String, int>{'wallClockMs': 60000, 'toolCalls': 10}),
        const ProfileBudget(maxToolCalls: 2),
      );

      expect(eff.toolCalls, 2);
      expect(eff.wallClockMs, 60000); // untouched dimension preserved
    });

    test('a looser profile cap cannot raise the header (clamp to header)', () {
      final eff = effectiveProcedureBudget(
        ProcedureBudget(<String, int>{'toolCalls': 10}),
        const ProfileBudget(maxToolCalls: 50),
      );

      expect(eff.toolCalls, 10);
    });

    test('a profile cap fills a dimension the header omits', () {
      final eff = effectiveProcedureBudget(
        ProcedureBudget(<String, int>{'wallClockMs': 60000}),
        const ProfileBudget(
          maxTokens: 8000,
          wallClock: Duration(milliseconds: 30000),
        ),
      );

      expect(eff.tokenSpend, 8000); // maxTokens → tokenSpend
      expect(eff.wallClockMs, 30000); // wallClock tightens 60000 → 30000
    });

    test('a null profile leaves the header unchanged', () {
      final header = ProcedureBudget(<String, int>{'toolCalls': 7});
      expect(effectiveProcedureBudget(header, null), header);
    });

    test('maxLlmCalls has no procedure dimension and is dropped', () {
      final eff = effectiveProcedureBudget(
        ProcedureBudget(<String, int>{'toolCalls': 5}),
        const ProfileBudget(maxLlmCalls: 3),
      );

      expect(eff.raw.containsKey('llmCalls'), isFalse);
      expect(eff.toolCalls, 5);
    });
  });

  // ── d56-4 role pin: the profile role fills an empty procedure role ──
  group('d56-4 the profile role pins the wire prompt role', () {
    late _Substrate substrate;
    late _Memory memory;

    setUp(() {
      substrate = _Substrate();
      memory = _Memory();
    });

    ProcedureEngine engineFor(StubPromptResolver prompts) {
      final substrateBridge = SubstrateBridge(
        substrate,
        promptResolver: prompts.resolver,
        routeChainOf: prompts.routeChainOf,
      );
      return ProcedureEngine(
        resolver: ProcedureResolver(<LoadedProcedure>[]),
        procedureReloadStore:
            DiskProcedureStore(systemDir: Directory('scripts/system')),
        memory: memory,
        memoryBridge: MemoryBridge(memory),
        substrateBridge: substrateBridge,
        now: () => DateTime.utc(2026, 6, 24, 12, 0, 0),
      );
    }

    ResolvedProfile passthroughWithRole(String? role) => ResolvedProfile(
          id: 'r',
          mode: ProfileMode.passthrough,
          entryProcedure: 'passthrough_v1',
          role: role,
        );

    test('an empty procedure role is filled by the profile role', () async {
      final prompts = StubPromptResolver(role: ''); // procedure names no role
      final engine = engineFor(prompts);

      await engine
          .invoke(ProcedureInvocation(
            procedureId: 'passthrough_v1',
            arguments: const <String, Object?>{'text': 'hi'},
            profile: passthroughWithRole('researcher'),
          ))
          .outcome;

      expect(substrate.lastCall!.roleId, 'researcher');
    });

    test('a procedure-named role is not overridden by the profile role',
        () async {
      final prompts = StubPromptResolver(role: 'analyst');
      final engine = engineFor(prompts);

      await engine
          .invoke(ProcedureInvocation(
            procedureId: 'passthrough_v1',
            arguments: const <String, Object?>{'text': 'hi'},
            profile: passthroughWithRole('researcher'),
          ))
          .outcome;

      expect(substrate.lastCall!.roleId, 'analyst');
    });
  });

  // ── d56-5 budget tighten + clamp, driven through the engine ─────────
  group('d56-5 the profile budget tightens the run budget', () {
    late _Substrate substrate;
    late _Memory memory;

    setUp(() {
      substrate = _Substrate();
      memory = _Memory();
    });

    ProcedureEngine engineFor(Iterable<LoadedProcedure> procedures) =>
        ProcedureEngine(
          resolver: ProcedureResolver(procedures),
          memory: memory,
          memoryBridge: MemoryBridge(memory),
          substrateBridge: SubstrateBridge(substrate),
          now: () => DateTime.utc(2026, 6, 24, 12, 0, 0),
        );

    LoadedProcedure embedTwice(String budget) => _procedure(
          'greedy_v1',
          '''
import '${BridgeLibraries.substrateLibrary}';

Future<Object?> run(inputs) async {
  await sub.embed('first');
  await sub.embed('second');
  return 1;
}
''',
          budget: budget,
        );

    ResolvedProfile profileBudget(ProfileBudget? budget) => ResolvedProfile(
          id: 'r',
          mode: ProfileMode.answer,
          entryProcedure: 'greedy_v1',
          budget: budget,
        );

    test('a tighter profile toolCalls cap refuses the second tool call',
        () async {
      // Header allows 5 tool calls; the profile tightens it to 1.
      final engine = engineFor(<LoadedProcedure>[
        embedTwice('{ wallClockMs: 60000, toolCalls: 5 }'),
      ]);

      final outcome = await engine
          .invoke(ProcedureInvocation(
            procedureId: 'greedy_v1',
            profile: profileBudget(const ProfileBudget(maxToolCalls: 1)),
          ))
          .outcome;

      expect(outcome.status, TrailOutcomeStatus.budgetExceeded);
      expect(outcome.error, isA<ProcedureBudgetExceeded>());
      expect((outcome.error! as ProcedureBudgetExceeded).limit, 1);
    });

    test('a looser profile cap cannot loosen the header (still refused)',
        () async {
      // Header allows 1 tool call; the profile asks for 50 — the header wins.
      final engine = engineFor(<LoadedProcedure>[
        embedTwice('{ wallClockMs: 60000, toolCalls: 1 }'),
      ]);

      final outcome = await engine
          .invoke(ProcedureInvocation(
            procedureId: 'greedy_v1',
            profile: profileBudget(const ProfileBudget(maxToolCalls: 50)),
          ))
          .outcome;

      expect(outcome.status, TrailOutcomeStatus.budgetExceeded);
      expect((outcome.error! as ProcedureBudgetExceeded).limit, 1);
    });

    test('without a profile budget the header alone governs', () async {
      // Header allows 5 tool calls; no profile override → two embeds pass.
      final engine = engineFor(<LoadedProcedure>[
        embedTwice('{ wallClockMs: 60000, toolCalls: 5 }'),
      ]);

      final outcome = await engine
          .invoke(ProcedureInvocation(
            procedureId: 'greedy_v1',
            profile: profileBudget(null),
          ))
          .outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.record.effort.toolCalls, 2);
    });
  });

  // ── d56-6 mem.* is unaffected by the MCP allowlist ──────────────────
  group('d56-6 the MCP allowlist does not gate memory writes', () {
    late _Substrate substrate;
    late _Memory memory;

    setUp(() {
      substrate = _Substrate();
      memory = _Memory();
    });

    test('a restrictive profile MCP allowlist still lets mem.persist write',
        () async {
      final engine = ProcedureEngine(
        resolver: ProcedureResolver(<LoadedProcedure>[
          _procedure(
            'writer_v1',
            '''
import '${BridgeLibraries.memoryLibrary}';

Future<Object?> run(inputs) async {
  await mem.persist('Event', {'summary': 'x'}, producer: 'p');
  return {'done': true};
}
''',
            budget: '{ wallClockMs: 60000 }',
          ),
        ]),
        memory: memory,
        memoryBridge: MemoryBridge(memory),
        substrateBridge: SubstrateBridge(substrate),
        now: () => DateTime.utc(2026, 6, 24, 12, 0, 0),
      );

      final outcome = await engine
          .invoke(ProcedureInvocation(
            procedureId: 'writer_v1',
            // A profile whose MCP allowlist excludes every server — mem.* must
            // be untouched by the MCP list (it routes through MemoryBridge).
            profile: ResolvedProfile(
              id: 'r',
              mode: ProfileMode.answer,
              entryProcedure: 'writer_v1',
              offeredMcpServers: const <String>['nonexistent'],
            ),
          ))
          .outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted);
      // The recorder writes its own ProcedureRun markers; the body's Event is
      // the extra write the MCP allowlist must not have blocked.
      expect(memory.persistedTypeNames, contains('Event'));
    });
  });
}

/// Builds a [LoadedProcedure] from [body] with a configurable [budget] block
/// (mirrors the inline-procedure helper in `c51_budget_enforcement_test.dart`).
LoadedProcedure _procedure(
  String id,
  String body, {
  required String budget,
  int version = 1,
}) {
  final source = '''
/// @procedure
/// id: $id
/// version: $version
/// summary: a test procedure
/// successCriterion: returns a value
/// budget: $budget
$body
''';
  return ProcedureLoader.shared.load(
    ProcedureSource(
      ref: ProcedureRef.system('/procedures/$id.dart'),
      source: source,
    ),
  );
}

// ── A substrate double recording the last call + embedding ──────────
//
// `completeStream` records the issuing [LlmCall] (so the role assertion can
// read `lastCall.roleId`) and emits a single canned answer chunk; `embed`
// returns a unit vector so a budget-probing `sub.embed` works. Mirrors the
// `_RelaySubstrate` / `_EmbeddingSubstrate` doubles in d55 / c51.
class _Substrate implements TomBrainSubstrateClient {
  LlmCall? lastCall;
  int callCount = 0;
  String reply = 'ok';

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) {
    lastCall = call;
    callCount++;
    return Stream<LlmStreamEvent>.fromIterable(<LlmStreamEvent>[
      LlmStreamChunk(callId: 'c', text: reply),
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
// Models just enough of the store for the recorder's writes and a body's
// `mem.persist` to be read back. Records every persisted `typeName` and counts
// the persist calls. Mirrors the doubles in d55 / c51.
class _Memory implements TomBrainMemory {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

  /// Every persisted node's `typeName`, in persist order.
  final List<String> persistedTypeNames = <String>[];

  /// The number of `persist` calls that reached the store.
  int persistCalls = 0;

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
    persistCalls++;
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
