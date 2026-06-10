// C.18 — D4rtDcliHost acceptance suite.
//
// Plan step C.18 (verbatim): "Tests: host boots; bridges resolve; calling
// a bridged method from a d4rt string-source script returns the expected
// result."
//
// C.16 proved the *composition contract* and C.17 proved the *sandbox
// switch*. C.18 is the dedicated acceptance suite for the three explicit
// criteria the plan names, written so each criterion maps to exactly one
// group and read as an executable statement of "what a booted host must
// do". Where C.16's tests injected bridges positionally (it was
// convention-agnostic at the time) or exercised internals, C.18 only ever
// drives the host through its public `run(String source)` seam under the
// prototype's locked sandbox posture — the way `answer_with_memory_v1`
// (§ 6) actually runs it.
//
// The three criteria:
//
//   C.18-1 BOOTS         — a host constructed under the locked default
//                          (the prototype's only configuration) comes up
//                          runnable: live interpreter, CLI surface over the
//                          *same* interpreter, and a trivial string-source
//                          script returns.
//   C.18-2 BRIDGES       — both brain bridges resolve from a string-source
//          RESOLVE         script run through the host (the `mem` / `sub`
//                          named globals are reachable), and a bare
//                          interpreter does NOT — so resolution is the
//                          host's boot doing the work.
//   C.18-3 BRIDGED-CALL  — calling a bridged method from a d4rt
//          RESULT          string-source script returns the expected result
//                          end-to-end, for memory, for substrate, and for a
//                          procedure that touches both — the headline
//                          acceptance.
//
// The doubles mirror the C.16 fixtures: they implement only the members a
// script touches and fall through to `noSuchMethod` for the rest.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tom_d4rt/d4rt.dart';
import 'package:tom_d4rt_dcli/tom_d4rt_cli_api.dart';

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

  // Every acceptance test boots the host the way the prototype does: the
  // locked sandbox default, no opt-in surfaces, no native primitives.
  D4rtDcliHost makeLockedHost() => D4rtDcliHost(
        memoryBridge: memoryBridge,
        substrateBridge: substrateBridge,
        sandbox: const SandboxConfig.locked(),
      );

  setUp(() {
    stacks = _RecordingStackApi();
    memoryClient = _RecordingMemoryClient(stacks);
    substrateClient = _RecordingSubstrateClient();
    memoryBridge = MemoryBridge(memoryClient);
    substrateBridge = SubstrateBridge(substrateClient);
  });

  group('C.18-1 host boots', () {
    test('a locked host comes up runnable (live interpreter + CLI surface)',
        () {
      final host = makeLockedHost();

      expect(host.interpreter, isA<D4rt>());
      expect(host.cli, isA<D4rtCliApi>());
      // The composition contract restated as an acceptance fact: the CLI
      // surface wraps the same interpreter scripts run on, not a second.
      expect(identical(host.cli.d4rt, host.interpreter), isTrue);
      expect(host.sandbox.isLocked, isTrue);
    });

    test('a freshly-booted host runs a trivial string-source script', () async {
      final host = makeLockedHost();
      expect(await host.run('int run() => 1;'), 1);
    });
  });

  group('C.18-2 bridges resolve through the booted host', () {
    test('the memory bridge resolves from a string-source script', () async {
      final host = makeLockedHost();

      // Reaching `mem.recall(...)` at all requires the bridge type to
      // resolve AND the `mem` global to be bound — both are the host's
      // boot work. A returned value proves resolution succeeded.
      final resolved = await host.run('''
import '${BridgeLibraries.memoryLibrary}';

Future<bool> run() async {
  final recall = await mem.recall('probe');
  return recall.containsKey('nodes');
}
''');
      expect(resolved, isTrue);
    });

    test('the substrate bridge resolves from a string-source script',
        () async {
      substrateClient.streamEvents = _completedStream(text: 'ok');
      final host = makeLockedHost();

      final resolved = await host.run('''
import '${BridgeLibraries.substrateLibrary}';

Future<bool> run() async {
  final answer = await sub.llm('probe');
  return answer.containsKey('text');
}
''');
      expect(resolved, isTrue);
    });

    test('a bare, un-booted interpreter does NOT resolve the bridge',
        () async {
      // Negative control: resolution is the host's boot, not interpreter
      // leniency. A bare interpreter has no `BrainBridges` registration and
      // no `mem` global, so importing the library and calling fails.
      final bare = D4rt();
      expect(
        () => bare.execute(
          source: '''
import '${BridgeLibraries.memoryLibrary}';

Future<bool> run() async => (await mem.recall('x')).containsKey('nodes');
''',
          name: 'run',
        ),
        throwsA(anything),
      );
    });
  });

  group('C.18-3 calling a bridged method returns the expected result', () {
    test('memory: a recall round-trips through the `mem` global', () async {
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
          candidatesPerMode: <RecallMode, int>{RecallMode.bm25: 4},
          fusionStrategy: FusionStrategy.rrf,
          diversityStrategy: DiversityStrategy.mmr,
          elapsedMs: 9,
        ),
      );

      final host = makeLockedHost();

      final result = await host.run(
        '''
import '${BridgeLibraries.memoryLibrary}';

Future<Map<String, Object?>> run(String question) async {
  final recall = await mem.recall(question);
  return {
    'nodeId': recall['nodes'][0]['id'],
    'nodeText': recall['nodes'][0]['values']['text'],
  };
}
''',
        inputs: <Object?>['how do I automate backups?'],
      );

      // Inbound: the script's argument reached the client as a query.
      expect(memoryClient.lastRecallQuery!.text, 'how do I automate backups?');
      // Outbound: the flattened node surfaced through the bridged call.
      final out = (result as Map).cast<String, Object?>();
      expect(out['nodeId'], 'n_00000000000000000000000042');
      expect(out['nodeText'], 'rsync nightly to NAS');
    });

    test('substrate: an llm call round-trips through the `sub` global',
        () async {
      substrateClient.streamEvents = _completedStream(
        chunks: <String>['Back up ', 'nightly.'],
      );

      final host = makeLockedHost();

      final result = await host.run(
        '''
import '${BridgeLibraries.substrateLibrary}';

Future<String> run(String prompt) async {
  final answer = await sub.llm(prompt);
  return answer['text'];
}
''',
        inputs: <Object?>['draft the answer'],
      );

      expect(substrateClient.lastCall!.inputs,
          <String, Object?>{'prompt': 'draft the answer'});
      expect(result, 'Back up nightly.');
    });

    test('both bridges in one procedure (the answer_with_memory_v1 shape)',
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
      substrateClient.streamEvents = _completedStream(text: 'final answer');

      final host = makeLockedHost();

      final result = await host.run(
        '''
import '${BridgeLibraries.memoryLibrary}';
import '${BridgeLibraries.substrateLibrary}';

Future<Map<String, Object?>> run(String question) async {
  final recall = await mem.recall(question);
  final answer = await sub.llm('use the recalled context');
  return {
    'recalledId': recall['nodes'][0]['id'],
    'answer': answer['text'],
  };
}
''',
        inputs: <Object?>['prior?'],
      );

      expect(memoryClient.lastRecallQuery!.text, 'prior?');
      expect(substrateClient.lastCall!.inputs,
          <String, Object?>{'prompt': 'use the recalled context'});
      final out = (result as Map).cast<String, Object?>();
      expect(out['recalledId'], 'n_00000000000000000000000007');
      expect(out['answer'], 'final answer');
    });
  });
}

