// C.15 — generator-output round-trip smoke.
//
// Plan step C.15: "Test the generator output: a tiny d4rt script that
// calls one method on each bridge runs successfully against in-memory
// test doubles for memory + substrate."
//
// This is the seam the native C.12/C.13 tests stand in for: there the
// bridges' primitive⇄domain conversions are driven directly in Dart;
// here the *generated* bridge is exercised end-to-end *through the d4rt
// interpreter*. A real procedure script imports the bridge libraries,
// receives a natively-constructed bridge instance, calls a method on it,
// and reads the flattened primitive result back. The doubles capture the
// inbound domain types so we can prove the script's primitive arguments
// were converted, and the script reads the outbound primitive maps so we
// prove the domain results were flattened — the full round-trip the
// generated `*.b.dart` performs under the interpreter.
//
// Contrast with C.14 (`generated_bridges_test.dart`), which proves the
// classes *resolve* and *register* but deliberately calls no instance
// method. C.15 is the method round-trip.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tom_d4rt/d4rt.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show NodeId, Vec;

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

void main() {
  late _RecordingMemoryClient memoryClient;
  late _RecordingStackApi stacks;
  late _RecordingSubstrateClient substrateClient;
  late MemoryBridge memoryBridge;
  late SubstrateBridge substrateBridge;
  late D4rt interpreter;

  setUp(() {
    stacks = _RecordingStackApi();
    memoryClient = _RecordingMemoryClient(stacks);
    substrateClient = _RecordingSubstrateClient();
    memoryBridge = MemoryBridge(memoryClient);
    substrateBridge = SubstrateBridge(substrateClient);
    interpreter = D4rt();
    BrainBridges.register(interpreter);
  });

  group('C.15 generator output — single-bridge round-trips', () {
    test('a script calls MemoryBridge.recall and reads the flattened nodes',
        () async {
      memoryClient.recallResult = RecallResult(
        nodes: <Node>[
          Node(
            id: NodeId.fromString('n_00000000000000000000000042'),
            typeName: 'Conclusion',
            values: const <String, Object?>{'text': 'rsync nightly to NAS'},
            createdAt: DateTime.utc(2026, 6, 1),
          ),
        ],
        report: const RecallReport(
          candidatesPerMode: <RecallMode, int>{
            RecallMode.bm25: 4,
            RecallMode.vector: 6,
          },
          fusionStrategy: FusionStrategy.rrf,
          diversityStrategy: DiversityStrategy.mmr,
          elapsedMs: 9,
        ),
      );

      final result = await interpreter.execute(
        source: '''
import '${BridgeLibraries.memoryLibrary}';

Future<Map<String, Object?>> main(MemoryBridge mem) async {
  final recall = await mem.recall('how do I automate backups?');
  return {
    'nodeId': recall['nodes'][0]['id'],
    'nodeText': recall['nodes'][0]['values']['text'],
    'bm25Candidates': recall['report']['candidatesPerMode']['bm25'],
  };
}
''',
        positionalArgs: <Object?>[memoryBridge],
      );

      // (a) Inbound conversion: the script's primitive string + default
      // modes/k were converted into a RecallQuery and captured by the
      // double — proof the generated bridge performed the coercion.
      final query = memoryClient.lastRecallQuery!;
      expect(query.text, 'how do I automate backups?');
      expect(query.modes, <RecallMode>{RecallMode.bm25, RecallMode.vector});
      expect(query.k, 8);

      // (b) Outbound flattening read back inside the d4rt script.
      final out = (result as Map).cast<String, Object?>();
      expect(out['nodeId'], 'n_00000000000000000000000042');
      expect(out['nodeText'], 'rsync nightly to NAS');
      expect(out['bm25Candidates'], 4);
    });

    test('a script calls SubstrateBridge.llm and reads the answer text',
        () async {
      substrateClient.streamEvents = <LlmStreamEvent>[
        const LlmStreamStarted(
          callId: 'c1',
          providerId: 'ollama:local',
          modelId: 'gemma3:27b',
        ),
        const LlmStreamChunk(callId: 'c1', text: 'Back up '),
        const LlmStreamChunk(callId: 'c1', text: 'nightly.'),
        const LlmStreamCompleted(
          callId: 'c1',
          report: LlmCallReport(
            providerId: 'ollama:local',
            modelId: 'gemma3:27b',
            anchorHash: 'a1',
            promptHash: 'p1',
            tokensIn: 11,
            tokensOut: 4,
            retries: 0,
            wallClockMs: 120,
          ),
        ),
      ];

      final result = await interpreter.execute(
        source: '''
import '${BridgeLibraries.substrateLibrary}';

Future<Map<String, Object?>> main(SubstrateBridge sub) async {
  final answer = await sub.llm('draft the answer');
  return {
    'text': answer['text'],
    'provider': answer['report']['providerId'],
  };
}
''',
        positionalArgs: <Object?>[substrateBridge],
      );

      // (a) Inbound conversion: prompt input + default role/budget.
      final call = substrateClient.lastCall!;
      expect(call.roleId, SubstrateBridge.defaultRole);
      expect(call.inputs, <String, Object?>{'prompt': 'draft the answer'});

      // (b) Outbound flattening: concatenated chunk text + report map.
      final out = (result as Map).cast<String, Object?>();
      expect(out['text'], 'Back up nightly.');
      expect(out['provider'], 'ollama:local');
    });
  });

  group('C.15 generator output — both bridges in one script', () {
    test('one script calls a method on each bridge and combines the results',
        () async {
      memoryClient.recallResult = RecallResult(
        nodes: <Node>[
          Node(
            id: NodeId.fromString('n_00000000000000000000000007'),
            typeName: 'Claim',
            values: const <String, Object?>{'text': 'prior context'},
            createdAt: DateTime.utc(2026, 6, 1),
          ),
        ],
        report: const RecallReport(
          candidatesPerMode: <RecallMode, int>{RecallMode.bm25: 1},
          fusionStrategy: FusionStrategy.rrf,
          diversityStrategy: DiversityStrategy.mmr,
          elapsedMs: 2,
        ),
      );
      substrateClient.streamEvents = <LlmStreamEvent>[
        const LlmStreamChunk(callId: 'c', text: 'final answer'),
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

      final result = await interpreter.execute(
        source: '''
import '${BridgeLibraries.memoryLibrary}';
import '${BridgeLibraries.substrateLibrary}';

Future<Map<String, Object?>> main(MemoryBridge mem, SubstrateBridge sub) async {
  final recall = await mem.recall('prior?');
  final answer = await sub.llm('use the recalled context');
  return {
    'recalledId': recall['nodes'][0]['id'],
    'answer': answer['text'],
  };
}
''',
        positionalArgs: <Object?>[memoryBridge, substrateBridge],
      );

      // Both doubles saw their respective domain types.
      expect(memoryClient.lastRecallQuery!.text, 'prior?');
      expect(substrateClient.lastCall!.inputs,
          <String, Object?>{'prompt': 'use the recalled context'});

      final out = (result as Map).cast<String, Object?>();
      expect(out['recalledId'], 'n_00000000000000000000000007');
      expect(out['answer'], 'final answer');
    });
  });

  group('C.15 generator output — write path through the interpreter', () {
    test('a script calls MemoryBridge.persist and reads the returned id',
        () async {
      memoryClient.persistId =
          NodeId.fromString('n_00000000000000000000000099');

      final result = await interpreter.execute(
        source: '''
import '${BridgeLibraries.memoryLibrary}';

Future<String> main(MemoryBridge mem) async {
  return await mem.persist(
    'Conclusion',
    {'text': 'the synthesised answer'},
    producer: 'engine:answer_with_memory_v1:r_1',
    runId: 'r_1',
  );
}
''',
        positionalArgs: <Object?>[memoryBridge],
      );

      // Inbound: the primitive type name + values map + named provenance
      // were converted into a NodeDraft + Scope by the generated bridge.
      expect(memoryClient.lastDraft!.typeName, 'Conclusion');
      expect(memoryClient.lastDraft!.values,
          <String, Object?>{'text': 'the synthesised answer'});
      expect(memoryClient.lastScope!.producer,
          'engine:answer_with_memory_v1:r_1');
      expect(memoryClient.lastScope!.runId, 'r_1');

      // Outbound: the id string surfaced to the script.
      expect(result, 'n_00000000000000000000000099');
    });
  });
}

/// Recording `TomBrainMemoryClient` double. Captures the domain types the
/// generated bridge constructs so the round-trip's inbound leg is
/// observable; returns canned domain results so the outbound leg is too.
class _RecordingMemoryClient implements TomBrainMemoryClient {
  _RecordingMemoryClient(this._stacks);

  final _RecordingStackApi _stacks;

  RecallQuery? lastRecallQuery;
  RecallResult recallResult = const RecallResult(
    nodes: <Node>[],
    report: RecallReport(
      candidatesPerMode: <RecallMode, int>{},
      fusionStrategy: FusionStrategy.rrf,
      diversityStrategy: DiversityStrategy.mmr,
      elapsedMs: 0,
    ),
  );

  NodeDraft? lastDraft;
  Scope? lastScope;
  NodeId persistId = NodeId.fromString('n_00000000000000000000000000');

  @override
  Future<RecallResult> recall(RecallQuery query) async {
    lastRecallQuery = query;
    return recallResult;
  }

  @override
  Future<NodeId> persist(NodeDraft draft, {required Scope scope}) async {
    lastDraft = draft;
    lastScope = scope;
    return persistId;
  }

  @override
  StackApi get stacks => _stacks;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// Minimal recording `StackApi` — present only because
/// `TomBrainMemoryClient.stacks` is non-nullable. No stack method is
/// exercised by the C.15 scripts.
class _RecordingStackApi implements StackApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// Recording `TomBrainSubstrateClient` double. Captures the `LlmCall`
/// the generated bridge constructs and replays a canned stream.
class _RecordingSubstrateClient implements TomBrainSubstrateClient {
  LlmCall? lastCall;
  List<LlmStreamEvent> streamEvents = const <LlmStreamEvent>[];

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) {
    lastCall = call;
    return Stream<LlmStreamEvent>.fromIterable(streamEvents);
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
