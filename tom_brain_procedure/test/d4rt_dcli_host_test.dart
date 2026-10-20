// C.16 — D4rtDcliHost composition tests.
//
// Plan step C.16: "Implement D4rtDcliHost: composes tom_d4rt_dcli's
// D4rtCliApi with our two bridges + the engine-native primitives."
//
// These tests are the executable acceptance check for that composition.
// They prove:
//
//   1. BOOTS — a constructed host exposes a live `D4rt` interpreter and a
//      composed `D4rtCliApi` over the *same* interpreter (the C.16
//      composition contract).
//   2. BRIDGES RESOLVE — the two brain bridges register on the host's
//      interpreter and resolve from a d4rt script that imports the bridge
//      library (the same registration C.14 proved, now driven through the
//      host's boot rather than a bare `BrainBridges.register`).
//   3. GLOBAL INJECTION + RUN — the host's chosen injection convention
//      (named globals `mem` / `sub`, Q-C.15.1) works end-to-end: a
//      procedure script reaches the bridges through the globals and
//      `host.run(...)` returns the entry point's result. The recording
//      doubles capture the inbound domain types so the round-trip is
//      observable, mirroring C.15's pattern but through the host surface.
//   4. NATIVE-PRIMITIVE SEAM — `installNativePrimitives` runs against the
//      host's interpreter at boot (the C.19 seam).
//
// The doubles here intentionally implement only the members the host
// scripts touch and fall through to `noSuchMethod` for the rest —
// consistent with the C.15 fixtures.

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

  D4rtDcliHost makeHost({NativePrimitiveInstaller? installNativePrimitives}) =>
      D4rtDcliHost(
        memoryBridge: memoryBridge,
        substrateBridge: substrateBridge,
        installNativePrimitives: installNativePrimitives,
      );

  setUp(() {
    stacks = _RecordingStackApi();
    memoryClient = _RecordingMemoryClient(stacks);
    substrateClient = _RecordingSubstrateClient();
    memoryBridge = MemoryBridge(memoryClient);
    substrateBridge = SubstrateBridge(
      substrateClient,
      routeChainOf: (_) => const <RouteEntry>[
        RouteEntry(providerId: 'p', model: 'm'),
      ],
    );
  });

  group('C.16 host boots + composes D4rtCliApi', () {
    test('exposes a live interpreter and a CLI surface over it', () {
      final host = makeHost();

      expect(host.interpreter, isA<D4rt>());
      expect(host.cli, isA<D4rtCliApi>());

      // The composition contract: the CLI surface wraps the *same*
      // interpreter the host runs scripts on — not a second one.
      expect(identical(host.cli.d4rt, host.interpreter), isTrue);
      expect(host.cli.toolName, 'TomBrainEngine');
    });

    test('exposes the two injected bridges', () {
      final host = makeHost();
      expect(identical(host.memoryBridge, memoryBridge), isTrue);
      expect(identical(host.substrateBridge, substrateBridge), isTrue);
    });
  });

  group('C.16 bridges resolve on the host interpreter', () {
    test(
      'a script importing the memory bridge library resolves + dispatches',
      () async {
        final host = makeHost();

        // The bridged class resolves through the host's boot-time
        // registration AND a method dispatches on a natively-passed
        // instance. (Resolution alone — `mem is MemoryBridge` — is an
        // unreliable probe: d4rt's `is` against a bridged type for a native
        // instance is a known quirk; a method call is the meaningful proof.)
        final result = await host.interpreter.execute(
          source:
              '''
import '${BridgeLibraries.memoryLibrary}';

Future<bool> main(MemoryBridge mem) async {
  final recall = await mem.recall('anything');
  return recall.containsKey('nodes');
}
''',
          positionalArgs: <Object?>[memoryBridge],
        );
        expect(result, isTrue);
        expect(memoryClient.lastRecallQuery!.text, 'anything');
      },
    );

    test(
      'a fresh, un-booted interpreter does NOT resolve the bridge',
      () async {
        // Negative control: resolution is the host's boot doing the work,
        // not interpreter leniency.
        final bare = D4rt();
        expect(
          () => bare.execute(
            source:
                '''
import '${BridgeLibraries.memoryLibrary}';

bool main(MemoryBridge mem) => true;
''',
            positionalArgs: <Object?>[memoryBridge],
          ),
          throwsA(anything),
        );
      },
    );
  });

  group('C.16 named-global injection + run (Q-C.15.1 convention)', () {
    test('run() reaches MemoryBridge through the `mem` global', () async {
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

      final host = makeHost();

      // The script does NOT take the bridge as a parameter — it imports
      // the bridge library and references the injected `mem` global, with
      // the entry point free to carry only inputs (here: a question).
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

      // Inbound: the question reached the recording client as a query.
      expect(memoryClient.lastRecallQuery!.text, 'how do I automate backups?');

      // Outbound: the flattened node surfaced through the global call.
      final out = (result as Map).cast<String, Object?>();
      expect(out['nodeId'], 'n_00000000000000000000000042');
      expect(out['nodeText'], 'rsync nightly to NAS');
    });

    test('run() reaches SubstrateBridge through the `sub` global', () async {
      substrateClient.streamEvents = <LlmEvent>[
        const LlmTextDelta('Back up '),
        const LlmTextDelta('nightly.'),
        const LlmRunCompleted(
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

      final host = makeHost();

      final result = await host.run(
        '''
import '${BridgeLibraries.substrateLibrary}';

Future<String> run(String prompt) async {
  final answer = await sub.send(prompt, llmRoute: 'fast');
  return answer['text'];
}
''',
        inputs: <Object?>['draft the answer'],
      );

      expect(substrateClient.lastCall!.inputs, <String, Object?>{
        'prompt': 'draft the answer',
      });
      expect(result, 'Back up nightly.');
    });

    test('one run() reaches both globals in a single procedure', () async {
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
      substrateClient.streamEvents = <LlmEvent>[
        const LlmTextDelta('final answer'),
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
      ];

      final host = makeHost();

      final result = await host.run(
        '''
import '${BridgeLibraries.memoryLibrary}';
import '${BridgeLibraries.substrateLibrary}';

Future<Map<String, Object?>> run(String question) async {
  final recall = await mem.recall(question);
  final answer = await sub.send('use the recalled context', llmRoute: 'fast');
  return {
    'recalledId': recall['nodes'][0]['id'],
    'answer': answer['text'],
  };
}
''',
        inputs: <Object?>['prior?'],
      );

      expect(memoryClient.lastRecallQuery!.text, 'prior?');
      expect(substrateClient.lastCall!.inputs, <String, Object?>{
        'prompt': 'use the recalled context',
      });

      final out = (result as Map).cast<String, Object?>();
      expect(out['recalledId'], 'n_00000000000000000000000007');
      expect(out['answer'], 'final answer');
    });

    test(
      'default entryPoint is `run` (spec § 4.3); custom names honoured',
      () async {
        final host = makeHost();

        // Default name = 'run'.
        final viaRun = await host.run('int run() => 41;');
        expect(viaRun, 41);

        // A custom entry point is dispatched too.
        final viaCustom = await host.run(
          'int compute() => 42;',
          entryPoint: 'compute',
        );
        expect(viaCustom, 42);
      },
    );
  });

  group('C.16 engine-native-primitive seam', () {
    test(
      'installNativePrimitives runs against the host interpreter at boot',
      () {
        D4rt? seen;
        final host = makeHost(installNativePrimitives: (d4rt) => seen = d4rt);
        expect(identical(seen, host.interpreter), isTrue);
      },
    );

    test('no installer is fine — host still boots and runs', () async {
      final host = makeHost();
      expect(await host.run('int run() => 7;'), 7);
    });
  });
}

/// Recording `TomBrainMemoryClient` double — captures the domain types
/// the bridge constructs and returns canned domain results, so both legs
/// of the bridge round-trip are observable (mirrors the C.15 fixture).
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Minimal recording `StackApi` — present only because
/// `TomBrainMemoryClient.stacks` is non-nullable. No stack method is
/// exercised by the C.16 host scripts.
class _RecordingStackApi implements StackApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Recording `TomBrainSubstrateClient` double — captures the `LlmCall`
/// the bridge constructs and replays a canned stream.
class _RecordingSubstrateClient implements TomBrainSubstrateClient {
  LlmCall? lastCall;
  List<LlmEvent> streamEvents = const <LlmEvent>[];

  @override
  Stream<LlmEvent> completeStream(LlmCall call) {
    lastCall = call;
    return Stream<LlmEvent>.fromIterable(streamEvents);
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
