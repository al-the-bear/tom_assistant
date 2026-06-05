// C.47 — Bridge audit (Plan step C.47;
// `tom_brain_procedure_prototype_specification.md` § 5.1).
//
// Plan step C.47: "Prove that every memory + substrate method the engine
// bridges has a passing roundtrip test. Drift detection here is the most
// important guard — if memory or substrate change a signature, the bridge
// test must fail loudly."
//
// ── What this audit guarantees, and how each guarantee fails loudly ───
//
// The audit is the phase's drift sentinel. It establishes three nested
// guards, weakest-to-strongest:
//
//  1. **Compile-time underlying-contract guard.** The recording doubles
//     `_AuditMemoryClient` / `_AuditStackApi` / `_AuditSubstrateClient`
//     `implements` the three interface boundaries (PE-10) and provides an
//     explicit `@override` for *every* method the two bridges call. If
//     `tom_brain_memory` or `tom_brain_substrate` change one of those
//     signatures, the bridge source stops compiling against the new API
//     *and* these doubles stop compiling against the interface — the
//     audit cannot even build. That is the loudest possible failure.
//
//  2. **Bridge-surface signature guard.** The generated `BridgedClass`
//     carries a `methodSignatures` string per bridged method — the exact
//     d4rt-facing contract a procedure script binds to. This audit pins
//     all 19 of them (15 memory + 4 substrate, the § 5.1 surface) to
//     literal expected strings. Any edit to a bridge method's d4rt-facing
//     signature (a param added, removed, retyped, or re-defaulted, then
//     re-reflected into the `*.b.dart`) drifts the generated string away
//     from the pin and the audit fails, naming the method.
//
//  3. **Per-method roundtrip-coverage guard.** Every bridged method is
//     driven end-to-end *through the d4rt interpreter* against the
//     recording doubles, and the method name is collected into a covered
//     set. The audit then asserts `covered == bridged == audited`: the
//     set the interpreter actually exercised equals the set the generated
//     bridge actually registers equals the set this audit pins. Add a
//     bridged method without a roundtrip and `covered ⊊ bridged` → fail.
//     Register a method this audit does not know about and
//     `bridged ⊋ audited` → fail. Remove one and the symmetric failure
//     fires. There is no way to change the bridged method set without
//     this test going red.
//
// Contrast with the earlier bridge tests this audit subsumes the role of:
//   - C.12 / C.13 (`memory_bridge_test.dart`, `substrate_bridge_test.dart`)
//     assert the *native* primitive⇄domain conversion field-by-field.
//   - C.15 (`bridge_roundtrip_test.dart`) drives three methods (recall,
//     llm, persist) through the interpreter as a generator-output smoke.
// C.47 is neither: it does not re-assert every field (that is C.12/C.13's
// job) — it proves *completeness* (every method, no gaps) and *drift*
// (the signature surface is pinned). The field-level detail lives one
// layer down; the audit guards the closed set and its shape.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tom_d4rt/d4rt.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, Vec;

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';
// The generated delegating barrel that exposes the `BridgedClass`
// definitions. Same-package `src/` import (the `implementation_imports`
// lint only fires across package boundaries); used so the audit reads the
// *actually-registered* bridge surface rather than a hand-copied list.
import 'package:tom_brain_procedure_prototype/src/bridges/brain_bridges.b.dart';

