// D.54 — Procedure-script conformance.
//
// Plan step D.54 (verbatim): "**Procedure-script conformance**:
// `answer_with_memory_v1` is exercised through the dispatcher entry surface,
// not by importing the script directly. The test injects a stub memory + stub
// substrate so the post-conditions can be asserted."
//
// ── How this suite differs from D.37–D.42 ───────────────────────────────
//
// D.37–D.42 drove the shipped disk procedure through `ProcedureEngine.invoke`
// directly: they hold the `ProcedureOutcome`, read its result outputs and its
// trail entries, and assert the body's per-step post-conditions against the
// engine. That is *script* conformance with the engine as the harness.
//
// D.54 raises the harness one layer: the procedure is reached *only* through
// `BrainProcessBoot.boot(...).dispatcher.accept(Access)` — the single inbound
// entry point (PE-11). No test in this file imports the script, names
// `answer_with_memory_v1`, or touches the engine; the dispatcher's
// `classify → select → schedule` route is what selects and runs it (the boot
// route, D.44). The booted process is wired over a *stub memory* (an injected
// in-process `TomBrainMemoryClient` that records every node, edge, stack push
// and trail note) and a *stub substrate* (a canned chunked LLM stream), so the
// procedure's post-conditions are observable off those two stubs after a single
// `accept` resolves.
//
// The booted route discards the run's `ProcedureOutcome` (it awaits
// `coordinator.submitForeground(...)` for completion only — Q-D.38.1), so the
// answer and the run's trail are *not* readable from the `accept` return. They
// are read from memory instead: the answer lands as a `Conclusion` node, and
// the `automation_candidate` note lands on the run trail the recorder opened on
// the stub. This is exactly the observability the spec promises a downstream
// consumer (§ 11) — the run's effects are in memory, not in the caller's hand.
//
// ── The post-condition bundle, by classification + recall outcome (§ 11) ─
//
// The cold-classification interest path is driven by `classify`, not by an
// empty recall: the body embeds the prompt and classifies the vector against
// memory's centroids, and a `decision == 'unknown'` is the cold signal
// (Q-D.40.1). The stub memory controls that decision directly via
// `classifyResult`, independent of what `recall` returns.
//
//   COLD  (stub `classify` returns `unknown` — far from every centroid) →
//     • a streamed answer is produced (the multi-chunk substrate stream is
//       drained into the `Conclusion.statement`; per-token delivery to a live
//       caller is a Phase E concern, Q-D.38.1);
//     • an `Event` carries the inbound prompt; a `Conclusion` carries the
//       answer;
//     • NO `derived_from` edges (nothing was cited);
//     • a `produced_by` edge ties the `Conclusion` to the authoritative final
//       `ProcedureRun` node (drawn by the recorder at complete());
//     • an `InterestItem` is persisted *and* pushed onto the `interests` stack
//       (the cold-classification path, D.40);
//     • NO `produced_by` edge points at the `InterestItem` (Q-D.40.2).
//
//   WARM  (stub `classify` returns `confident`, recall surfaced cited nodes) →
//     • the same streamed-answer + Event + Conclusion + produced_by bundle;
//     • a `derived_from` edge ties the `Conclusion` to *each* cited node;
//     • NO interest push (the prompt classified confidently).
//
//   REPEAT  (stub recall surfaced a prior `Event` whose `summary` == this
//            prompt) →
//     • the run still closes with the answer in memory;
//     • an `automation_candidate` note is written to the run trail carrying a
//       non-empty `why` and the prompt as `signature` (D.41).
//
// The procedure is loaded by boot from the real `scripts/system/` disk store,
// so this exercises the shipped artifact through the production bring-up path,
// not an inline copy.

import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        Access,
        DeliverCallback,
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

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';

