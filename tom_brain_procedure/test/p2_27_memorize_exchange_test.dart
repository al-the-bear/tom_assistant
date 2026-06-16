// P2.27 — the memory curator (`memorize_exchange_v1`) as a D4rt script,
// end-to-end through the procedure engine against the real memory store.
//
// dream-subsystem redesign part f:
//   "Add an explicit step which asks the auxiliary LLM, for each prompt and
//    answer, what of this should be memorized … under which angles 'worth
//    storing' can be seen … and use the memory tools to store the information
//    and check what is already in memory."
//
// ── What this suite proves ──────────────────────────────────────────────
//
// `memorize_exchange_v1` is a shipped artifact under `scripts/system/`. This
// suite loads it through the production resolver path (`DiskProcedureStore` +
// `ProcedureResolver.fromStore`) and drives it through `ProcedureEngine.invoke`
// against a *real* on-disk `SqliteTomBrainMemory` and a *stub* substrate that
// returns a deterministic `TYPE :: statement` curator verdict (plus a 768-dim
// embedding). The store is the seam the curator actually calls, so this is the
// proof the post-exchange curation runs against the production memory stack.
//
//   Stores worthwhile items (the Verify) — over a finished exchange whose Event
//     is seeded, the curator's verdict (`Claim :: …` + `Question :: …`) lands as
//     a Claim row edged `derived_from` the exchange Event (its provenance link,
//     reported as a produced node) and a Question row pushed onto the
//     `questions_open` stack (carrying no edge, not a produced node). The run is
//     accepted (within its header budget) and `storedIds` reports both.
//   Stores nothing on NONE — when the curator finds nothing worth keeping it
//     emits the `NONE` sentinel; no node is written and `storedIds` is empty.
//   Within scope — the engine binds the curator's identity onto the memory
//     bridge, so the store's `AgentRegistry` confines the run. A curator
//     registered *without* the `node:Claim` write scope has its Claim write
//     refused with `AgentScopeViolation`: the run errors and no Claim row is
//     written.
//
// Like p2_21 these cases open the real on-disk store, which refuses to boot
// without the packaged vec0 binary (P1.1), so the group is skipped — not
// failed — when no binary is present for the platform.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show AgentRegistration, NodeDraft, Scope, Vec, WriteBudget;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

import 'stub_prompt_resolver.dart';

/// The bootstrap embedding model dimensionality (768, nomic-embed-text).
const _bootstrapDims = 768;

/// A deterministic 768-dim vector. The curator properties under test (parsing,
/// persistence, edging, stacking, scope) ride on the stub substrate, not on
/// embedding *values*, so a deterministic vector is sufficient.
Vec _v768({required int seed}) {
  final values = Float32List(_bootstrapDims);
  for (var i = 0; i < _bootstrapDims; i++) {
    values[i] = ((seed * 31 + i) % 1000) / 1000.0;
  }
  return Vec(values);
}

/// Locates `<workspace>/tom_binaries/sqlite_vec`. Mirrors p2_21.
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

/// Builds the exchange Event [NodeDraft] the curator's Claim is edged back to.
NodeDraft _eventDraft({required String summary, required int seed}) => NodeDraft(
      typeName: 'Event',
      values: <String, Object?>{
        'summary': summary,
        'payload': const <String, Object?>{},
        'occurred_at': '2026-06-05T10:00:00.000Z',
      },
      embedding: _v768(seed: seed),
    );

/// A budget that permits every store-side write — the procedure's own header
/// `budget:` block is what bounds the run; this agent budget only has to be
/// wide enough not to interfere.
WriteBudget _unboundedBudget() =>
    WriteBudget(maxNodes: 1000, maxEdges: 1000, maxStackEntries: 1000);

/// Registers the curator agent with the given write [scopes]. The happy path
/// passes its full declared surface; the scope-enforcement case omits
/// `node:Claim` so the Claim write is refused.
AgentRegistration _curatorAgent(Set<String> scopes) => AgentRegistration(
      agentName: 'memorize_exchange_v1',
      procedureId: 'memorize_exchange_v1',
      defaultBudget: _unboundedBudget(),
      readScopes: const <String>{AgentRegistration.globalWildcard},
      writeScopes: scopes,
    );

