// Todo-4 — clear-error stub verbs + the procedure-as-tool surface
// (`tom_brain_procedure_prototype_specification.md` § 5.2.1, § 11;
// `tom_brain_completion_plan.md` Todo 4 / G-PR6 / G-PR7).
//
// What this suite locks (the Todo-4 "done when"):
//
//   G-PR6 — each clear-error stub (`plan_v1` / `create_v1` / `critique_v1` /
//           `decide_v1`):
//             • RESOLVES from `scripts/system/` with its `<verb>_v1` v1 header
//               and a `requires: [notImplemented]` declaration;
//             • VALIDATES — passes the strict `ContractValidator` (entry-point
//               signature + `requires`-vs-calls), which the no-op `think_v1`
//               stub cannot (it returns a Map, not a `ProcedureResult`);
//             • is TOOL-LISTABLE — surfaces in the bound engine surface's
//               `procedure.list`;
//             • THROWS the clear error when invoked at top level — the typed
//               `ProcedureNotImplemented` (carried through to `outcome.error`),
//               **never** the bare `ProcedureNotFound`. The message names the
//               stub, the loop to implement, and the verb.
//
//   G-PR7 — the procedure-as-tool surface works end-to-end through the *real*
//           bound `ToolEngineSurface` (not a test double):
//             • the generic `procedure.run` invokes an existing procedure
//               (`think_v1`) and surfaces its succeeded status + outputs;
//             • `procedure.run` against a stub surfaces a `failed` status (the
//               nested stub's throw is swallowed into a failed result on the
//               sugar/tool path — the typed signal lives on the nested run's
//               trail, top-level invoke is where it reaches `outcome.error`);
//             • the four explicit verb tools (`procedure.plan` / `create` /
//               `critique` / `decide`) are registered and route to `<verb>_v1`.
//
// The verbs reachable from both an answering script and a free-time/dreaming
// procedure are the same five sugar verbs; this suite proves the four
// not-yet-real ones fail loudly and identically wherever they are reached.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, ProcedureNotImplemented, StackEntryId, TrailId, Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

/// The d4rt library a caller script imports to reach the `tool` global
/// (`tool.list()` / `tool.invoke(name, args)`). Hard-coded to the canonical
/// `package:` URI the host registers the tool bridge under (mirrors
/// `BrainBridges.toolLibrary`).
const String _toolLibrary =
    'package:tom_brain_procedure/src/bridges/tool_bridge.dart';