void main() {
  late _StubMemory memory;
  late _StubSubstrate substrate;

  setUp(() {
    memory = _StubMemory();
    substrate = _StubSubstrate();
  });

  /// Boots the prototype process over the stub memory + stub substrate, in the
  /// in-process memory transport so the post-conditions are observable
  /// synchronously off the injected client. Tears the booted brain down after
  /// the test.
  Future<BootedBrain> bootBrain(String memoryRoot) async {
    final booted = await BrainProcessBoot.boot(
      BrainProcessConfig(
        substrate: substrate,
        memoryProvisioning: MemoryProvisioningConfig.inProcess(
          client: memory,
          memoryConfig: MemoryConfig.forTesting(root: memoryRoot),
        ),
      ),
    );
    addTearDown(booted.shutdown);
    return booted;
  }

  /// The authoritative final `ProcedureRun` node — the one the recorder
  /// persists with a terminal status (the inflight marker carries 'running').
  ({NodeId id, NodeDraft draft}) finalRunNode() => memory
      .persistedOfType('ProcedureRun')
      .firstWhere((p) => p.draft.values['status'] != 'running');

  // The two recalled node ids the warm path should cite in its derived_from
  // edges.
  final citedA = NodeId.fromString('n_00000000000000000000000054');
  final citedB = NodeId.fromString('n_00000000000000000000000055');

  group('D.54-1 cold path through accept — event + conclusion + produced_by + '
      'interest push, no derived_from', () {
    test('a single accepted user_prompt satisfies the cold post-condition '
        'bundle', () async {
      // Default stub classify returns `unknown` → the cold-classification path.
      substrate.answerChunks = <String>['I have no notes on that yet.'];
      final booted = await bootBrain('ztmp/d54_cold');

      await booted.dispatcher.accept(_accessWith(text: 'what is a quasar?'));

      // (a) An Event carries the inbound prompt.
      final event = memory.persistedOfType('Event').single;
      expect(event.draft.values['summary'], 'what is a quasar?');

      // (b) A Conclusion carries the generated answer.
      final conclusion = memory.persistedOfType('Conclusion').single;
      expect(conclusion.draft.values['statement'],
          'I have no notes on that yet.');

      // (c) No derived_from edges — nothing was cited.
      final derivedFromConclusion = memory.recordedEdges.where(
        (e) => e.type == EdgeType.derivedFrom && e.from == conclusion.id,
      );
      expect(derivedFromConclusion, isEmpty);

      // (d) A produced_by edge ties the Conclusion to the final run node.
      final producedBy = memory.recordedEdges.where(
        (e) => e.type == EdgeType.producedBy && e.from == conclusion.id,
      );
      expect(producedBy, hasLength(1));
      expect(producedBy.single.to, finalRunNode().id);

      // (e) Interest push when applicable: an InterestItem is persisted and
      //     pushed onto the `interests` stack.
      final interest = memory.persistedOfType('InterestItem').single;
      expect(interest.draft.values['topic'], 'what is a quasar?');
      expect((interest.draft.values['why'] as String).isNotEmpty, isTrue);

      final interests = await memory.stacks.peek('interests');
      expect(interests, hasLength(1));
      expect(interests.single.nodeId, interest.id);

      // (f) The InterestItem is NOT a produced result — no produced_by edge
      //     points at it (its bootstrap schema forbids one, Q-D.40.2).
      final producedToInterest = memory.recordedEdges.where(
        (e) => e.type == EdgeType.producedBy && e.to == interest.id,
      );
      expect(producedToInterest, isEmpty);
    });
  });

  group('D.54-2 warm path through accept — event + conclusion + both edge '
      'kinds, no interest', () {
    test('a single accepted user_prompt satisfies the warm post-condition '
        'bundle', () async {
      memory.recallResult = _recallWith(<Node>[
        Node(
          id: citedA,
          typeName: 'Conclusion',
          values: const <String, Object?>{'text': 'rsync nightly to the NAS'},
          createdAt: DateTime.utc(2026, 6, 1),
        ),
        Node(
          id: citedB,
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'the NAS lives at 10.0.0.4'},
          createdAt: DateTime.utc(2026, 6, 1),
        ),
      ]);
      // Warm: the prompt classifies confidently against a known centroid, so
      // the cold-classification interest path does not fire (Q-D.40.1).
      memory.classifyResult = const ClassificationResult(
        decision: ClassificationDecision.confident,
        bestMatch: 'Conclusion',
        bestSimilarity: 0.92,
        secondSimilarity: 0.18,
      );
      substrate.answerChunks = <String>['Back up by rsyncing nightly.'];
      final booted = await bootBrain('ztmp/d54_warm');

      await booted.dispatcher
          .accept(_accessWith(text: 'how do I automate backups?'));

      // (a) An Event carries the inbound prompt.
      final event = memory.persistedOfType('Event').single;
      expect(event.draft.values['summary'], 'how do I automate backups?');

      // (b) A Conclusion carries the generated answer.
      final conclusion = memory.persistedOfType('Conclusion').single;
      expect(conclusion.draft.values['statement'],
          'Back up by rsyncing nightly.');

      // (c) A derived_from edge ties the Conclusion to each cited node.
      final derivedTargets = memory.recordedEdges
          .where(
              (e) => e.type == EdgeType.derivedFrom && e.from == conclusion.id)
          .map((e) => e.to)
          .toSet();
      expect(derivedTargets, <NodeId>{citedA, citedB});

      // (d) A produced_by edge ties the Conclusion to the final run node.
      final producedBy = memory.recordedEdges.where(
        (e) => e.type == EdgeType.producedBy && e.from == conclusion.id,
      );
      expect(producedBy, hasLength(1));
      expect(producedBy.single.to, finalRunNode().id);

      // (e) No interest push: the prompt was not cold.
      expect(memory.persistedOfType('InterestItem'), isEmpty);
      expect(await memory.stacks.peek('interests'), isEmpty);
    });
  });

  group('D.54-3 repeat path through accept — automation-candidate note', () {
    test('a repeated prompt emits one automation_candidate note on the trail',
        () async {
      // Recall surfaces a prior Event whose summary == this prompt: an earlier
      // identical-shape turn (the repetition signal, D.41).
      memory.recallResult = _recallWith(<Node>[
        Node(
          id: NodeId.fromString('n_00000000000000000000000056'),
          typeName: 'Event',
          values: const <String, Object?>{'summary': 'what is a quasar?'},
          createdAt: DateTime.utc(2026, 6, 1),
        ),
      ]);
      // The topic is already known (the user asked it before), so it
      // classifies confidently — the signal under test is repetition, not
      // cold curiosity (Q-D.40.1 / Q-D.41.1).
      memory.classifyResult = const ClassificationResult(
        decision: ClassificationDecision.confident,
        bestMatch: 'Event',
        bestSimilarity: 0.95,
        secondSimilarity: 0.10,
      );
      substrate.answerChunks = <String>['A quasar is a luminous galactic core.'];
      final booted = await bootBrain('ztmp/d54_repeat');

      await booted.dispatcher.accept(_accessWith(text: 'what is a quasar?'));

      // The note reached the run trail the recorder opened on the stub.
      final notes = memory.automationNotes();
      expect(notes, hasLength(1));
      expect(notes.single['signature'], 'what is a quasar?');
      expect((notes.single['why'] as String).isNotEmpty, isTrue);

      // The run still produced the answer in memory.
      final conclusion = memory.persistedOfType('Conclusion').single;
      expect(conclusion.draft.values['statement'],
          'A quasar is a luminous galactic core.');
    });

    test('a cold (non-repeat) prompt emits no automation note', () async {
      // Default classify `unknown` → cold path, not a repeat.
      final booted = await bootBrain('ztmp/d54_norepeat');

      await booted.dispatcher.accept(_accessWith(text: 'what is a pulsar?'));

      expect(memory.automationNotes(), isEmpty);
    });
  });

  group('D.54-4 streamed answer through accept', () {
    test('a multi-chunk substrate stream is drained into the Conclusion',
        () async {
      // A genuinely chunked stream: the proof the body drained the whole stream
      // is that the persisted Conclusion is the concatenation of every chunk.
      substrate.answerChunks = <String>[
        'Back up by ',
        'rsyncing ',
        'nightly to the NAS.',
      ];
      final booted = await bootBrain('ztmp/d54_stream');

      await booted.dispatcher
          .accept(_accessWith(text: 'how do I automate backups?'));

      final conclusion = memory.persistedOfType('Conclusion').single;
      expect(conclusion.draft.values['statement'],
          'Back up by rsyncing nightly to the NAS.');
    });
  });
}