/// The authoritative § 5.1 memory surface: bridged method name → the
/// exact d4rt-facing signature string the generated `BridgedClass`
/// records. Fifteen rows — `recall`, `classify`, `persist`, `edge`,
/// `propose_node_type`, the seven `stack.*` operations (exposed as
/// `stackList` … `stackRemove` because Dart method names cannot contain a
/// dot), and the three dreaming-agent lifecycle/classifier maintenance
/// methods `demote`, `updateCentroid`, and `findUncertain`.
const Map<String, String> _expectedMemorySignatures = <String, String>{
  'recall':
      "Future<Map<String, Object?>> recall(String text, {List<String> modes = const <String>['bm25', 'vector'], int k = 8})",
  'classify':
      "Future<Map<String, Object?>> classify(List<double> embedding, {String target = 'nodeType'})",
  'persist':
      'Future<String> persist(String typeName, Map<String, Object?> values, {required String producer, String? idempotencyKey, String? causedBy, String? runId, List<double>? embedding})',
  'edge':
      'Future<String> edge(String from, String type, String to, {required String producer, double weight = 1.0, String? idempotencyKey, String? causedBy, String? runId, Map<String, Object?>? attrs})',
  'proposeNodeType': 'Future<void> proposeNodeType(Map<String, Object?> decl)',
  'stackList': 'Future<List<Map<String, Object?>>> stackList()',
  'stackCreate': 'Future<void> stackCreate(Map<String, Object?> decl)',
  'stackPush':
      'Future<String> stackPush(String name, String nodeId, {double priority = 0.0, Map<String, Object?>? attrs, String? producer, String? runId})',
  'stackPeek':
      'Future<List<Map<String, Object?>>> stackPeek(String name, {int k = 16})',
  'stackPop': 'Future<Map<String, Object?>?> stackPop(String name)',
  'stackUpdate':
      'Future<void> stackUpdate(String name, String nodeId, {double? priority, String? status, Map<String, Object?>? attrs})',
  'stackRemove': 'Future<void> stackRemove(String name, String nodeId)',
  'demote': 'Future<void> demote(String nodeId, String reason)',
  'updateCentroid':
      'Future<void> updateCentroid(String forKey, List<double> centroid)',
  'findUncertain':
      'Future<List<String>> findUncertain(String forKey, {required double low, required double high, int limit = 200})',
};

/// The authoritative § 5.1 substrate surface: four rows — `llm`, `embed`,
/// `search`, `fetch`.
const Map<String, String> _expectedSubstrateSignatures = <String, String>{
  'llm':
      'Future<Map<String, Object?>> llm(String prompt, {String role = defaultRole, Map<String, Object?>? budget})',
  'embed': 'Future<Map<String, Object?>> embed(String text)',
  'search':
      'Future<Map<String, Object?>> search(String query, {String? provider, int k = 10})',
  'fetch': 'Future<Map<String, Object?>> fetch(String url, {int? budgetBytes})',
};