/// Builds a minimal completed `llm` stream: optional [chunks] (or a single
/// [text]) followed by an `LlmStreamCompleted` so `sub.llm(...)` resolves.
List<LlmStreamEvent> _completedStream({
  String? text,
  List<String>? chunks,
}) {
  final parts = chunks ?? <String>[?text];
  return <LlmStreamEvent>[
    for (final part in parts) LlmStreamChunk(callId: 'c', text: part),
    const LlmStreamCompleted(
      callId: 'c',
      report: LlmCallReport(
        providerId: 'ollama:local',
        modelId: 'gemma3:27b',
        anchorHash: 'a',
        promptHash: 'p',
        tokensIn: 1,
        tokensOut: 1,
        retries: 0,
        wallClockMs: 1,
      ),
    ),
  ];
}

/// Recording `TomBrainMemoryClient` double — captures the domain types the
/// bridge constructs and returns canned domain results (mirrors C.16).
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

  @override
  Future<RecallResult> recall(RecallQuery query) async {
    lastRecallQuery = query;
    return recallResult;
  }

  @override
  StackApi get stacks => _stacks;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// Minimal recording `StackApi` — present only because
/// `TomBrainMemoryClient.stacks` is non-nullable; no stack method is
/// exercised by the C.18 acceptance scripts.
class _RecordingStackApi implements StackApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// Recording `TomBrainSubstrateClient` double — captures the `LlmCall` the
/// bridge constructs and replays a canned stream (mirrors C.16).
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
