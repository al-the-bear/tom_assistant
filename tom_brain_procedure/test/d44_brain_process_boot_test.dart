// D.44 — `BrainProcessBoot` startup orchestration.
//
// Plan step D.44 (verbatim): "Implement startup orchestration in
// `BrainProcessBoot`: brings up substrate (in-process), memory (isolate),
// engine + dispatcher (main isolate), and the future access layer (Phase E)."
//
// This suite drives `BrainProcessBoot.boot(BrainProcessConfig)` through the
// dispatcher barrel and proves the orchestration contract:
//
//   1. Bring-up: boot opens the in-process substrate (when a config is given),
//      provisions memory through the D.43 seam (in-process transport for
//      tests), and returns a `BootedBrain` exposing the assembled engine,
//      coordinator, memory, substrate, and a ready dispatcher. The engine and
//      coordinator share one `PreemptionState` (the cooperative-preemption
//      contract).
//   2. boot → submit → shutdown: an `Access` accepted through the booted
//      dispatcher runs `answer_with_memory_v1` end-to-end against the
//      provisioned memory + substrate (Event + Conclusion persisted), and
//      `shutdown()` then completes — closing memory and substrate.
//   3. Shutdown teardown order + idempotency: the access layer is torn down
//      before memory/substrate; memory and substrate are each closed exactly
//      once even across repeated `shutdown()` calls.
//   4. Failure hygiene: a failure during bring-up (a throwing access-layer
//      installer) tears the already-brought-up resources (memory + substrate)
//      back down before the error propagates — a failed boot leaks nothing.
//
// The procedure is loaded from the real `scripts/system/` disk store, so the
// boot wires the shipped `answer_with_memory_v1`, not an inline copy.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        Access,
        EdgeId,
        InboundRequest,
        NodeId,
        OutboundChunk,
        Persona,
        ResolvedIdentity,
        Session,
        StackEntryId,
        TrailId,
        Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

import 'answer_parity_prompts.dart';