/// The curator's full declared write surface (memory § 9 / part f): it adds
/// Claim and Question nodes, the `derived_from` provenance edge, and pushes onto
/// the `questions_open` stack — and nothing else.
Set<String> _fullScope() => <String>{
      AgentRegistration.nodeScope('Claim'),
      AgentRegistration.nodeScope('Question'),
      AgentRegistration.edgeScope('derived_from'),
      AgentRegistration.stackScope('questions_open'),
    };

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

  MemoryConfig freshConfig() {
    final root = Directory.systemTemp.createTempSync('tbm_p2_27_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    return MemoryConfig.forTesting(root: root.path, binariesRoot: vecRoot!);
  }

  Future<SqliteTomBrainMemory> openStore() async {
    final store = SqliteTomBrainMemory();
    await store.open(freshConfig());
    addTearDown(store.close);
    return store;
  }

  /// Seeds the exchange Event the curator links its Claim back to, unscoped (the
  /// bootstrap/system write path, not a cognitive-agent write), and returns its
  /// id string — the `eventId` the curator edges `derived_from`.
  Future<String> seedExchangeEvent(SqliteTomBrainMemory store) async {
    final id = await store.persist(
      _eventDraft(
        summary: 'The user asked about their editor preferences.',
        seed: 100,
      ),
      scope: Scope(producer: 'p2.27:seed', idempotencyKey: 'seed-event'),
    );
    return id.value;
  }

  /// Builds an engine that runs `memorize_exchange_v1` under the curator
  /// identity, wired over the real [store] and the [substrate] stub. The memory
  /// bridge carries the agent name, so the store's `AgentRegistry` scopes every
  /// write the body issues.
  Future<ProcedureEngine> engineFor({
    required SqliteTomBrainMemory store,
    required TomBrainSubstrateClient substrate,
  }) async {
    final system = await ProcedureResolver.fromStore(
      DiskProcedureStore(systemDir: Directory('scripts/system')),
    );
    final prompts = StubPromptResolver(role: 'memory_curator');
    return ProcedureEngine(
      resolver: ProcedureResolver(<LoadedProcedure>[
        system.resolve('memorize_exchange_v1'),
        system.resolve('tool_loop_v1'),
      ]),
      memory: store,
      memoryBridge: MemoryBridge(store, agentName: 'memorize_exchange_v1'),
      substrateBridge: SubstrateBridge(
        substrate,
        promptResolver: prompts.resolver,
        routeChainOf: prompts.routeChainOf,
      ),
      now: () => DateTime.utc(2026, 6, 5, 12, 0, 0),
    );
  }

  Future<ProcedureOutcome> runCurator({
    required ProcedureEngine engine,
    required String prompt,
    required String answer,
    String? eventId,
  }) =>
      engine
          .invoke(ProcedureInvocation(
            procedureId: 'memorize_exchange_v1',
            arguments: <String, Object?>{
              'prompt': prompt,
              'answer': answer,
              'eventId': ?eventId,
            },
          ))
          .outcome;

  group('memory curator through the engine against real memory (needs vec0)',
      () {
    test('stores a Claim (edged derived_from the Event) and a Question '
        '(pushed onto questions_open)', () async {
      final store = await openStore();
      final eventId = await seedExchangeEvent(store);
      store.registerAgent(_curatorAgent(_fullScope()));

      final outcome = await runCurator(
        engine: await engineFor(
          store: store,
          substrate: _CuratorSubstrate(
            verdict: 'Claim :: The user prefers the dark editor theme.\n'
                'Question :: Which keybinding scheme does the user use?',
          ),
        ),
        prompt: 'I always work in dark mode.',
        answer: 'Noted — I will assume a dark editor theme.',
        eventId: eventId,
      );

      // Accepted ⇒ the run stayed within its declared header budget.
      expect(outcome.status, TrailOutcomeStatus.accepted);

      // The body returns every persisted id as `storedIds` (Claim + Question).
      final storedIds = outcome.result!.output<List<Object?>>('storedIds');
      expect(storedIds, isNotNull);
      expect(storedIds, hasLength(2));

      // The Verify: one Claim row and one Question row exist in the real store.
      final stats = await store.stats();
      expect(stats.nodeCountByType['Claim'] ?? 0, equals(1));
      expect(stats.nodeCountByType['Question'] ?? 0, equals(1));

      // The Claim records its provenance back to the exchange Event.
      expect(stats.edgeCountByType['derived_from'] ?? 0, equals(1),
          reason: 'the Claim is edged derived_from the exchange Event');

      // The Question is queued for the Researcher on `questions_open`; it
      // carries no outgoing edge, so no extra edge appears for it.
      final stackEntries = await store.stacks.peek('questions_open');
      expect(stackEntries, hasLength(1),
          reason: 'the Question is pushed onto questions_open');
    });

    test('stores nothing when the curator emits NONE', () async {
      final store = await openStore();
      final eventId = await seedExchangeEvent(store);
      store.registerAgent(_curatorAgent(_fullScope()));

      final outcome = await runCurator(
        engine: await engineFor(
          store: store,
          substrate: _CuratorSubstrate(verdict: 'NONE'),
        ),
        prompt: 'What time is it?',
        answer: 'It is just past noon.',
        eventId: eventId,
      );

      expect(outcome.status, TrailOutcomeStatus.accepted);

      final storedIds = outcome.result!.output<List<Object?>>('storedIds');
      expect(storedIds, isNotNull);
      expect(storedIds, isEmpty);

      // The Verify: the ephemeral exchange leaves no Claim or Question behind.
      final stats = await store.stats();
      expect(stats.nodeCountByType['Claim'] ?? 0, equals(0));
      expect(stats.nodeCountByType['Question'] ?? 0, equals(0));
      final stackEntries = await store.stacks.peek('questions_open');
      expect(stackEntries, isEmpty);
    });

    test('an out-of-scope curator Claim write is refused with '
        'AgentScopeViolation and writes no Claim', () async {
      final store = await openStore();
      final eventId = await seedExchangeEvent(store);

      // The curator is registered WITHOUT the `node:Claim` scope: its first
      // `mem.persist('Claim', …)` is rejected by the AgentRegistry before any
      // row is written — the "within scope" half.
      store.registerAgent(_curatorAgent(<String>{
        AgentRegistration.nodeScope('Question'),
        AgentRegistration.edgeScope('derived_from'),
        AgentRegistration.stackScope('questions_open'),
      }));

      final outcome = await runCurator(
        engine: await engineFor(
          store: store,
          substrate: _CuratorSubstrate(
            verdict: 'Claim :: The user prefers the dark editor theme.',
          ),
        ),
        prompt: 'I always work in dark mode.',
        answer: 'Noted.',
        eventId: eventId,
      );

      expect(outcome.status, isNot(TrailOutcomeStatus.accepted));
      expect(outcome.error, isA<AgentScopeViolation>());

      final stats = await store.stats();
      expect(stats.nodeCountByType['Claim'] ?? 0, equals(0),
          reason: 'the Claim write was refused, so no Claim row exists');
    });
  }, skip: skipNoBinary);
}

// ── A deterministic curator-substrate stub ──────────────────────────────
//
// Returns a fixed `TYPE :: statement` [verdict] for the curator's single
// `sub.run('dreaming.curator.worth_storing')` call, and a 768-dim embedding for
// each `sub.embed(...)` so the Claim/Question the body persists carries a
// dimension the store accepts. Mirrors p2_21's `_DreamSubstrate`.
class _CuratorSubstrate implements TomBrainSubstrateClient {
  _CuratorSubstrate({required this.verdict});

  /// The `TYPE :: statement` list (or `NONE`) every `sub.run(...)` returns.
  final String verdict;

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) {
    return Stream<LlmStreamEvent>.fromIterable(<LlmStreamEvent>[
      LlmStreamChunk(callId: 'c', text: verdict),
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