// ── Synthetic Access (no real channel) ──────────────────────────────────

Access _accessWith({
  String text = 'what is a quasar?',
  // A confident centroid hint names the procedure id to run (Q-E.50.1).
  String? kindHint = SystemProcedures.answerWithMemoryV1,
  DeliverCallback? deliver,
}) =>
    Access(
      envelope: InboundRequest(text: text, kindHint: kindHint),
      identity: ResolvedIdentity(principalId: 'p1'),
      session: Session(sessionId: 's1'),
      persona: Persona.assistant(),
      deliver: deliver ?? (chunk) => Stream<OutboundChunk>.value(chunk),
    );

RecallResult _recallWith(List<Node> nodes) => RecallResult(
      nodes: nodes,
      report: RecallReport(
        candidatesPerMode: <RecallMode, int>{RecallMode.bm25: nodes.length},
        fusionStrategy: FusionStrategy.rrf,
        diversityStrategy: DiversityStrategy.mmr,
        elapsedMs: 7,
      ),
    );

// ── A recording in-process `TomBrainMemoryClient` stub ──────────────────
//
// Implements enough of the store for the booted route's run recorder to open a
// trail, persist nodes (Event / Conclusion / InterestItem / ProcedureRun),
// draw edges (derived_from / produced_by), push the cold-path interest, and
// write the automation_candidate trail note — and records every one so a single
// `accept` resolution exposes the run's complete post-condition set. Mirrors
// the D.42 consolidated double, plus the explicit `open`/`close` the in-process
// provisioning seam (D.43) drives.
class _StubMemory implements TomBrainMemoryClient {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