/// The four clear-error stub verbs, each paired with the loop word its message
/// names (§ 5.2.1: `{verb}_v1 is a stub — implement the {kind} loop before
/// calling {verb}()`).
const Map<String, String> _stubVerbKinds = <String, String>{
  'plan': 'planning',
  'create': 'creation',
  'critique': 'critique',
  'decide': 'decision',
};

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

  /// Loads one shipped `scripts/system/<id>.dart` procedure through the real
  /// store + resolver path so the test exercises the actual artifact.
  Future<LoadedProcedure> loadSystem(String id) async {
    final store = DiskProcedureStore(systemDir: Directory('scripts/system'));
    final resolver = await ProcedureResolver.fromStore(store);
    return resolver.resolve(id);
  }

  group('G-PR6-1 the four stubs resolve with a notImplemented header', () {
    for (final verb in _stubVerbKinds.keys) {
      test('${verb}_v1 resolves at v1 declaring requires: [notImplemented]',
          () async {
        final stub = await loadSystem('${verb}_v1');
        expect(stub.header.id, '${verb}_v1');
        expect(stub.header.version, 1);
        // The stub fails loudly through the one engine-native primitive, so it
        // declares exactly that primitive — nothing more.
        expect(stub.header.requires, <String>['notImplemented']);
      });
    }
  });

  group('G-PR6-2 the four stubs pass the strict contract validator', () {
    for (final verb in _stubVerbKinds.keys) {
      test('${verb}_v1 has a valid run(ProcedureInputs)->ProcedureResult '
          'signature and a matching requires', () async {
        final stub = await loadSystem('${verb}_v1');
        // Unlike the no-op `think_v1` stub (which returns a Map and would fail
        // the return-type check), a clear-error stub uses the canonical strict
        // entry-point shape, so the contract validator accepts it whole.
        expect(
          () => ContractValidator.shared.validate(stub),
          returnsNormally,
        );
      });
    }
  });

  group('G-PR6-3 invoking a stub at top level throws the clear error', () {
    _stubVerbKinds.forEach((verb, kind) {
      test('$verb surfaces ProcedureNotImplemented, not ProcedureNotFound',
          () async {
        final engine = engineFor(<LoadedProcedure>[
          await loadSystem('${verb}_v1'),
        ]);

        final outcome = await engine
            .invoke(ProcedureInvocation(procedureId: '${verb}_v1'))
            .outcome;

        // The stub threw, so the run closes errored carrying the typed error.
        expect(outcome.status, TrailOutcomeStatus.errored);
        expect(outcome.error, isA<ProcedureNotImplemented>());
        // Crucially NOT the bare ProcedureNotFound — the stub resolved and ran.
        expect(outcome.error, isNot(isA<ProcedureNotFound>()));

        final error = outcome.error! as ProcedureNotImplemented;
        expect(error.verb, verb);
        // The message is the fixed, actionable § 5.2.1 contract.
        expect(error.toString(), contains('${verb}_v1 is a stub'));
        expect(error.toString(), contains('implement the $kind loop'));
        expect(error.toString(), contains('$verb()'));
      });
    });
  });

  group('G-PR7-1 procedure.run drives the real bound engine surface', () {
    test('runs an existing procedure (think_v1) and surfaces its result',
        () async {
      final engine = engineFor(<LoadedProcedure>[
        _procedure(
          'caller_v1',
          '''
import '$_toolLibrary';

Future<Object?> run(inputs) async {
  return await tool.invoke('procedure.run', {'id': 'think_v1'});
}
''',
        ),
        await loadSystem('think_v1'),
      ]);

      final outcome = await engine
          .invoke(ProcedureInvocation(procedureId: 'caller_v1'))
          .outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted);
      // `tool.invoke` wraps a successful tool call as {ok: true, result: …};
      // procedure.run's result is {status, outputs}.
      expect(outcome.result!.output<bool>('ok'), isTrue);
      final result = outcome.result!.output<Map<Object?, Object?>>('result')!;
      expect(result['status'], 'succeeded');
      expect((result['outputs']! as Map)['stub'], 'think_v1');
    });

    test('routing a stub surfaces a failed status (throw swallowed on the '
        'tool path)', () async {
      final engine = engineFor(<LoadedProcedure>[
        _procedure(
          'caller_v1',
          '''
import '$_toolLibrary';

Future<Object?> run(inputs) async {
  return await tool.invoke('procedure.run', {'id': 'plan_v1'});
}
''',
        ),
        await loadSystem('plan_v1'),
      ]);

      final outcome = await engine
          .invoke(ProcedureInvocation(procedureId: 'caller_v1'))
          .outcome;

      // The caller did not crash — the nested stub's throw is swallowed into a
      // failed result before it reaches the tool. The caller observes failure.
      expect(outcome.result!.output<bool>('ok'), isTrue);
      final result = outcome.result!.output<Map<Object?, Object?>>('result')!;
      expect(result['status'], 'failed');
    });
  });

  group('G-PR7-2 procedure.list (bound surface) lists the shipped stubs', () {
    test('the four stub ids surface through the tool', () async {
      final engine = engineFor(<LoadedProcedure>[
        _procedure(
          'caller_v1',
          '''
import '$_toolLibrary';

Future<Object?> run(inputs) async {
  return await tool.invoke('procedure.list', {});
}
''',
        ),
        for (final verb in _stubVerbKinds.keys) await loadSystem('${verb}_v1'),
      ]);

      final outcome = await engine
          .invoke(ProcedureInvocation(procedureId: 'caller_v1'))
          .outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result!.output<bool>('ok'), isTrue);
      final result = outcome.result!.output<Map<Object?, Object?>>('result')!;
      final procedures = (result['procedures']! as List)
          .map((p) => (p as Map)['id'])
          .toSet();
      expect(
        procedures,
        containsAll(<String>['plan_v1', 'create_v1', 'critique_v1', 'decide_v1']),
      );
    });
  });

  group('G-PR7-3 the explicit verb tools are registered and route to <verb>_v1',
      () {
    test('procedure.plan / create / critique / decide register under the '
        'procedure group', () {
      final registry = ToolRegistry();
      registerBasicTools(registry);
      for (final verb in _stubVerbKinds.keys) {
        final tool = registry.lookup('procedure.$verb');
        expect(tool, isNotNull, reason: 'missing tool procedure.$verb');
        expect(tool!.group, ToolGroup.procedure);
        expect(tool.readOnly, isFalse);
      }
    });

    test('procedure.plan routes to plan_v1 through the engine surface',
        () async {
      // Through the real engine: invoking procedure.plan reaches the plan_v1
      // stub, which fails loudly — the explicit tool is a thin alias for
      // procedure.run with the id fixed to plan_v1.
      final engine = engineFor(<LoadedProcedure>[
        _procedure(
          'caller_v1',
          '''
import '$_toolLibrary';

Future<Object?> run(inputs) async {
  return await tool.invoke('procedure.plan', {});
}
''',
        ),
        await loadSystem('plan_v1'),
      ]);

      final outcome = await engine
          .invoke(ProcedureInvocation(procedureId: 'caller_v1'))
          .outcome;

      expect(outcome.result!.output<bool>('ok'), isTrue);
      final result = outcome.result!.output<Map<Object?, Object?>>('result')!;
      // plan_v1 is still a clear-error stub: the run fails (the throw is
      // swallowed on the tool path), proving the route reached plan_v1.
      expect(result['status'], 'failed');
    });
  });
}

/// Builds a [LoadedProcedure] from [body], wrapping it in a minimal valid
/// `@procedure` header (§ 4.4). Mirrors the helper the C.40 sugar suite uses;
/// callers do not declare `requires` because the engine runtime runs only the
/// `SandboxValidator`, not the stricter `ContractValidator`.
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
// The scripts here never call `sub`, so the substrate double only needs to
// satisfy the bridge/engine constructor; its members fall through to
// `noSuchMethod`. Copied from the C.40 sugar suite.
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
// Models just enough of the store for the recorder's writes to be read back.
// Copied from the C.38/C.40 engine suites; unimplemented members fall through
// to `noSuchMethod`.
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
