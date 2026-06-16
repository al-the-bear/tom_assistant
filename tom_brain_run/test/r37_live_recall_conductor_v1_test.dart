// §19 — live verification of `recall_conductor_v1` against the local Gemma
// route (memory_optimization_plan.md § 19; memory_specification.md § 6.7,
// § 14).
//
// ── The open question this test exists to answer ─────────────────────
//
// The recall conductor was designed around a bet: that a *cheap local* model
// (Gemma on the mbp oMLX route) can drive the pre-answer recall-curation loop
// by replying in the SUFFICIENT / SEARCH / KEEP **line-directive** grammar the
// d4rt body parses. The sandbox cannot parse JSON tool-calls, so the loop
// speaks line directives instead of tool-calling (§ 6.7). The unit suite
// (`tom_brain_procedure/test/recall_conductor_v1_test.dart`, RC-1..RC-3) proves
// the loop *mechanics* on a scripted substrate. This suite closes the loop on
// the *real* question § 19 poses: **does live Gemma actually honour the
// directive grammar in the conductor loop?**
//
// ── Why it lives in tom_brain_run (not tom_brain_procedure) ──────────
//
// The conductor procedure ships in `tom_brain_procedure`, but that package is
// scope-disciplined to do **no HTTP** — its `dependency_surface_test` asserts
// `tom_core_server` is *not* a dependency, so it has no HTTP-capable platform.
// A live substrate call therefore belongs here, in the assembly package that
// owns `buildSubstrate` and the standalone platform, alongside the other
// `r3x_live_*` suites.
//
// ── Why a fake memory (not the real SQLite store) ────────────────────
//
// This isolates the directive-following question from the store. The conductor
// seed recall uses `bm25` + `vector` modes; the `vector` mode needs a query
// embedding (Ollama), which is **not** required to answer "does Gemma follow
// the grammar". The fake memory returns a fixed, backup-themed five-Claim seed
// with no embeddings, so the test runs on the oMLX endpoint alone — and stays
// green on bomber even while Ollama is down.
//
// ── Gating ───────────────────────────────────────────────────────────
//
// Skipped (never failed) when the oMLX endpoint is unreachable — a per-test
// awaited TCP probe, mirroring the #34/#35 live suites. Off-host records a
// clean skip; bomber (oMLX up) runs it green.
//
// ── Pass contract vs. recorded finding ───────────────────────────────
//
// The *hard* assertions are robustness guarantees that hold regardless of what
// Gemma replies: the run is accepted, returns a non-empty curated set drawn
// only from surfaced ids and capped at `volumeCap`, and every live report
// carries the assistant-dedication anchor. Whether Gemma *honoured* the grammar
// (curated a non-degraded set) versus the loop *degraded* to the seed is the
// live finding § 19 asks us to record — printed in a capture block, not a
// pass/fail gate (§ 19: "If it does not, record the finding and fall back to
// the seed-only path", which the body already does — proven by RC-3).
//
// Endpoint defaults (bomber) and overrides:
//   * oMLX — `TOM_BRAIN_OMLX_BASE_URI` (default `http://10.8.0.7:8000/`),
//            `TOM_BRAIN_OMLX_MODEL`    (default `gemma-4-26b-a4b-it-4bit`).
//     The base URI MUST carry a trailing slash — the OpenAI client resolves
//     `v1/chat/completions` against it relatively.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';
import 'package:tom_basics/tom_basics.dart' show TomPlatformUtils;
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:tom_brain_run/tom_brain_run.dart' show buildSubstrate;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, TrailId, Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';
import 'package:tom_core_server/tom_core_server.dart'
    show standalonePlatformUtils;

