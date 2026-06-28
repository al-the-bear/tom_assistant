// D.44b — `MemoryProcedureStore` is wired into the live boot resolver (CLP-76).
//
// TODO I-1 / `tom_brain_procedure_specification.md` § 24.5: brain-authored
// procedures persist as memory `Procedure` nodes, but until CLP-76 the boot
// composed only the disk store into the resolver, so a brain-authored
// procedure was *persisted but not resolvable/runnable*. This suite proves the
// boot now composes `MemoryProcedureStore` UNDER the disk store via
// `ShadowingProcedureStore`:
//
//   1. a brain `Procedure` node resolves through `booted.engine.resolver`
//      (the memory tier reaches the live resolver at all); and
//   2. a same-id disk procedure shadows the memory node — the disk source
//      wins the id, the precedence § 24.5 mandates ("a human-edited
//      disk/bundle procedure still shadows a memory node of the same id"),
//      which is why the boot uses `ShadowingProcedureStore` (shadow-by-id) and
//      not `CompositeProcedureStore` (which would surface both versions).
//
// The memory is the in-process boot double; the brain `Procedure` node is
// pre-seeded so the resolver sees it at bring-up without a dispatch.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show NodeId, Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

void main() {
  late Directory systemDir;

  setUp(() {
    systemDir = Directory.systemTemp.createTempSync('d44b_system_');
  });

  tearDown(() {
    if (systemDir.existsSync()) systemDir.deleteSync(recursive: true);
  });

  BrainProcessConfig configWith(_SeededMemory memory) => BrainProcessConfig(
        substrate: _NoopSubstrate(),
        memoryProvisioning: MemoryProvisioningConfig.inProcess(
          client: memory,
          memoryConfig: MemoryConfig.forTesting(root: 'ztmp/d44b_boot'),
        ),
        systemScriptsDir: systemDir,
      );

  test('a brain-authored Procedure node resolves through the booted engine '
      '(CLP-76: MemoryProcedureStore is in the live resolver)', () async {
    // The disk tier is empty; the only procedure the boot can know is the
    // pre-seeded brain node. Before CLP-76 the boot built a disk-only resolver,
    // so this id was unknown — that is the failing-before state this proves.
    final memory = _SeededMemory()
      ..seedProcedure(
        'n_00000000000000000000000001',
        _procedureSource('brain_authored_v1'),
      );

    final booted = await BrainProcessBoot.boot(configWith(memory));
    addTearDown(booted.shutdown);

    expect(booted.engine.resolver.knows('brain_authored_v1'), isTrue,
        reason: 'the memory tier must reach the live boot resolver');
  });

  test('a same-id disk procedure shadows the brain node (disk source wins)',
      () async {
    // Both tiers carry `shadowed_v1`; the disk source must win the id, the
    // precedence § 24.5 mandates and the reason the boot uses
    // ShadowingProcedureStore rather than CompositeProcedureStore.
    const diskSource = '/// @procedure\n'
        '/// id: shadowed_v1\n'
        '/// version: 2\n'
        '/// summary: The disk edition of the shadowed procedure.\n'
        '/// successCriterion: wins the id over the memory node.\n'
        '/// budget: { wallClockMs: 1000 }\n'
        'Future run() async {}\n';
    File('${systemDir.path}/shadowed_v1.dart').writeAsStringSync(diskSource);

    final memory = _SeededMemory()
      ..seedProcedure(
        'n_00000000000000000000000002',
        _procedureSource('shadowed_v1'),
      );

    final booted = await BrainProcessBoot.boot(configWith(memory));
    addTearDown(booted.shutdown);

    expect(booted.engine.resolver.knows('shadowed_v1'), isTrue);
    expect(booted.engine.resolver.resolve('shadowed_v1').source, diskSource,
        reason: 'the disk procedure must shadow the same-id memory node');
  });
}

/// A minimal valid `Procedure` source carrying [id] — the five required header
/// fields (`id`, `version`, `summary`, `successCriterion`, `budget`) and an
/// empty body, enough for the loader to parse a header.
String _procedureSource(String id) => '/// @procedure\n'
    '/// id: $id\n'
    '/// version: 1\n'
    '/// summary: A brain-authored procedure persisted as a memory node.\n'
    '/// successCriterion: resolves through the booted engine resolver.\n'
    '/// budget: { wallClockMs: 1000 }\n'
    'Future run() async {}\n';

/// In-process `TomBrainMemory` that serves pre-seeded `Procedure` nodes through
/// the `stream` + `get` calls `MemoryProcedureStore` makes at bring-up. Only
/// the lifecycle and those two reads are exercised — no dispatch runs — so
/// everything else falls through to `noSuchMethod`.
class _SeededMemory implements TomBrainMemory {
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};

  /// Seeds a `Procedure` node with [idText] as its node id and [source] as its
  /// verbatim d4rt source.
  void seedProcedure(String idText, String source) {
    final id = NodeId.fromString(idText);
    _nodes[id] = Node(
      id: id,
      typeName: 'Procedure',
      values: <String, Object?>{'source': source, 'revision': 1},
      createdAt: DateTime.utc(2026),
    );
  }

  @override
  Future<void> open(MemoryConfig config) async {}

  @override
  Future<void> close() async {}

  @override
  Stream<Node> stream(StreamQuery query) {
    final types = query.filter.typeNames;
    return Stream<Node>.fromIterable(
      _nodes.values.where((n) => types.isEmpty || types.contains(n.typeName)),
    );
  }

  @override
  Future<Node?> get(NodeId id) async => _nodes[id];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// A substrate whose `open`/`close` are no-ops and whose answer/embed calls are
/// never reached — the resolver-wiring tests never dispatch a run.
class _NoopSubstrate implements TomBrainSubstrateClient {
  @override
  Future<void> open(SubstrateConfig config) async {}

  @override
  Future<void> close() async {}

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
