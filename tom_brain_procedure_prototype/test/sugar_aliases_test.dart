// C.40 — sugar aliases (`think` / `plan` / `create` / `critique` /
// `decide`) acceptance suite.
//
// Plan step C.40 (verbatim): "Implement the sugar `think(…)`, `plan(…)`,
// `create(…)`, `critique(…)`, `decide(…)` as bridged aliases over
// `runProcedure('<name>_v1', …)`. For the prototype only `think_v1` exists
// as a no-op stub procedure script; the others throw `ProcedureNotFound`
// informatively until Phase D loads the system library."
//
// These tests pin the four facts that make the sugar correct:
//
//   1. MAPPING   — the verb → `<name>_v1` table is exactly the five spec
//                  verbs (§ 5.2), each mapped to its `_v1` procedure id.
//   2. THINK     — `think(inputs)` from a script resolves to `think_v1`
//                  and runs the no-op stub; the stub's result threads back
//                  to the caller unchanged, and both runs are recorded.
//   3. MISSING   — `plan` / `create` / `critique` / `decide` resolve to a
//                  missing `<name>_v1` and surface `ProcedureNotFound`
//                  informatively (the run closes `errored`, the captured
//                  error names the absent id).
//   4. STUB      — the shipped `scripts/system/think_v1.dart` loads with a
//                  valid header and runs to an accepted outcome both when
//                  invoked directly and via the `think` alias.
//
// The scripts here call only the engine-native sugar verbs (which delegate
// to `runProcedure`), never `mem` / `sub`, so the substrate double is inert
// and the memory double is the same stateful in-memory client the C.38/C.39
// engine suite uses (the recorder writes a real trail + run record).

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
        now: () => DateTime.utc(2026, 6, 1, 12, 0, 0),
      );

  /// The shipped no-op stub, loaded from disk through the real store +
  /// resolver path so the test exercises the actual `scripts/system/`
  /// artifact rather than an inline copy.
  Future<LoadedProcedure> loadThinkStub() async {
    final store = DiskProcedureStore(systemDir: Directory('scripts/system'));
    final resolver = await ProcedureResolver.fromStore(store);
    return resolver.resolve('think_v1');
  }

  group('C.40-1 the verb → procedure-id mapping is the five spec verbs', () {
    test('exactly think/plan/create/critique/decide map to their _v1 ids', () {
      expect(
        sugarAliasProcedureIds,
        equals(<String, String>{
          'think': 'think_v1',
          'plan': 'plan_v1',
          'create': 'create_v1',
          'critique': 'critique_v1',
          'decide': 'decide_v1',
        }),
      );
      // Every value is its key + `_v1` — the fixed-id projection contract.
      for (final entry in sugarAliasProcedureIds.entries) {
        expect(entry.value, '${entry.key}_v1');
      }
    });
  });

  group('C.40-2 think(inputs) resolves to think_v1 and runs the stub', () {
    test('the stub result threads back to the caller via the think alias',
        () async {
      final thinkStub = await loadThinkStub();
      final engine = engineFor(<LoadedProcedure>[
        _procedure(
          'caller_v1',
          '''
import '$engineNativeLibrary';

Future<Object?> run(inputs) async {
  return await think(inputs);
}
''',
        ),
        thinkStub,
      ]);

      final outcome = await engine
          .invoke(ProcedureInvocation(procedureId: 'caller_v1'))
          .outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted);
      // The stub's `{'stub': 'think_v1'}` flowed back unchanged through the
      // sugar alias, the nested run, and the caller's return.
      expect(outcome.result!.output<String>('stub'), 'think_v1');

      // Two runs were recorded — the caller and the nested think_v1.
      final recent = await memory.stacks.peek(recentRunsStackName);
      expect(recent, hasLength(2));
    });

    test('think forwards its named depthDelta to runProcedure', () async {
      // A depthDelta of 2 advances the chain two levels; think_v1 then runs
      // at depth 3 (caller is depth 1). The run still completes accepted —
      // the delta is honoured, not the cap (well under 10).
      final thinkStub = await loadThinkStub();
      final engine = engineFor(<LoadedProcedure>[
        _procedure(
          'caller_v1',
          '''
import '$engineNativeLibrary';

Future<Object?> run(inputs) async {
  return await think(inputs, depthDelta: 2);
}
''',
        ),
        thinkStub,
      ]);

      final outcome = await engine
          .invoke(ProcedureInvocation(procedureId: 'caller_v1'))
          .outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result!.output<String>('stub'), 'think_v1');
    });
  });

  group('C.40-3 the unimplemented verbs surface ProcedureNotFound', () {
    for (final verb in const <String>['plan', 'create', 'critique', 'decide']) {
      test('$verb resolves to a missing ${verb}_v1 and closes errored',
          () async {
        final engine = engineFor(<LoadedProcedure>[
          _procedure(
            'caller_v1',
            '''
import '$engineNativeLibrary';

Future<Object?> run(inputs) async {
  return await $verb(inputs);
}
''',
          ),
          // Note: no `${verb}_v1` is loaded — the resolver does not know it.
        ]);

        final outcome = await engine
            .invoke(ProcedureInvocation(procedureId: 'caller_v1'))
            .outcome;

        // The missing target crashes the caller; the run closes errored and
        // the captured error informatively names the absent procedure id.
        expect(outcome.status, TrailOutcomeStatus.errored);
        expect(outcome.error, isA<ProcedureNotFound>());
        final notFound = outcome.error! as ProcedureNotFound;
        expect(notFound.id, '${verb}_v1');
        expect(notFound.code, procedureNotFoundCode);

        // The crash reached the trail as a runtime-crash error entry.
        final errors = outcome.entries
            .where((e) => e.kind == TrailEntryKind.error)
            .toList();
        expect(errors, hasLength(1));
      });
    }
  });

  group('C.40-4 the shipped think_v1 stub is valid and runs', () {
    test('the disk stub parses with the think_v1 v1 header', () async {
      final stub = await loadThinkStub();
      expect(stub.header.id, 'think_v1');
      expect(stub.header.version, 1);
      // A pure no-op: it requires no primitives.
      expect(stub.header.requires, isEmpty);
    });

    test('invoking think_v1 directly resolves an accepted stub outcome',
        () async {
      final engine = engineFor(<LoadedProcedure>[await loadThinkStub()]);

      final outcome = await engine
          .invoke(ProcedureInvocation(procedureId: 'think_v1'))
          .outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result!.output<String>('stub'), 'think_v1');
    });
  });
}

