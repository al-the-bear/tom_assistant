// Shared in-process boot doubles for the booted-dispatcher suites (HC-34).
//
// `BrainProcessBoot.boot` needs three collaborators that every boot-level test
// fakes the same way: an in-process `TomBrainMemory`, its `StackApi`, and a
// `TomBrainSubstrateClient` that answers (and, in some suites, captures) the
// assembled prompt. These were copy-pasted across four test files
// (`boot_history_injection_test.dart`, `boot_turn_summary_sink_test.dart`,
// `history_compaction_pipeline_test.dart`,
// `history_provider_independence_test.dart`); this module hosts the one copy
// they now share.
//
// The doubles are deliberate supersets of the per-file variants — the memory
// records every persisted node, and the substrate handles the confirmation
// call, the thinking-lane `evaluator` critique, the matrix `sessionMode`, and
// optional wire capture. A suite that does not exercise one of those branches is
// unaffected by its presence, so the union changes no observed behaviour.

import 'dart:typed_data';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, TrailId, Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

/// A fixed substrate `LlmCallReport` — the value is never asserted on by the
/// boot suites, so a single descriptive constant serves every completion.
const String _anchorHash = 'sha256:anchor';
const LlmCallReport _report = LlmCallReport(
  providerId: 'p',
  modelId: 'm',
  anchorHash: _anchorHash,
  promptHash: 'pr',
  tokensIn: 1,
  tokensOut: 1,
  retries: 0,
  wallClockMs: 1,
);

/// In-process `TomBrainMemory` for the booted-dispatcher suites.
///
/// Trails, nodes, edges, recall and classification are all served from memory.
/// Every persisted node is recorded in [persisted] (and reachable by type via
/// [persistedOfType]) for the suites that assert the cold-path write; the suites
/// that ignore it simply never read the list.
class BootMemory implements TomBrainMemory {
  final InMemoryStacks _stacks = InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

  /// Every node persisted through [persist], in order, for cold-path assertions.
  final List<({NodeId id, NodeDraft draft})> persisted =
      <({NodeId id, NodeDraft draft})>[];

  RecallResult recallResult = const RecallResult(
    nodes: <Node>[],
    report: RecallReport(
      candidatesPerMode: <RecallMode, int>{},
      fusionStrategy: FusionStrategy.rrf,
      diversityStrategy: DiversityStrategy.mmr,
      elapsedMs: 0,
    ),
  );

  ClassificationResult classifyResult = const ClassificationResult.unknown();

  /// The persisted nodes whose draft type is [typeName], in persist order.
  Iterable<({NodeId id, NodeDraft draft})> persistedOfType(String typeName) =>
      persisted.where((p) => p.draft.typeName == typeName);

  @override
  Future<void> open(MemoryConfig config) async {}

  @override
  Future<void> close() async {}

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

/// In-process `StackApi` for the booted-dispatcher suites.
class InMemoryStacks implements StackApi {
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

/// Prompt-answering substrate for the booted-dispatcher suites.
///
/// Behaviour, all of which is dormant unless a suite exercises it:
///  * the answer call streams [answerChunks] and records the assembled prompt as
///    [lastPrompt];
///  * the trailing `assistant_to_user` completion-confirmation call (agent-loop
///    completion plan § 3.1) is answered with `DONE` so it terminates the loop
///    without overwriting [lastPrompt];
///  * the thinking lane's `evaluator` self-critique is answered with `ACCEPT` so
///    the recursive loop exits after one pass;
///  * [sessionMode], when given, is recorded as [answeredUnderSessionMode] on
///    the answer call — modelling how the real substrate takes the Claude-Code
///    session mode at construction and never feeds it into the prompt;
///  * with [emitWire] set, the answer completion carries a [CapturedWirePrompt]
///    for suites that read the wire.
class BootSubstrate implements TomBrainSubstrateClient {
  BootSubstrate({this.sessionMode, this.emitWire = false});

  /// The Claude-Code session mode (none / brain / quest) this substrate answers
  /// under, or null when the suite does not vary it.
  final String? sessionMode;

  /// Whether the answer completion carries a [CapturedWirePrompt].
  final bool emitWire;

  /// The chunks the answer call streams.
  List<String> answerChunks = <String>['ok'];

  /// The assembled prompt of the most recent answer call.
  String? lastPrompt;

  /// The [sessionMode] in effect when the substrate produced the captured answer
  /// prompt — asserted on to prove a matrix crossed every mode.
  String? answeredUnderSessionMode;

  static const String _confirmationSentinel =
      'You have just produced an answer for the user.';

  @override
  Future<void> open(SubstrateConfig config) async {}

  @override
  Future<void> close() async {}

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) {
    // Thinking lane self-critique: ACCEPT on the first pass so the recursive
    // loop exits after one iteration. Never invoked by the linear answer lanes.
    if (call.roleId == 'evaluator') {
      return _terminal('ACCEPT');
    }
    final rawPrompt = call.inputs['prompt'] as String?;
    final isConfirmation = call.roleId == 'assistant_to_user' &&
        rawPrompt != null &&
        rawPrompt.trimLeft().startsWith(_confirmationSentinel);
    // The confirmation call terminates the loop with `DONE`; only the answer
    // prompt is captured for assertion.
    if (isConfirmation) {
      return _terminal('DONE');
    }
    lastPrompt = rawPrompt;
    answeredUnderSessionMode = sessionMode;
    return Stream<LlmStreamEvent>.fromIterable(<LlmStreamEvent>[
      for (final chunk in answerChunks)
        LlmStreamChunk(callId: 'c', text: chunk),
      LlmStreamCompleted(
        callId: 'c',
        wire: emitWire
            ? CapturedWirePrompt(
                body: 'ANCHOR\n\n${rawPrompt ?? ''}',
                anchorHash: _anchorHash,
                roleId: call.roleId,
              )
            : null,
        report: _report,
      ),
    ]);
  }

  /// A one-chunk completion carrying [text] — the short role-keyed replies
  /// (`DONE` / `ACCEPT`) that terminate a loop without contributing answer text.
  Stream<LlmStreamEvent> _terminal(String text) =>
      Stream<LlmStreamEvent>.fromIterable(<LlmStreamEvent>[
        LlmStreamChunk(callId: 'c', text: text),
        const LlmStreamCompleted(callId: 'c', report: _report),
      ]);

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