void main() {
  late _BootMemory memory;
  late _AnsweringSubstrate substrate;
  late AnswerParityPrompts parity;

  setUp(() {
    memory = _BootMemory();
    substrate = _AnsweringSubstrate();
    parity = AnswerParityPrompts();
  });

  BrainProcessConfig configWith({
    SubstrateConfig? substrateConfig,
    AccessLayerInstaller? installAccessLayer,
    FileScope? toolFileScope,
    String? sessionTodoStoreRoot,
  }) =>
      BrainProcessConfig(
        substrate: substrate,
        substrateConfig: substrateConfig,
        memoryProvisioning: MemoryProvisioningConfig.inProcess(
          client: memory,
          memoryConfig: MemoryConfig.forTesting(root: 'ztmp/d44_boot'),
        ),
        installAccessLayer: installAccessLayer,
        toolFileScope: toolFileScope,
        sessionTodoStoreRoot: sessionTodoStoreRoot,
        // Increment 6 (§6): the booted `answer_with_memory_v1` resolves its
        // prompt through the host `PromptResolver`. Boot threads these seams onto
        // the engine's `SubstrateBridge`; the parity fake reproduces the
        // pre-migration assembled prompt so the substrate sees identical text.
        promptResolver: parity.resolver,
        routeChainOf: parity.routeChainOf,
      );

  Access userPrompt(String text) => Access(
        // After the Todo-6 route-flip (§ 4.0.1) the only routable procedure is
        // the entry router; a confident hint names it, and the two-phase route
        // then runs the answer branch it selects (here `answer_with_memory_v1`,
        // since the prompts carry no deliberation cue).
        envelope: InboundRequest(
            text: text, kindHint: SystemProcedures.promptAnalyzerV1),
        identity: ResolvedIdentity(principalId: 'p1'),
        session: Session(sessionId: 's1'),
        persona: Persona.assistant(),
        deliver: (chunk) => Stream<OutboundChunk>.value(chunk),
      );

  group('D.44-1 bring-up assembles the process', () {
    test('boot returns a BootedBrain with the parts live (in-process memory)',
        () async {
      final booted = await BrainProcessBoot.boot(configWith());
      addTearDown(booted.shutdown);

      // Memory was provisioned over the in-process transport and opened.
      expect(booted.memory.transport, MemoryTransport.inProcess);
      expect(booted.memory.host, isNull);
      expect(memory.openCount, 1);
      expect(memory.openedWithRoot, 'ztmp/d44_boot');

      // The dispatcher is ready, and the engine/coordinator are exposed.
      expect(booted.dispatcher, isA<Dispatcher>());
      expect(booted.engine, isA<ProcedureEngine>());
      expect(booted.coordinator, isA<RunCoordinator>());
      expect(identical(booted.substrate, substrate), isTrue);
    });

    test('the engine and coordinator share one PreemptionState', () async {
      final booted = await BrainProcessBoot.boot(configWith());
      addTearDown(booted.shutdown);

      // Cooperative preemption only works if the object the engine yields
      // against is the same object the coordinator drives.
      expect(
        identical(booted.engine.preemptionState, booted.coordinator.preemption),
        isTrue,
      );
    });

    test('boot opens the in-process substrate when a config is supplied',
        () async {
      final booted = await BrainProcessBoot.boot(
        configWith(substrateConfig: _minimalSubstrateConfig()),
      );
      addTearDown(booted.shutdown);

      expect(substrate.openCount, 1);
    });

    test('boot skips the substrate open when no config is supplied', () async {
      final booted = await BrainProcessBoot.boot(configWith());
      addTearDown(booted.shutdown);

      expect(substrate.openCount, 0);
    });

    test('boot threads the configured tool file-scope onto the engine',
        () async {
      final booted = await BrainProcessBoot.boot(
        configWith(
          toolFileScope: FileScope(
            writeRoots: const <String>['/scope/a'],
            readRoots: const <String>['/scope/b'],
          ),
        ),
      );
      addTearDown(booted.shutdown);

      expect(
        booted.engine.toolFileScope.writeableRoots,
        const <String>['/scope/a'],
      );
      expect(
        booted.engine.toolFileScope.readableRoots,
        const <String>['/scope/a', '/scope/b'],
      );
    });

    test('boot falls back to the engine placeholder root when none configured',
        () async {
      final booted = await BrainProcessBoot.boot(configWith());
      addTearDown(booted.shutdown);

      // A null config leaves the engine on its neutral placeholder, so the
      // tool-calling path stays well-formed even with no `tools.fileScope`.
      expect(booted.engine.toolFileScope.writeableRoots,
          const <String>['/tom-brain-engine']);
    });

    test('a configured sessionTodoStoreRoot makes session todos persist to disk',
        () async {
      final dir = Directory.systemTemp.createTempSync('d44_session_todos_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final booted = await BrainProcessBoot.boot(
        configWith(sessionTodoStoreRoot: dir.path),
      );
      addTearDown(booted.shutdown);

      // A todo added under a session is flushed to `<root>/session_todos.json`,
      // so a later boot over the same root would rehydrate it (the
      // survives-a-restart contract proven directly in
      // session_todo_persistence_test.dart).
      booted.engine.sessionTodoStores.forSession('s1').add('remember this');

      final file = File('${dir.path}/session_todos.json');
      expect(file.existsSync(), isTrue,
          reason: 'the booted engine wired a persistent session-todo registry');
      final decoded = jsonDecode(file.readAsStringSync()) as Map;
      expect(decoded.keys, contains('s1'));
    });

    test('no sessionTodoStoreRoot keeps the in-memory (non-persistent) registry',
        () async {
      final dir = Directory.systemTemp.createTempSync('d44_session_todos_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final booted = await BrainProcessBoot.boot(configWith());
      addTearDown(booted.shutdown);

      booted.engine.sessionTodoStores.forSession('s1').add('ephemeral');
      expect(File('${dir.path}/session_todos.json').existsSync(), isFalse,
          reason: 'a root-less boot persists nothing');
    });
  });

  group('D.44-2 boot → submit → shutdown sequence completes', () {
    test('an accepted Access runs answer_with_memory_v1 end-to-end', () async {
      substrate.answerChunks = <String>['I have no notes on that yet.'];
      final booted = await BrainProcessBoot.boot(configWith());

      await booted.dispatcher.accept(userPrompt('what is a quasar?'));

      // The shipped procedure persisted the exchange (cold path: empty recall).
      final event = memory.persistedOfType('Event').single;
      expect(event.draft.values['summary'], 'what is a quasar?');
      final conclusion = memory.persistedOfType('Conclusion').single;
      expect(conclusion.draft.values['statement'],
          'I have no notes on that yet.');

      // The full sequence then shuts down cleanly.
      await booted.shutdown();
      expect(memory.closeCount, 1);
      expect(substrate.closeCount, 1);
    });

    test('the route streams the answer as deltas then an empty final marker '
        '(P1.3 #8)', () async {
      // Two substrate chunks → two non-final delta chunks reach the channel
      // live, then the route closes the stream with an empty final marker.
      substrate.answerChunks = <String>['Hello, ', 'world.'];
      final booted = await BrainProcessBoot.boot(configWith());
      addTearDown(booted.shutdown);

      final delivered = <OutboundChunk>[];
      final access = Access(
        envelope: InboundRequest(
            text: 'greet me', kindHint: SystemProcedures.promptAnalyzerV1),
        identity: ResolvedIdentity(principalId: 'p1'),
        session: Session(sessionId: 's1'),
        persona: Persona.assistant(),
        deliver: (chunk) {
          delivered.add(chunk);
          return Stream<OutboundChunk>.value(chunk);
        },
      );

      await booted.dispatcher.accept(access);

      // The substrate answer deltas arrived as non-final chunks, in order.
      // Tool-call notices ride the same stream as separate non-final chunks
      // (`OutboundChunk.notice`, P2) — so the answer deltas are the non-final
      // chunks that carry no notice.
      final answerDeltas =
          delivered.where((c) => !c.isFinal && c.notice == null).toList();
      expect(answerDeltas.map((c) => c.textDelta).toList(),
          <String>['Hello, ', 'world.']);

      // Increment 6 (§6) migrated the answer step onto `sub.run`: the procedure
      // no longer opens with a bare `tool.list()`. Its outer-loop termination
      // probe `tool.invoke('todo.list', {})` is now the tool event that surfaces
      // as an out-of-band notice chunk (no answer text), proving the
      // route → engine → tool-event notice wiring is still live end-to-end
      // through the nested `tool_loop_v1` run.
      final notices = delivered.where((c) => c.notice != null).toList();
      expect(notices, isNotEmpty);
      expect(notices.first.textDelta, isEmpty);
      expect(notices.first.notice, startsWith('🔧 tool todo.list'));

      // The stream was terminated by exactly one empty final marker — the
      // deltas already carried the text, so the terminator re-sends nothing.
      final finals = delivered.where((c) => c.isFinal).toList();
      expect(finals, hasLength(1));
      expect(finals.single.textDelta, isEmpty);

      // The final marker is last.
      expect(delivered.last.isFinal, isTrue);
    });
  });

  group('D.44-3 shutdown teardown order + idempotency', () {
    test('the access layer is torn down before memory and substrate',
        () async {
      final order = <String>[];
      memory.onClose = () => order.add('memory');
      substrate.onClose = () => order.add('substrate');

      final booted = await BrainProcessBoot.boot(
        configWith(
          installAccessLayer: (dispatcher) async =>
              () async => order.add('access_layer'),
        ),
      );

      await booted.shutdown();

      expect(order, <String>['access_layer', 'memory', 'substrate'],
          reason: 'stop inbound first, then memory (flush/checkpoint), then '
              'substrate');
    });

    test('shutdown is idempotent — memory and substrate close exactly once',
        () async {
      final booted = await BrainProcessBoot.boot(configWith());

      await booted.shutdown();
      await booted.shutdown();

      expect(memory.closeCount, 1);
      expect(substrate.closeCount, 1);
    });

    test('the installer receives the booted dispatcher', () async {
      Dispatcher? handed;
      final booted = await BrainProcessBoot.boot(
        configWith(
          installAccessLayer: (dispatcher) async {
            handed = dispatcher;
            return () async {};
          },
        ),
      );
      addTearDown(booted.shutdown);

      expect(identical(handed, booted.dispatcher), isTrue);
    });
  });

  group('D.44-4 failure hygiene — a failed boot leaks nothing', () {
    test('a throwing access-layer installer tears down memory + substrate',
        () async {
      // D.46 contract: a bring-up failure surfaces as a typed `BrainStartupError`
      // tagged with the phase it failed in (here `accessLayer`), with the
      // original error preserved in `cause`.
      await expectLater(
        BrainProcessBoot.boot(
          configWith(
            substrateConfig: _minimalSubstrateConfig(),
            installAccessLayer: (_) async =>
                throw StateError('install failed'),
          ),
        ),
        throwsA(
          isA<BrainStartupError>()
              .having((e) => e.phase, 'phase', BootPhase.accessLayer)
              .having((e) => e.cause, 'cause', isA<StateError>()),
        ),
      );

      // The substrate was opened, the memory provisioned — both must be torn
      // back down by boot's failure path.
      expect(substrate.openCount, 1);
      expect(memory.closeCount, 1);
      expect(substrate.closeCount, 1);
    });
  });
}

/// A minimal valid-shape [SubstrateConfig] for the open pass-through tests.
/// The fake substrate's `open` records the call and ignores the value, so the
/// config only needs to construct — it is never validated here.
SubstrateConfig _minimalSubstrateConfig() => const SubstrateConfig(
      providers: <ProviderProfile>[],
      roleRoutes: <String, List<RoleRouteEntryConfig>>{},
      embedding: EmbeddingChoice(
        providerId: 'p',
        model: 'm',
        dims: 1,
        normalize: true,
      ),
      webSearch: WebSearchConfig(
        defaultProvider: 'none',
        providers: <String, WebSearchProviderConfig>{},
      ),
      webFetch: WebFetchConfig(),
      mcpClient: McpClientConfigBlock(),
    );

// ─── A stateful in-process `TomBrainMemoryClient` ───────────────────
//
// Records its open/close lifecycle (the in-process transport calls both),
// persists nodes/edges, and models the `interests` stack — enough for the run
// recorder's trail + stack writes and for asserting the procedure's
// post-conditions. Mirrors the d42 `_BrainMemory` double, plus open/close
// recording.
class _BootMemory implements TomBrainMemory {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

  int openCount = 0;
  int closeCount = 0;
  String? openedWithRoot;
  void Function()? onClose;

  final List<({NodeId id, NodeDraft draft})> persisted =
      <({NodeId id, NodeDraft draft})>[];
  final List<({NodeId from, EdgeType type, NodeId to})> recordedEdges =
      <({NodeId from, EdgeType type, NodeId to})>[];

  RecallResult recallResult = const RecallResult(
    nodes: <Node>[],
    report: RecallReport(
      candidatesPerMode: <RecallMode, int>{},
      fusionStrategy: FusionStrategy.rrf,
      diversityStrategy: DiversityStrategy.mmr,
      elapsedMs: 0,
    ),
  );

  /// The classification `classify` returns. `unknown` (far from every
  /// centroid / cold start) by default, so the step-4 cold-interest path
  /// fires on the empty-recall boot run.
  ClassificationResult classifyResult = const ClassificationResult.unknown();

  Iterable<({NodeId id, NodeDraft draft})> persistedOfType(String typeName) =>
      persisted.where((p) => p.draft.typeName == typeName);

  @override
  Future<void> open(MemoryConfig config) async {
    openCount++;
    openedWithRoot = config.root;
  }

  @override
  Future<void> close() async {
    closeCount++;
    onClose?.call();
  }

  @override
  StackApi get stacks => _stacks;

  @override
  Future<RecallResult> recall(RecallQuery query) async => recallResult;

  @override
  Future<RecallResult> recallMulti(MultiRecallQuery query) async => recallResult;

  @override
  Future<ClassificationResult> classify(
    Vec embedding, {
    ClassificationTarget target = ClassificationTarget.nodeType,
  }) async =>
      classifyResult;

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
    persisted.add((id: id, draft: draft));
    return id;
  }

  @override
  Future<Node?> get(NodeId id) async => _nodes[id];

  @override
  Stream<Node> stream(StreamQuery query) {
    // CLP-76: the boot now enumerates brain `Procedure` nodes from memory.
    // This double serves none, so the procedure tier sees an empty stream.
    final types = query.filter.typeNames;
    return Stream<Node>.fromIterable(
      _nodes.values.where((n) => types.isEmpty || types.contains(n.typeName)),
    );
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
    recordedEdges.add((from: from, type: type, to: to));
    return EdgeId.generate();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

// ─── An answer-capturing `TomBrainSubstrateClient` ──────────────────
//
// Records its open/close lifecycle and emits a canned chunked stream whose
// concatenation is the answer text. Mirrors the d42 double, plus open/close
// recording.
class _AnsweringSubstrate implements TomBrainSubstrateClient {
  List<String> answerChunks = <String>['ok'];

  int openCount = 0;
  int closeCount = 0;
  void Function()? onClose;

  @override
  Future<void> open(SubstrateConfig config) async {
    openCount++;
  }

  @override
  Future<void> close() async {
    closeCount++;
    onClose?.call();
  }

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) {
    return Stream<LlmStreamEvent>.fromIterable(<LlmStreamEvent>[
      for (final chunk in answerChunks)
        LlmStreamChunk(callId: 'c', text: chunk),
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