void main() {
  late _AuditMemoryClient memoryClient;
  late _AuditStackApi stacks;
  late _AuditSubstrateClient substrateClient;
  late MemoryBridge memoryBridge;
  late SubstrateBridge substrateBridge;
  late D4rt interpreter;

  setUp(() {
    stacks = _AuditStackApi();
    memoryClient = _AuditMemoryClient(stacks);
    substrateClient = _AuditSubstrateClient();
    memoryBridge = MemoryBridge(memoryClient);
    substrateBridge = SubstrateBridge(substrateClient);
    interpreter = D4rt();
    BrainBridges.register(interpreter);
  });

  // Resolves the generated `BridgedClass` for a bridge by name. Reading
  // from `AllBridge.bridgeClasses()` (not a hand-copied list) is what
  // makes the closed-set guard real: this is the surface d4rt scripts
  // actually bind to.
  BridgedClass bridgeClassNamed(String name) {
    return AllBridge.bridgeClasses().firstWhere(
      (c) => c.name == name,
      orElse: () =>
          throw StateError('No bridged class named "$name" is registered.'),
    );
  }

  group('C.47 bridge audit — registered method set is the § 5.1 surface', () {
    test('MemoryBridge registers exactly the 15 audited memory methods', () {
      final registered = bridgeClassNamed('MemoryBridge').methods.keys.toSet();
      expect(
        registered,
        equals(_expectedMemorySignatures.keys.toSet()),
        reason: 'The bridged memory method set drifted from the audited '
            '§ 5.1 surface — a method was added, removed, or renamed '
            'without updating this audit.',
      );
    });

    test('SubstrateBridge registers exactly the 4 audited substrate methods',
        () {
      final registered =
          bridgeClassNamed('SubstrateBridge').methods.keys.toSet();
      expect(
        registered,
        equals(_expectedSubstrateSignatures.keys.toSet()),
        reason: 'The bridged substrate method set drifted from the audited '
            '§ 5.1 surface — a method was added, removed, or renamed '
            'without updating this audit.',
      );
    });
  });

  group('C.47 bridge audit — d4rt-facing signatures are pinned (drift guard)',
      () {
    test('every memory method signature matches its pin', () {
      final signatures = bridgeClassNamed('MemoryBridge').methodSignatures;
      for (final entry in _expectedMemorySignatures.entries) {
        expect(
          signatures[entry.key],
          equals(entry.value),
          reason: 'MemoryBridge.${entry.key} d4rt-facing signature drifted.',
        );
      }
    });

    test('every substrate method signature matches its pin', () {
      final signatures = bridgeClassNamed('SubstrateBridge').methodSignatures;
      for (final entry in _expectedSubstrateSignatures.entries) {
        expect(
          signatures[entry.key],
          equals(entry.value),
          reason:
              'SubstrateBridge.${entry.key} d4rt-facing signature drifted.',
        );
      }
    });
  });

  group('C.47 bridge audit — every bridged method roundtrips end-to-end', () {
    test(
        'each of the 19 methods runs through the interpreter and is recorded',
        () async {
      // Seed canned domain results so every outbound flattening leg has
      // something to read. Inbound legs are observed via the doubles'
      // `called` set.
      memoryClient.persistId =
          NodeId.fromString('n_00000000000000000000000099');
      memoryClient.edgeId = EdgeId.fromString('e_00000000000000000000000001');
      stacks.summaries = const <StackSummary>[
        StackSummary(name: 's', size: 1, topPriority: 0.0, bootstrap: false),
      ];
      stacks.pushId = StackEntryId.fromString('se_00000000000000000000000001');
      stacks.peekEntries = <StackEntry>[
        StackEntry(
          id: StackEntryId.fromString('se_00000000000000000000000002'),
          stackName: 's',
          nodeId: NodeId.fromString('n_00000000000000000000000003'),
          priority: 0.0,
          pushedAt: DateTime.utc(2026, 6, 1),
        ),
      ];
      stacks.popEntry = StackEntry(
        id: StackEntryId.fromString('se_00000000000000000000000003'),
        stackName: 's',
        nodeId: NodeId.fromString('n_00000000000000000000000004'),
        priority: 0.0,
        pushedAt: DateTime.utc(2026, 6, 1),
      );
      substrateClient.streamEvents = <LlmStreamEvent>[
        const LlmStreamChunk(callId: 'c', text: 'ok'),
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
      ];

      // One d4rt-script body per bridged method. Each calls the method on
      // the natively-constructed bridge passed as `main`'s argument; the
      // double records the converted-domain inbound call, proving the
      // bridged method executed under the interpreter — the roundtrip.
      const memoryBodies = <String, String>{
        'recall': "await mem.recall('q');",
        'classify': "await mem.classify([0.1, 0.2], target: 'nodeType');",
        'persist': "await mem.persist('Conclusion', {'text': 'x'}, "
            "producer: 'engine');",
        'edge': "await mem.edge('n_00000000000000000000000001', "
            "'produced_by', 'n_00000000000000000000000002', producer: 'p');",
        'proposeNodeType': "await mem.proposeNodeType({'typeName': 'Widget'});",
        'stackList': 'await mem.stackList();',
        'stackCreate': "await mem.stackCreate({'name': 's'});",
        'stackPush': "await mem.stackPush('s', "
            "'n_00000000000000000000000003');",
        'stackPeek': "await mem.stackPeek('s');",
        'stackPop': "await mem.stackPop('s');",
        'stackUpdate': "await mem.stackUpdate('s', "
            "'n_00000000000000000000000006', priority: 0.5);",
        'stackRemove': "await mem.stackRemove('s', "
            "'n_00000000000000000000000007');",
        'demote': "await mem.demote('n_00000000000000000000000008', "
            "'prunerDecision');",
        'updateCentroid': "await mem.updateCentroid('Claim', [0.1, 0.2]);",
        'findUncertain':
            "await mem.findUncertain('Claim', low: 0.0, high: 1.0);",
      };
      const substrateBodies = <String, String>{
        'llm': "await sub.llm('q');",
        'embed': "await sub.embed('t');",
        'search': "await sub.search('q');",
        'fetch': "await sub.fetch('https://example.com');",
      };

      for (final entry in memoryBodies.entries) {
        await interpreter.execute(
          source: '''
import '${BrainBridges.memoryLibrary}';

Future<Object?> main(MemoryBridge mem) async {
  return ${entry.value}
}
''',
          positionalArgs: <Object?>[memoryBridge],
        );
      }
      for (final entry in substrateBodies.entries) {
        await interpreter.execute(
          source: '''
import '${BrainBridges.substrateLibrary}';

Future<Object?> main(SubstrateBridge sub) async {
  return ${entry.value}
}
''',
          positionalArgs: <Object?>[substrateBridge],
        );
      }

      // The set the interpreter actually exercised. The seven `stack.*`
      // methods are recorded on the StackApi double (the bridge reaches
      // them via `client.stacks`), so the memory-covered set is the union
      // of the direct memory calls and the stack calls.
      final coveredMemory = <String>{
        ...memoryClient.called,
        ...stacks.called,
      };
      final coveredSubstrate = substrateClient.called;

      // The set the generated bridge actually registers.
      final registeredMemory =
          bridgeClassNamed('MemoryBridge').methods.keys.toSet();
      final registeredSubstrate =
          bridgeClassNamed('SubstrateBridge').methods.keys.toSet();

      // covered == registered == audited. No bridged method may exist
      // without a roundtrip, and no roundtrip may exercise a method the
      // bridge does not register.
      expect(coveredMemory, equals(registeredMemory),
          reason: 'A bridged memory method has no interpreter roundtrip '
              '(or a roundtrip hit an unregistered method).');
      expect(coveredMemory, equals(_expectedMemorySignatures.keys.toSet()));

      expect(coveredSubstrate, equals(registeredSubstrate),
          reason: 'A bridged substrate method has no interpreter roundtrip '
              '(or a roundtrip hit an unregistered method).');
      expect(
          coveredSubstrate, equals(_expectedSubstrateSignatures.keys.toSet()));
    });
  });
}

