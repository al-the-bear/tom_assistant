// D.8 — `answer_with_memory_v1` stub acceptance suite.
//
// Plan step D.8 (verbatim): "Add `scripts/system/answer_with_memory_v1.dart`
// as a stub."
//
// The stub is the callable target the Phase D dispatcher routes every
// inbound `user_prompt` to (D.16); the real recall→answer→persist body lands
// at D.10 (D.36–D.42). At D.8 the proof obligation is exactly the one the
// shipped `think_v1` stub carries (mirrored from `sugar_aliases_test.dart`
// group C.40-4):
//
//   1. STUB ON DISK   — `scripts/system/answer_with_memory_v1.dart` exists
//                       and loads from the real store+resolver path with a
//                       valid `answer_with_memory_v1` v1 header that requires
//                       no bridged primitive (a no-op stub).
//   2. RUNS ACCEPTED  — invoking it through the engine resolves an accepted
//                       outcome whose result carries the `stub` marker, so we
//                       know *this* procedure (not some other) ran.
//   3. COEXISTS       — the real `scripts/system/` directory now ships two
//                       system stubs (`think_v1` + `answer_with_memory_v1`)
//                       and the resolver indexes both without clashing.
//
// The stub calls only its own (empty) body — never `mem` / `sub` — so the
// substrate double is inert and the memory double is the same stateful
// in-memory client the C.38/C.39 engine + C.40 sugar suites use (the
// recorder still writes a real trail + run record around the run).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, TrailId, Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';

void main() {
  late _StatefulMemory memory;
  late _InertSubstrate substrate;
  late MemoryBridge memoryBridge;
  late SubstrateBridge substrateBridge;

  setUp(() {
    memory = _StatefulMemory();
    substrate = _InertSubstrate();
    memoryBridge = MemoryBridge(memory);
    substrateBridge = SubstrateBridge(substrate);
  });

  ProcedureEngine engineFor(Iterable<LoadedProcedure> procedures) =>
      ProcedureEngine(
        resolver: ProcedureResolver(procedures),
        memory: memory,
        memoryBridge: memoryBridge,
        substrateBridge: substrateBridge,
        now: () => DateTime.utc(2026, 6, 2, 12, 0, 0),
      );

  /// Builds a resolver over the real `scripts/system/` directory — the same
  /// store+resolver path the dispatcher uses, so the test exercises the
  /// shipped artifact rather than an inline copy.
  Future<ProcedureResolver> systemResolver() async {
    final store = DiskProcedureStore(systemDir: Directory('scripts/system'));
    return ProcedureResolver.fromStore(store);
  }

  group('D.8-1 the stub is on disk and loads with a valid header', () {
    test('scripts/system/answer_with_memory_v1.dart exists', () {
      expect(
        File('scripts/system/answer_with_memory_v1.dart').existsSync(),
        isTrue,
        reason: 'D.8 must add the answer_with_memory_v1 system stub',
      );
    });

    test('the disk stub parses with the answer_with_memory_v1 v1 header',
        () async {
      final resolver = await systemResolver();
      final stub = resolver.resolve('answer_with_memory_v1');
      expect(stub.header.id, 'answer_with_memory_v1');
      expect(stub.header.version, 1);
      // A pure no-op at D.8: it requires no bridged primitive (the real
      // recall/llm/persist/edge list arrives with the body at D.10).
      expect(stub.header.requires, isEmpty);
      // The intended budget caps are declared up front (D.36).
      expect(stub.header.budget.wallClockMs, 60000);
    });
  });

  group('D.8-2 invoking the stub resolves an accepted outcome', () {
    test('answer_with_memory_v1 runs to an accepted stub outcome', () async {
      final resolver = await systemResolver();
      final engine = engineFor(<LoadedProcedure>[
        resolver.resolve('answer_with_memory_v1'),
      ]);

      final outcome = await engine
          .invoke(ProcedureInvocation(procedureId: 'answer_with_memory_v1'))
          .outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted);
      // The stub's `{'stub': 'answer_with_memory_v1'}` flowed back unchanged.
      expect(outcome.result!.output<String>('stub'), 'answer_with_memory_v1');

      // The recorder wrote the run to `recent_runs` (one run — the stub).
      final recent = await memory.stacks.peek(recentRunsStackName);
      expect(recent, hasLength(1));
    });
  });

  group('D.8-3 the two system stubs coexist in the shipped directory', () {
    test('the resolver indexes both think_v1 and answer_with_memory_v1',
        () async {
      final resolver = await systemResolver();
      expect(resolver.knows('think_v1'), isTrue);
      expect(resolver.knows('answer_with_memory_v1'), isTrue);
      expect(resolver.ids, containsAll(<String>['answer_with_memory_v1', 'think_v1']));
    });
  });
}

// ── An inert `TomBrainSubstrateClient` ──────────────────────────────
//
// The stub never calls `sub`, so the substrate double only needs to satisfy
// the bridge/engine constructor; its members fall through to `noSuchMethod`.
class _InertSubstrate implements TomBrainSubstrateClient {
  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) =>
      StreamController<LlmStreamEvent>().stream;

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

// ── A stateful in-memory `TomBrainMemoryClient` ─────────────────────
//
// Models just enough of the store for the recorder's writes to be read back:
// trails are ordered entry logs, stacks are push/peek/remove containers,
// persisted nodes are resolvable by id. Copied from the C.40 sugar suite;
// unimplemented members fall through to `noSuchMethod`.
class _StatefulMemory implements TomBrainMemoryClient {
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
