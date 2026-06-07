// P2.24 — `answer_with_memory_v1` through real D4rt execution against the
// real memory store.
//
// prototype_implementation_plan_2.md #24:
//   "Procedure engine: verify real D4rt execution of `answer_with_memory_v1`.
//    Confirm `D4rtDcliHost` runs the on-disk
//    `scripts/system/answer_with_memory_v1.dart` through the real `tom_d4rt`
//    interpreter with the `MemoryBridge` + `SubstrateBridge` globals, against
//    the real memory store and real substrate. Test: engine-level test driving
//    the script with stub substrate + real store, asserting the five-step body
//    (recall → llm → persist Event+Conclusion + edges → interest push →
//    automation note). Verify: the script's writes appear in the real store."
//
// ── Why this is not d36–d42 again ───────────────────────────────────────
//
// D.36–D.42 each drive the same shipped artifact through the engine, but
// against a *mock* `TomBrainMemoryClient` whose `persist` records the draft and
// never validates it. The real `SqliteTomBrainMemory` is stricter: every
// bootstrap node type with an `embedding.source_fields` policy (Event,
// Conclusion, InterestItem all do) refuses a draft that arrives without a
// supplied embedding — "memory does not embed lazily" (`node_persister.dart`,
// `EmbeddingPolicyViolation.missingEmbedding`). So a body that writes those
// nodes only lands them in the *real* store if it embeds them first. This suite
// is the first to drive the body through `D4rtDcliHost` (the real `tom_d4rt`
// interpreter, the real `mem`/`sub` bridge globals) against the production
// store, so it is the first to prove the script's writes actually appear there.
//
// Like p2_15 – p2_21 these cases open the real on-disk store, which refuses to
// boot without the packaged vec0 binary (P1.1), so the group is skipped — not
// failed — when no binary is present for the platform.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show NodeDraft, Scope, Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';

/// The bootstrap embedding model dimensionality (768, nomic-embed-text). Every
/// embedding the stub substrate returns carries this dimension so the store's
/// embedding-policy check accepts the persisted Event / Conclusion /
/// InterestItem.
const _bootstrapDims = 768;

/// A deterministic 768-dim vector. The properties under test (the body's writes
/// landing in the real store) ride on the *presence* of a dimension-correct
/// embedding and on BM25 recall, not on embedding *values*, so a deterministic
/// vector is sufficient.
Vec _v768({required int seed}) {
  final values = Float32List(_bootstrapDims);
  for (var i = 0; i < _bootstrapDims; i++) {
    values[i] = ((seed * 31 + i) % 1000) / 1000.0;
  }
  return Vec(values);
}