  /// Every persisted node, in order, with the id the store assigned it.
  final List<({NodeId id, NodeDraft draft})> persisted =
      <({NodeId id, NodeDraft draft})>[];

  /// Every edge drawn, in order.
  final List<({NodeId from, EdgeType type, NodeId to})> recordedEdges =
      <({NodeId from, EdgeType type, NodeId to})>[];

  /// Empty by default — no cited nodes. Tests seed nodes for warm/repeat.
  RecallResult recallResult = const RecallResult(
    nodes: <Node>[],
    report: RecallReport(
      candidatesPerMode: <RecallMode, int>{},
      fusionStrategy: FusionStrategy.rrf,
      diversityStrategy: DiversityStrategy.mmr,
      elapsedMs: 0,
    ),
  );

  /// `unknown` by default — the cold-classification path (the prompt sits far
  /// from every centroid). Tests set this to `confident` for the warm path so
  /// no interest is pushed. The cold path is driven by `classify`, not by an
  /// empty recall (Q-D.40.1).
  ClassificationResult classifyResult = const ClassificationResult.unknown();

  /// The persisted nodes of a given type, in persist order.
  Iterable<({NodeId id, NodeDraft draft})> persistedOfType(String typeName) =>
      persisted.where((p) => p.draft.typeName == typeName);

  /// The `automation_candidate` notes written to *any* run trail (D.41). The
  /// booted route discards the `ProcedureOutcome`, so the note is read off the
  /// trail the recorder opened on this stub, not off a returned outcome.
  Iterable<Map<String, Object?>> automationNotes() => _trails.values
      .expand((entries) => entries)
      .where((e) =>
          e.kind == TrailEntryKind.note &&
          e.payload['category'] == automationCandidateCategory)
      .map((e) => e.payload['payload'] as Map<String, Object?>);

  @override
  Future<void> open(MemoryConfig config) async {}

  @override
  Future<void> close() async {}

  @override
  StackApi get stacks => _stacks;

  @override
  Future<RecallResult> recall(RecallQuery query) async => recallResult;

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

// ── An answer-capturing `TomBrainSubstrateClient` stub ──────────────────
//
// Emits a canned chunked stream terminated with Completed; the concatenation of
// `answerChunks` is the answer text the body produces. `open`/`close` are
// no-ops so the booted process can open it (when a config is given) and close
// it on shutdown.
class _StubSubstrate implements TomBrainSubstrateClient {
  List<String> answerChunks = <String>['ok'];

  @override
  Future<void> open(SubstrateConfig config) async {}

  @override
  Future<void> close() async {}

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