// ── Recording doubles ─────────────────────────────────────────────────
//
// Each `implements` an interface boundary and provides an explicit
// `@override` for every method the bridges call. This is guard (1): a
// signature change in `tom_brain_memory` / `tom_brain_substrate` breaks
// the override and the audit will not compile. Methods the bridges never
// touch fall through to `noSuchMethod` — the bridges do not depend on
// them, so their drift is not the audit's concern.

/// Recording `TomBrainMemoryClient`. `called` accumulates the names of
/// the bridge methods that reached it via the interpreter.
class _AuditMemoryClient implements TomBrainMemoryClient {
  _AuditMemoryClient(this._stacks);

  final _AuditStackApi _stacks;
  final Set<String> called = <String>{};

  NodeId persistId = NodeId.fromString('n_00000000000000000000000000');
  EdgeId edgeId = EdgeId.fromString('e_00000000000000000000000000');

  @override
  Future<RecallResult> recall(RecallQuery query) async {
    called.add('recall');
    return const RecallResult(
      nodes: <Node>[],
      report: RecallReport(
        candidatesPerMode: <RecallMode, int>{},
        fusionStrategy: FusionStrategy.rrf,
        diversityStrategy: DiversityStrategy.mmr,
        elapsedMs: 0,
      ),
    );
  }

  @override
  Future<ClassificationResult> classify(
    Vec embedding, {
    ClassificationTarget target = ClassificationTarget.nodeType,
  }) async {
    called.add('classify');
    return const ClassificationResult.unknown();
  }

