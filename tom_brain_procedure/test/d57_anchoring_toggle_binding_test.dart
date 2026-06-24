// d57 — per-run anchoring toggle binding (`session_configuration.md` § 3.4;
// plan step 9; decisions SCP-36…SCP-38).
//
// Step 9 threads `Access.profile.anchored` (a `ResolvedProfile` bool, default
// `true`) onto the run so the engine stamps it on every `LlmCall` it issues.
// The wire-prompt-level present/absent guarantee — `anchored:true` carries the
// assistant-dedication anchor, `anchored:false` omits it — is pinned at the
// substrate level in `tom_brain_substrate/test/b54_anchoring_toggle_test.dart`.
//
// This suite pins the *engine binding*: that the per-run `SubstrateBridge`
// reads the profile's `anchored` field and stamps it onto the issued
// `LlmCall`, mirroring d56-4's `lastCall.roleId` role-pin proof. The substrate
// double records the last `LlmCall`, so the assertion reads
// `substrate.lastCall!.anchored` directly.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        EdgeId,
        NodeId,
        ProfileMode,
        ResolvedProfile,
        StackEntryId,
        TrailId,
        Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

import 'stub_prompt_resolver.dart';

void main() {
  // ── d57 the profile anchored flag is stamped on the wire call ────────
  group('d57 the profile anchored flag is stamped on the LlmCall', () {
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

    ResolvedProfile passthrough({bool anchored = true}) => ResolvedProfile(
          id: 'r',
          mode: ProfileMode.passthrough,
          entryProcedure: 'passthrough_v1',
          role: 'assistant_to_user',
          anchored: anchored,
        );

    test('a default profile stamps anchored:true on the call', () async {
      final prompts = StubPromptResolver(role: 'assistant_to_user');
      final engine = engineFor(prompts);

      await engine
          .invoke(ProcedureInvocation(
            procedureId: 'passthrough_v1',
            arguments: const <String, Object?>{'text': 'hi'},
            profile: passthrough(),
          ))
          .outcome;

      expect(substrate.lastCall!.anchored, isTrue);
    });

    test('an un-anchored profile stamps anchored:false on the call', () async {
      final prompts = StubPromptResolver(role: 'assistant_to_user');
      final engine = engineFor(prompts);

      await engine
          .invoke(ProcedureInvocation(
            procedureId: 'passthrough_v1',
            arguments: const <String, Object?>{'text': 'hi'},
            profile: passthrough(anchored: false),
          ))
          .outcome;

      expect(substrate.lastCall!.anchored, isFalse);
    });

    test('with no profile the call defaults to anchored:true', () async {
      final prompts = StubPromptResolver(role: 'assistant_to_user');
      final engine = engineFor(prompts);

      await engine
          .invoke(ProcedureInvocation(
            procedureId: 'passthrough_v1',
            arguments: const <String, Object?>{'text': 'hi'},
          ))
          .outcome;

      expect(substrate.lastCall!.anchored, isTrue);
    });
  });
}

// ── A substrate double recording the last call + embedding ──────────
//
// `completeStream` records the issuing [LlmCall] (so the anchored assertion can
// read `lastCall.anchored`) and emits a single canned answer chunk. Mirrors the
// `_Substrate` double in d56.
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
// Models just enough of the store for the recorder's writes to flow. Mirrors
// the `_Memory` double in d56.
class _Memory implements TomBrainMemory {
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