void main() {
  // The real providers source their wire HTTP client from the
  // `tom_core_kernel` factory via the active `TomPlatformUtils`; a bare
  // `dart test` runs the fallback platform, whose `httpClient()` throws.
  // Install the standalone platform so the live HTTP path is exercised
  // end-to-end (off-host runs skip before any HTTP call, so this is harmless).
  setUpAll(() {
    TomPlatformUtils.setCurrentPlatform(standalonePlatformUtils);
  });

  group('§19 / live recall conductor against Gemma (oMLX)', () {
    final omlx = _LiveEndpoint.resolve(
      baseUriEnv: 'TOM_BRAIN_OMLX_BASE_URI',
      defaultBaseUri: 'http://10.8.0.7:8000/',
      modelEnv: 'TOM_BRAIN_OMLX_MODEL',
      defaultModel: 'gemma-4-26b-a4b-it-4bit',
      daemonName: 'oMLX',
    );

    test(
      'the real conductor loop drives live Gemma; directive-following recorded',
      () async {
        final reason = await omlx.unreachableReason();
        if (reason != null) return markTestSkipped(reason);

        // The real substrate the run package manufactures, pointed at live
        // Gemma, with the bootstrap role roster (which carries `recaller`).
        final SubstrateConfig substrateConfig = SubstrateConfigLoader.parse(
          _conductorSubstrateYaml(omlx),
        );
        final InProcessTomBrainSubstrate substrate = buildSubstrate(
          substrateConfig,
          roleRegistry: bootstrapRoleRegistry(),
        );
        await substrate.open(substrateConfig);
        final tee = _TeeSubstrate(substrate);
        addTearDown(substrate.close);

        final memory = _ConductorFakeMemory();
        final memoryBridge = MemoryBridge(memory);
        // The prompt resolver fills the *production* curate template (the
        // directive-grammar instructions Gemma must obey) and pins the
        // `recaller` role + route, so the wire prompt Gemma sees is faithful.
        final substrateBridge = SubstrateBridge(
          tee,
          promptResolver: (String id, Map<String, Object?> inputs) async =>
              ResolvedPrompt(
            role: 'recaller',
            llmRoute: 'recaller',
            templateBody: _renderCurate(inputs),
            tools: const <Object?>[],
            maxToolLoops: 6,
            temperature: null,
            channel: null,
          ),
          routeChainOf: (String _) => <RouteEntry>[
            RouteEntry(providerId: 'omlx', model: omlx.model),
          ],
        );

        final Directory scriptsDir = await _resolveProcedureScripts();
        final ProcedureResolver system = await ProcedureResolver.fromStore(
          DiskProcedureStore(systemDir: scriptsDir),
        );
        final engine = ProcedureEngine(
          resolver: system,
          memory: memory,
          memoryBridge: memoryBridge,
          substrateBridge: substrateBridge,
        );

        final outcome = await engine
            .invoke(ProcedureInvocation(
              procedureId: 'recall_conductor_v1',
              arguments: <String, Object?>{
                'text': 'How do I automate my backups?',
                'volumeCap': 3,
                'maxRounds': 2,
              },
            ))
            .outcome;

        // The finding is the deliverable — extract and PRINT it first, so the
        // capture surfaces in the trail even when a later assert fails.
        expect(outcome.status, TrailOutcomeStatus.accepted,
            reason: 'the conductor must never fail the run — it degrades');
        final result = outcome.result!;
        final curated = result.output<List>('curatedIds')!.cast<String>();
        final degraded = result.output<bool>('degraded') ?? false;
        final searches = result.output<int>('searches') ?? 0;
        final rationale = result.output<Map>('rationale')!;
        final curatedNodes = result.output<List>('curatedNodes')!;

        // ── The live finding § 19 asks us to record ──────────────────────
        // `degraded == false` ⇒ the loop parsed ≥1 KEEP directive from Gemma's
        // reply (it followed the grammar). `degraded == true` ⇒ Gemma's replies
        // were unparseable / produced no keeps and the loop fell back to the
        // seed (the RC-3 path).
        final honoured = !degraded;
        final capture = StringBuffer()
          ..writeln('=== §19 LIVE CONDUCTOR CAPTURE ===')
          ..writeln('endpoint     : ${omlx.baseUri}')
          ..writeln('model        : ${omlx.model}')
          ..writeln('anchorHash   : ${AnchorRegistry.currentHash}')
          ..writeln('rounds(calls): ${tee.calls.length}')
          ..writeln('searches     : $searches')
          ..writeln('degraded     : $degraded')
          ..writeln('honoured     : $honoured  '
              '(Gemma emitted parseable KEEP/SEARCH directives)')
          ..writeln('curatedIds   : $curated')
          ..writeln('rationale    : $rationale');
        for (var i = 0; i < tee.calls.length; i++) {
          capture
            ..writeln('--- Gemma raw reply, round ${i + 1} ---')
            ..writeln(tee.calls[i].text.trim());
        }
        capture.writeln('=== END §19 LIVE CONDUCTOR CAPTURE ===');
        // ignore: avoid_print
        print(capture.toString());

        // ── Hard robustness contract (holds regardless of Gemma's reply) ──
        expect(curated, isNotEmpty,
            reason: 'a curated set is always returned (§ 6.7)');
        expect(curated.length, lessThanOrEqualTo(3),
            reason: 'curation is capped at volumeCap');
        for (final id in curated) {
          expect(memory.seedIds, contains(id),
              reason: 'only surfaced ids may be curated');
        }
        expect(curatedNodes.length, curated.length,
            reason: 'one node map per curated id');
        expect(tee.calls, isNotEmpty,
            reason: 'the conductor must have issued ≥1 live completion');
        for (final c in tee.calls) {
          expect(c.anchorHash, AnchorRegistry.currentHash,
              reason: 'the anchor invariant holds on every live call');
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test('the oMLX endpoint resolves to a well-formed http target', () {
      expect(omlx.baseUri.host, isNotEmpty);
      expect(omlx.baseUri.hasPort, isTrue);
      expect(omlx.baseUri.path, endsWith('/'),
          reason: 'OpenAI client resolves v1/... relatively — needs a slash');
      expect(omlx.model, isNotEmpty);
    });
  });
}

/// The substrate-only YAML for the conductor smoke: the oMLX transport and the
/// `recaller` route (which the curate prompt assumes). An Ollama embedding
/// block is declared for config-shape completeness but is never exercised — the
/// fake memory does not embed, so no Ollama daemon is required.
String _conductorSubstrateYaml(_LiveEndpoint omlx) => '''
substrate:
  providers:
    - id: omlx
      kind: openai
      baseUrl: ${omlx.baseUri}
      models:
        - ${omlx.model}
    - id: ollama
      kind: ollama
      baseUrl: http://127.0.0.1:11434/
      models:
        - nomic-embed-text
  roleRoutes:
    recaller:
      - providerId: omlx
        model: ${omlx.model}
    assistant_to_user:
      - providerId: omlx
        model: ${omlx.model}
  embedding:
    providerId: ollama
    model: nomic-embed-text
    dims: 768
    normalize: true
''';

/// Renders the production curate prompt body against [inputs]. Mirrors
/// `tom_brain_run/config/bomber/cognition/assist_user/recall_conductor.curate.user.md`
/// verbatim, so the directive-grammar instructions Gemma is asked to obey are
/// the production ones; only the `${prompt}` / `${surfaced}` slots are filled.
String _renderCurate(Map<String, Object?> inputs) {
  final prompt = '${inputs['prompt'] ?? ''}';
  final surfaced = '${inputs['surfaced'] ?? ''}';
  return '''
Decide whether the memory surfaced so far is enough to answer the user's prompt, then either ask for more or curate the set the answer stage will use.

User prompt:
$prompt

Surfaced memory (one per line, `nodeId :: summary`):
$surfaced

Reply using ONLY these line directives, one per line, and nothing else:

- `SUFFICIENT: yes` or `SUFFICIENT: no` — your overall judgement (informational).
- `SEARCH: <kind> <query>` — request a targeted re-search. `<kind>` is one of: old, cold, prompts, answers, multi, recall. Use these when the surfaced set is missing something the prompt needs (e.g. older or rarely-used memory).
- `KEEP: <nodeId> | <one-line reason>` — curate a surfaced node into the final set. Use the exact id from the surfaced list.

Rules:
- If the surfaced set is enough, emit only `KEEP:` lines (one per node worth keeping) — this ends the curation.
- If it is not enough, emit `SEARCH:` lines instead; you will see the new results next round.
- Keep only nodes that genuinely help answer the prompt; prefer a small set over padding. Never invent an id that is not in the surfaced list.
''';
}

/// Resolves the procedure package's shipped `scripts/system` directory via its
/// package URI, independent of the test's working directory (mirrors #35).
Future<Directory> _resolveProcedureScripts() async {
  final Uri? libUri = await Isolate.resolvePackageUri(
    Uri.parse('package:tom_brain_procedure/tom_brain_procedure.dart'),
  );
  if (libUri == null) {
    throw StateError(
      'cannot resolve the tom_brain_procedure package URI — '
      'is it on the package config?',
    );
  }
  return Directory.fromUri(libUri.resolve('../scripts/system'));
}

// ─── Live endpoint + async reachability probe (mirrors #34/#35) ─────

class _LiveEndpoint {
  final Uri baseUri;
  final String model;
  final String daemonName;

  _LiveEndpoint._(this.baseUri, this.model, this.daemonName);

  factory _LiveEndpoint.resolve({
    required String baseUriEnv,
    required String defaultBaseUri,
    required String modelEnv,
    required String defaultModel,
    required String daemonName,
  }) {
    final env = Platform.environment;
    final model = env[modelEnv] ?? defaultModel;
    Uri parsed;
    try {
      parsed = Uri.parse(env[baseUriEnv] ?? defaultBaseUri);
    } on FormatException {
      parsed = Uri.parse(defaultBaseUri);
    }
    final port =
        parsed.hasPort ? parsed.port : (parsed.scheme == 'https' ? 443 : 80);
    final path = parsed.path.endsWith('/') ? parsed.path : '${parsed.path}/';
    return _LiveEndpoint._(parsed.replace(port: port, path: path), model,
        daemonName);
  }

  Future<String?> unreachableReason() async {
    try {
      final socket = await Socket.connect(baseUri.host, baseUri.port,
          timeout: const Duration(seconds: 2));
      socket.destroy();
      return null;
    } on Object catch (e) {
      return 'no TCP connect to ${baseUri.host}:${baseUri.port} within 2s '
          '($daemonName not reachable; this live verification is skipped '
          'off-host by design): $e';
    }
  }
}

// ─── A teeing substrate client (records Gemma's raw reply per call) ──

/// One live completion's capture: the concatenated streamed text (Gemma's raw
/// reply) and the terminal report's anchor hash.
class _CapturedCall {
  final String text;
  final String anchorHash;
  _CapturedCall(this.text, this.anchorHash);
}

/// Wraps a live [TomBrainSubstrateClient], recording the concatenated chunk
/// text and the terminal report's anchor hash of every `completeStream` call
/// (the conductor's only substrate entry point under `tools: none`), teeing
/// without consuming — every event still flows through to the conductor.
class _TeeSubstrate implements TomBrainSubstrateClient {
  _TeeSubstrate(this._inner);
  final TomBrainSubstrateClient _inner;
  final List<_CapturedCall> calls = <_CapturedCall>[];

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) async* {
    // Record on the *terminal* event, not after the `await for` completes: the
    // bridge's consumer (`substrate_bridge.dart` line 747) breaks out of the
    // stream as soon as it sees the terminal event, which cancels this async*
    // generator — so any `calls.add` placed after the loop would never run.
    final buf = StringBuffer();
    await for (final ev in _inner.completeStream(call)) {
      if (ev is LlmStreamChunk) buf.write(ev.text);
      if (ev is LlmStreamCompleted) {
        calls.add(_CapturedCall(buf.toString(), ev.report.anchorHash));
      }
      if (ev is LlmStreamFailed) {
        calls.add(_CapturedCall(buf.toString(), ev.report.anchorHash));
      }
      yield ev;
    }
  }

  @override
  Future<void> open(SubstrateConfig config) => _inner.open(config);

  @override
  Future<void> close() => _inner.close();

  @override
  Future<LlmCallReport> complete(LlmCall call) => _inner.complete(call);

  @override
  Future<EmbeddingResult> embed(String text) => _inner.embed(text);

  @override
  Future<List<EmbeddingResult>> embedBatch(List<String> texts) =>
      _inner.embedBatch(texts);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      _inner.noSuchMethod(invocation);
}

// ─── A recall-capturing fake `TomBrainMemory` ──────────────────────
//
// Returns a fixed, backup-themed five-Claim seed for every recall (seed + every
// re-search), needs no vec0 / no embeddings, and models just enough of the
// store for the run recorder's writes to succeed. (Mirrors the unit suite's
// fake — duplicated here because test files cannot be shared across packages.)
class _ConductorFakeMemory implements TomBrainMemory {
  final _FakeStacks _stacks = _FakeStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

  final List<RecallQuery> recallQueries = <RecallQuery>[];
  MultiRecallQuery? lastMultiRecallQuery;

  static const List<String> _seedStatements = <String>[
    'A nightly cron job rsyncs /home to the bomber NAS at 02:00.',
    'Weekly full backups are written to an external USB drive kept off-site.',
    'The user prefers automated backups over manual copies.',
    'Restic with a B2 remote was evaluated but not yet adopted.',
    'Database dumps are excluded from the rsync set and handled separately.',
  ];

  final List<Node> _seedNodes = <Node>[
    for (var i = 1; i <= 5; i++)
      Node(
        id: NodeId.fromString('n_0000000000000000000000000$i'),
        typeName: 'Claim',
        values: <String, Object?>{'statement': _seedStatements[i - 1]},
        createdAt: DateTime.utc(2026, 6, 1),
      ),
  ];

  List<String> get seedIds =>
      _seedNodes.map((n) => n.id.value).toList(growable: false);

  RecallResult _seedResult() => RecallResult(
        nodes: _seedNodes,
        report: const RecallReport(
          candidatesPerMode: <RecallMode, int>{RecallMode.bm25: 5},
          fusionStrategy: FusionStrategy.rrf,
          diversityStrategy: DiversityStrategy.mmr,
          elapsedMs: 3,
        ),
      );

  @override
  StackApi get stacks => _stacks;

  @override
  Future<RecallResult> recall(RecallQuery query) async {
    recallQueries.add(query);
    return _seedResult();
  }

  @override
  Future<RecallResult> recallMulti(MultiRecallQuery query) async {
    lastMultiRecallQuery = query;
    return _seedResult();
  }

  @override
  Future<ClassificationResult> classify(
    Vec embedding, {
    ClassificationTarget target = ClassificationTarget.nodeType,
  }) async =>
      const ClassificationResult.unknown();

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

class _FakeStacks implements StackApi {
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