  @override
  Future<NodeId> persist(NodeDraft draft, {required Scope scope}) async {
    called.add('persist');
    return persistId;
  }

  @override
  Future<EdgeId> edge(
    NodeId from,
    EdgeType type,
    NodeId to, {
    required Scope scope,
    double weight = 1.0,
    Map<String, Object?>? attrs,
  }) async {
    called.add('edge');
    return edgeId;
  }

  @override
  Future<void> registerNodeType(NodeTypeDecl decl) async {
    called.add('proposeNodeType');
  }

  @override
  Future<void> demote(NodeId id, DemotionReason reason) async {
    called.add('demote');
  }

  @override
  Future<void> updateCentroid(String forKey, Vec centroid) async {
    called.add('updateCentroid');
  }

  @override
  Future<List<NodeId>> findUncertain({
    required String forKey,
    required double low,
    required double high,
    int limit = 200,
  }) async {
    called.add('findUncertain');
    return const <NodeId>[];
  }

  @override
  StackApi get stacks => _stacks;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// Recording `StackApi`. Keeps its own `called` set; the audit unions it
/// with the memory client's. Each method records its bridge alias
/// (`stackList` … `stackRemove`).
class _AuditStackApi implements StackApi {
  final Set<String> called = <String>{};

  List<StackSummary> summaries = const <StackSummary>[];
  StackEntryId pushId =
      StackEntryId.fromString('se_00000000000000000000000000');
  List<StackEntry> peekEntries = const <StackEntry>[];
  StackEntry? popEntry;

  @override
  Future<List<StackSummary>> list() async {
    called.add('stackList');
    return summaries;
  }

  @override
  Future<void> create(StackDecl decl) async {
    called.add('stackCreate');
  }

  @override
  Future<StackEntryId> push(
    String name,
    NodeId entry, {
    double priority = 0.0,
    Map<String, Object?>? attrs,
    Scope? scope,
  }) async {
    called.add('stackPush');
    return pushId;
  }

  @override
  Future<List<StackEntry>> peek(String name, {int k = 16}) async {
    called.add('stackPeek');
    return peekEntries;
  }

  @override
  Future<StackEntry?> pop(String name) async {
    called.add('stackPop');
    return popEntry;
  }

  @override
  Future<void> update(
    String name,
    NodeId entry, {
    double? priority,
    StackEntryStatus? status,
    Map<String, Object?>? attrs,
  }) async {
    called.add('stackUpdate');
  }

  @override
  Future<void> remove(String name, NodeId entry) async {
    called.add('stackRemove');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// Recording `TomBrainSubstrateClient`. `called` accumulates the names of
/// the bridge methods that reached it via the interpreter.
class _AuditSubstrateClient implements TomBrainSubstrateClient {
  final Set<String> called = <String>{};
  List<LlmStreamEvent> streamEvents = const <LlmStreamEvent>[];

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) {
    called.add('llm');
    return Stream<LlmStreamEvent>.fromIterable(streamEvents);
  }

  @override
  Future<EmbeddingResult> embed(String text) async {
    called.add('embed');
    return EmbeddingResult(
      vec: Vec(Float32List.fromList(<double>[0.0])),
      modelIdentity: const EmbeddingModelIdentity(
        providerId: 'p',
        modelId: 'm',
        dims: 1,
        normalized: true,
      ),
    );
  }

  @override
  Future<WebSearchResult> webSearch(
    String query, {
    WebSearchOptions options = WebSearchOptions.empty,
  }) async {
    called.add('search');
    return const WebSearchResult(
      provider: 'p',
      query: 'q',
      hits: <SearchHit>[],
    );
  }

  @override
  Future<WebFetchResult> webFetch(
    Uri url, {
    WebFetchOptions options = WebFetchOptions.empty,
  }) async {
    called.add('fetch');
    return WebFetchResult(
      url: url,
      status: 200,
      contentType: 'text/plain',
      text: '',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