/// Locates `<workspace>/tom_binaries/sqlite_vec`. Mirrors p2_16 – p2_21.
String? _findSqliteVecRoot() {
  var dir = Directory.current.absolute;
  for (var i = 0; i < 8; i++) {
    final candidate =
        Directory('${dir.path}${Platform.pathSeparator}tom_binaries'
            '${Platform.pathSeparator}sqlite_vec');
    if (candidate.existsSync()) return candidate.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

void main() {
  final vecRoot = _findSqliteVecRoot();
  final resolver = SqliteVecBinaryResolver();

  String? resolvedPath;
  if (vecRoot != null && resolver.isSupported) {
    final path = resolver.resolve(vecRoot);
    if (File(path).existsSync()) resolvedPath = path;
  }

  final skipNoBinary = resolvedPath == null
      ? 'No packaged vec0 binary for this platform under '
          'tom_binaries/sqlite_vec (resolver.isSupported='
          '${resolver.isSupported}, vecRoot=$vecRoot).'
      : null;

  /// A fresh real-store config rooted in a unique temp dir, with teardown.
  MemoryConfig freshConfig() {
    final root = Directory.systemTemp.createTempSync('tbm_p2_24_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    return MemoryConfig.forTesting(root: root.path, binariesRoot: vecRoot!);
  }

  /// Opens a fresh real store with teardown registered.
  Future<SqliteTomBrainMemory> openStore() async {
    final store = SqliteTomBrainMemory();
    await store.open(freshConfig());
    addTearDown(store.close);
    return store;
  }

  /// Builds an engine that runs the shipped `answer_with_memory_v1` artifact
  /// from `scripts/system/` through the real `D4rtDcliHost`, wired over the real
  /// [store] and the [substrate] stub. The memory bridge carries no agent
  /// identity — the user-facing answer procedure runs unscoped (memory § 9 /
  /// `MemoryBridge.agentName == null`).
  Future<ProcedureEngine> engineFor({
    required SqliteTomBrainMemory store,
    required TomBrainSubstrateClient substrate,
  }) async {
    final system = await ProcedureResolver.fromStore(
      DiskProcedureStore(systemDir: Directory('scripts/system')),
    );
    return ProcedureEngine(
      // Load the full system set: `answer_with_memory_v1` step-1 recall now
      // dispatches the `retrieve_for_prompt_v1` conductor and its five
      // `recall_*` sub-procedures (Extension-H step #30), so they must all be
      // resolvable.
      resolver: ProcedureResolver(
        system.ids.map(system.resolve).toList(),
      ),
      memory: store,
      memoryBridge: MemoryBridge(store),
      substrateBridge: SubstrateBridge(substrate),
      now: () => DateTime.utc(2026, 6, 5, 12, 0, 0),
    );
  }

  Future<ProcedureOutcome> runAnswer({
    required ProcedureEngine engine,
    required String text,
  }) =>
      engine
          .invoke(ProcedureInvocation(
            procedureId: 'answer_with_memory_v1',
            arguments: <String, Object?>{'text': text},
          ))
          .outcome;

  group('answer_with_memory_v1 through real D4rt against real memory (needs '
      'vec0)', () {
    test('cold path: a single run persists Event + Conclusion + InterestItem '
        'into the real store and pushes the interest', () async {
      final store = await openStore();
      final substrate = _AnswerSubstrate(
        answer: 'Configure the bomber server via its provisioning manifest.',
      );
      final engine = await engineFor(store: store, substrate: substrate);

      final outcome = await runAnswer(
        engine: engine,
        text: 'how do I configure the bomber server?',
      );

      // The run is accepted ⇒ the body's writes all landed in the real store
      // (a refused write — e.g. a missing embedding — closes the run errored).
      expect(outcome.status, TrailOutcomeStatus.accepted,
          reason: 'the body must persist into the real store without an '
              'EmbeddingPolicyViolation: ${outcome.error}');

      // The declared `answer` output is the substrate completion.
      expect(outcome.result!.output<String>('answer'),
          'Configure the bomber server via its provisioning manifest.');

      // The Verify: the script's writes appear in the real store.
      final stats = await store.stats();
      expect(stats.nodeCountByType['Event'], 1,
          reason: 'the inbound prompt becomes one Event');
      expect(stats.nodeCountByType['Conclusion'], 1,
          reason: 'the answer becomes one Conclusion');
      expect(stats.nodeCountByType['InterestItem'], 1,
          reason: 'a fresh store has no centroids, so classify is `unknown` '
              '(cold start) and the body records an InterestItem');

      // The interest was pushed onto the bootstrap `interests` stack.
      final interests = await store.stacks.peek('interests');
      expect(interests, hasLength(1));

      // A produced_by edge ties the Conclusion to its ProcedureRun (drawn by
      // the recorder from the body's `producedNodeIds`).
      expect(stats.edgeCountByType['produced_by'] ?? 0, greaterThan(0));

      // Cold path: empty recall ⇒ no derived_from edges, no automation note.
      expect(stats.edgeCountByType['derived_from'] ?? 0, 0);
      expect(
        outcome.entries.where((e) =>
            e.kind == TrailEntryKind.note &&
            e.payload['category'] == automationCandidateCategory),
        isEmpty,
      );
    }, skip: skipNoBinary);

    test('warm + repeat path: a prompt that recalls a prior identical Event '
        'draws a derived_from edge and emits an automation_candidate note',
        () async {
      final store = await openStore();
      const prompt = 'what is the bomber project deployment cadence?';

      // Seed a prior Event whose `summary` is *exactly* this prompt — the
      // resurfaced earlier turn that (a) gives the new Conclusion a node to be
      // derived_from, and (b) makes this prompt an identical-shape repeat. One
      // seed keeps the run's writes small and deterministic (Event + Conclusion
      // + 1 edge + InterestItem + stack push = 5), comfortably under the
      // script's `memoryWrites: 16` header budget.
      await store.persist(
        NodeDraft(
          typeName: 'Event',
          values: <String, Object?>{
            'summary': prompt,
            'payload': const <String, Object?>{},
            'occurred_at': '2026-06-01T09:00:00.000Z',
          },
          embedding: _v768(seed: 7),
        ),
        scope: Scope(producer: 'p2.24:seed', idempotencyKey: 'seed-prior'),
      );

      final outcome = await runAnswer(
        engine: await engineFor(
          store: store,
          substrate: _AnswerSubstrate(answer: 'Nightly, to the NAS device.'),
        ),
        text: prompt,
      );
      expect(outcome.status, TrailOutcomeStatus.accepted,
          reason: 'the run must stay within its header budget: '
              '${outcome.error}');

      // The Verify: a derived_from edge from the new Conclusion to the recalled
      // prior Event appears in the real store.
      final stats = await store.stats();
      expect(stats.edgeCountByType['derived_from'] ?? 0, greaterThan(0),
          reason: 'the new Conclusion is derived_from the recalled prior Event');
      expect(stats.nodeCountByType['Event'], 2,
          reason: 'the seeded prior Event plus this run\'s inbound-prompt Event');

      // The automation_candidate note fired: recall surfaced an Event whose
      // summary equals this prompt (the cheap identical-shape repetition check).
      final notes = outcome.entries
          .where((e) =>
              e.kind == TrailEntryKind.note &&
              e.payload['category'] == automationCandidateCategory)
          .map((e) => e.payload['payload'] as Map<String, Object?>)
          .toList();
      expect(notes, hasLength(1));
      expect(notes.single['signature'], prompt);
    }, skip: skipNoBinary);
  });
}

// ── A deterministic answer-substrate stub ───────────────────────────────
//
// Returns a single-chunk completion of [answer] for every `sub.llm(...)`, and a
// dimension-correct (768-dim) embedding for every `sub.embed(...)`. The body
// must supply that embedding to the real store on each Event / Conclusion /
// InterestItem write, so the embedding *dimension* (not its values) is what
// matters here. Mirrors the p2_21 dream-substrate double.
class _AnswerSubstrate implements TomBrainSubstrateClient {
  _AnswerSubstrate({required this.answer});

  /// The single completion every `sub.llm(...)` returns.
  final String answer;

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) {
    return Stream<LlmStreamEvent>.fromIterable(<LlmStreamEvent>[
      LlmStreamChunk(callId: 'c', text: answer),
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
        vec: _v768(seed: text.length),
        modelIdentity: const EmbeddingModelIdentity(
          providerId: 'p',
          modelId: 'nomic-embed-text',
          dims: _bootstrapDims,
          normalized: true,
        ),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