/// Builds a [LoadedProcedure] from [body], wrapping it in a minimal valid
/// `@procedure` header (§ 4.4) so the resolver treats it as a real
/// procedure. Mirrors the helper the C.38/C.39 engine suite uses.
LoadedProcedure _procedure(String id, String body, {int version = 1}) {
  final source = '''
/// @procedure
/// id: $id
/// version: $version
/// summary: a test procedure
/// successCriterion: returns a value
/// budget: { wallClockMs: 60000 }
$body
''';
  return ProcedureLoader.shared.load(
    ProcedureSource(
      ref: ProcedureRef.system('/procedures/$id.dart'),
      source: source,
    ),
  );
}

// ── An inert `TomBrainSubstrateClient` ──────────────────────────────
//
// The sugar scripts here never call `sub`, so the substrate double only
// needs to satisfy the bridge/engine constructor; its members fall through
// to `noSuchMethod`. `embed` is concrete only because the bridge may probe
// the embedding model identity at construction in other suites; here it is
// never reached.
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
// Models just enough of the store for the recorder's writes to be read
// back: trails are ordered entry logs, stacks are push/peek/remove
// containers, persisted nodes are resolvable by id. Copied from the
// C.38/C.39 engine suite; unimplemented members fall through to
// `noSuchMethod`.
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
