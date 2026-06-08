// #35 — LIVE end-to-end + phase-end review (Extension H), the retrieval
// conductor.
//
// Plan-2 step #34 (verbatim, `prototype_implementation_plan_2.md`):
//
//   "Live e2e + phase-end review (Extension H). Add a `tom_brain_run` live test
//    (alongside `r32`/`r34`): seed a throwaway profile with a corpus where the
//    answer is phrased unlike the question and a target sits two edges from the
//    prompt topic → run a real prompt through `retrieve_for_prompt_v1` against
//    the live on-disk store + live oMLX → assert the HyDE + semantic seeds
//    surface the targets that naive recall misses, the fused context carries
//    provenance, and the profile is dropped at the end."
//
// ── What this suite proves (and how it differs from #32 / #34) ───────
//
// #32 drives the foreground answer chain live; #34 drives the background
// dreaming chain live. #35 drives the *retrieval conductor* live: it stands a
// throwaway memory **profile** up, seeds it with a tiny labelled corpus whose
// answer is phrased unlike the question (a `Conclusion`) plus two `Concept`s,
// then runs the same prompt twice through `retrieve_for_prompt_v1` over the
// real on-disk store + the real oMLX + Ollama substrate:
//
//   * Naive (`withOnly(['vector.prompt'])`) — the conductor's single inline
//     `vector.prompt` seed is text-only; memory never embeds on the caller's
//     behalf (recall_executor), so a null-embedding vector seed degrades to no
//     candidates. With every sub-procedure gated off, the fused recall is
//     **empty**. This is the "naive misses it" baseline.
//
//   * HyDE + semantic (`withOnly(['vector.prompt', 'vector.hypothetical_answers',
//     'symbolic.type_filter_by_classify'])`) — enables `recall_hyde_v1` and
//     `recall_semantic_v1` (and only those). HyDE drafts plausible *answers*
//     with live oMLX (`hypothesis_writer`), embeds them with live Ollama, and
//     the answer-shaped embedding surfaces the `Conclusion` whose text reads
//     unlike the question. The semantic leg, on a cold store with no Concept
//     centroids, escalates to the live `category_selector` role and seeds a
//     symbolic recall on the proposed Concept names / node types — surfacing a
//     `Concept`. So the enriched config returns nodes the naive config cannot.
//
// The fused result carries per-node `provenance` (index-aligned `nodeId` +
// `seedIndexes` + `fusedScore`), and the throwaway profile is created before
// the run and dropped after — the whole-store reset-to-zero (memory § 2.5).
//
// The substrate here is the *real* `InProcessTomBrainSubstrate` the run package
// manufactures (`buildSubstrate`), with the eleven-role
// `bootstrapRoleRegistryWithRetrieval()` roster so the four routed retrieval
// roles validate at `open()`. So this suite only passes when both daemons are
// live; off-host it skips (a per-test reachability probe) and on a platform with
// no packaged vec0 the whole group skips (the on-disk store loads the extension
// at `open`).
//
// ── On "a target two edges from the prompt topic" (plan vs shipped) ───
//
// The plan phrases the semantic target as "two edges from the prompt topic" —
// a graph-walk framing. The shipped `recall_semantic_v1` cheap path cannot turn
// a Concept *name* into a start NodeId without a second lookup, so on a cold
// store it seeds a *symbolic* recall on the Concept name / node type the live
// `category_selector` proposes (procedure header Q-H.30.1), not a graph walk.
// This suite asserts the shipped behaviour — a `Concept` the symbolic semantic
// seed surfaces — and the spec's § 23.2 reconciliation note records that the
// graph-walk seed is a documented-but-unwired catalogue entry, while the
// name→symbolic seed is the realised semantic contribution.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';
import 'package:tom_basics/tom_basics.dart' show TomPlatformUtils;
import 'package:tom_brain_memory/tom_brain_memory.dart'
    show SqliteTomBrainMemory, SqliteVecBinaryResolver;
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart'
    show
        DiskProcedureStore,
        MemoryBridge,
        MemoryRetrievalConfig,
        ProcedureEngine,
        ProcedureInvocation,
        ProcedureResolver,
        SubstrateBridge;
import 'package:tom_brain_run/tom_brain_run.dart' show buildSubstrate;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        MemoryConfig,
        NodeDraft,
        Scope,
        SqliteVecConfig,
        TrailOutcomeStatus,
        Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show
        InProcessTomBrainSubstrate,
        SubstrateConfig,
        SubstrateConfigLoader,
        bootstrapRoleRegistryWithRetrieval;
import 'package:tom_core_server/tom_core_server.dart'
    show standalonePlatformUtils;

/// The retrieval conductor procedure id (its scripts live in the procedure
/// prototype's shipped `scripts/system`).
const String _conductorId = 'retrieve_for_prompt_v1';

/// The throwaway memory profile the suite provisions, seeds, queries, drops.
const String _profileName = 'r35_retrieval_e2e';

/// Locates `<workspace>/tom_binaries/sqlite_vec`. Mirrors the #34 suite.
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

/// A live daemon endpoint: its (slash-terminated) base URI and the model id to
/// exercise. Resolution is synchronous and reads env overrides; reachability is
/// a separate, awaited TCP probe done inside the test body. Mirrors #34.
class _LiveEndpoint {
  final Uri baseUri;
  final String model;
  final String daemonName;

  _LiveEndpoint._(this.baseUri, this.model, this.daemonName);

  /// Reads `[baseUriEnv]` (default [defaultBaseUri]) and `[modelEnv]` (default
  /// [defaultModel]); normalises the base URI to an explicit port + trailing
  /// slash so the providers' relative path resolution keeps the host.
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
    return _LiveEndpoint._(
      parsed.replace(port: port, path: path),
      model,
      daemonName,
    );
  }

  /// One awaited `Socket.connect` with a two-second timeout. Returns `null` when
  /// reachable, or a skip-rationale string when not.
  Future<String?> unreachableReason() async {
    try {
      final socket = await Socket.connect(baseUri.host, baseUri.port,
          timeout: const Duration(seconds: 2));
      socket.destroy();
      return null;
    } on Object catch (e) {
      return 'no TCP connect to ${baseUri.host}:${baseUri.port} within 2s '
          '($daemonName not reachable; this live e2e is skipped off-host by '
          'design): $e';
    }
  }
}

/// oMLX (OpenAI-compatible chat) — base URI MUST be host-only (no `/v1`); the
/// passthrough provider resolves `v1/chat/completions` relatively.
_LiveEndpoint _omlx() => _LiveEndpoint.resolve(
      baseUriEnv: 'TOM_BRAIN_OMLX_BASE_URI',
      defaultBaseUri: 'http://10.8.0.7:8000/',
      modelEnv: 'TOM_BRAIN_OMLX_MODEL',
      defaultModel: 'gemma-4-26b-a4b-it-4bit',
      daemonName: 'oMLX',
    );

/// Ollama (embeddings). Defaults to the on-box daemon (`nomic-embed-text`, 768
/// dims); Ollama binds loopback, so the default is `127.0.0.1`.
_LiveEndpoint _ollama() => _LiveEndpoint.resolve(
      baseUriEnv: 'TOM_BRAIN_OLLAMA_BASE_URI',
      defaultBaseUri: 'http://127.0.0.1:11434/',
      modelEnv: 'TOM_BRAIN_OLLAMA_EMBED_MODEL',
      defaultModel: 'nomic-embed-text',
      daemonName: 'Ollama',
    );

/// The substrate-only YAML for the retrieval conductor: the oMLX + Ollama
/// transports, the four retrieval roles `recall_hyde_v1` / `recall_semantic_v1`
/// dispatch (recall_planner, hypothesis_writer, query_term_writer,
/// category_selector) routed to oMLX, and the Ollama embedding both the corpus
/// seed and the HyDE answers embed through.
String _retrievalSubstrateYaml({
  required _LiveEndpoint omlx,
  required _LiveEndpoint ollama,
}) =>
    '''
substrate:
  providers:
    - id: omlx
      kind: openai
      baseUrl: ${omlx.baseUri}
      models:
        - ${omlx.model}
    - id: ollama
      kind: ollama
      baseUrl: ${ollama.baseUri}
      models:
        - ${ollama.model}
  roleRoutes:
    recall_planner:
      - providerId: omlx
        model: ${omlx.model}
    hypothesis_writer:
      - providerId: omlx
        model: ${omlx.model}
    query_term_writer:
      - providerId: omlx
        model: ${omlx.model}
    category_selector:
      - providerId: omlx
        model: ${omlx.model}
  embedding:
    providerId: ollama
    model: ${ollama.model}
    dims: 768
    normalize: true
''';

/// One labelled corpus document the suite seeds. Carries the node type, the
/// field values, and the text its embedding is computed from (the live Ollama
/// embed call — memory never embeds on the caller's behalf, so every persisted
/// node must arrive with its vector).
class _Doc {
  const _Doc({
    required this.typeName,
    required this.values,
    required this.embedText,
  });

  final String typeName;
  final Map<String, Object?> values;
  final String embedText;
}

void main() {
  // The real providers source their wire HTTP client from the `tom_core_kernel`
  // factory via the active `TomPlatformUtils`; a bare `dart test` runs the
  // fallback platform, whose `httpClient()` throws. Install the standalone
  // platform so the live HTTP path is exercised end-to-end (mirrors #34).
  setUpAll(() {
    TomPlatformUtils.setCurrentPlatform(standalonePlatformUtils);
  });

  final String? vecRoot = _findSqliteVecRoot();
  final SqliteVecBinaryResolver resolver = SqliteVecBinaryResolver();
  String? resolvedPath;
  if (vecRoot != null && resolver.isSupported) {
    final String path = resolver.resolve(vecRoot);
    if (File(path).existsSync()) resolvedPath = path;
  }
  final String? skipNoBinary = resolvedPath == null
      ? 'No packaged vec0 binary for this platform under '
          'tom_binaries/sqlite_vec (resolver.isSupported='
          '${resolver.isSupported}, vecRoot=$vecRoot).'
      : null;

  group('#35 LIVE end-to-end — the retrieval conductor (HyDE + semantic)', () {
    test(
        'HyDE + semantic seeds surface the targets naive recall misses, the '
        'fused context carries provenance, and the profile is dropped',
        () async {
      final omlx = _omlx();
      final ollama = _ollama();
      final omlxSkip = await omlx.unreachableReason();
      if (omlxSkip != null) return markTestSkipped(omlxSkip);
      final ollamaSkip = await ollama.unreachableReason();
      if (ollamaSkip != null) return markTestSkipped(ollamaSkip);

      // A unique on-disk memory root; dropped wholesale on teardown.
      final Directory memoryRoot =
          Directory.systemTemp.createTempSync('tom_brain_run_35_mem_');
      addTearDown(() {
        if (memoryRoot.existsSync()) memoryRoot.deleteSync(recursive: true);
      });

      final MemoryConfig baseConfig = MemoryConfig(
        root: memoryRoot.path,
        sqliteVec: SqliteVecConfig(binariesRoot: vecRoot!),
      );

      // ── Provision: create the throwaway profile, assert it materialised ──
      final SqliteTomBrainMemory provisioner = SqliteTomBrainMemory();
      await provisioner.open(baseConfig);
      expect(await provisioner.profiles.exists(_profileName), isFalse,
          reason: 'the throwaway profile must not pre-exist');
      await provisioner.profiles.createProfile(_profileName);
      expect(await provisioner.profiles.exists(_profileName), isTrue,
          reason: 'createProfile materialises the profile layout');
      await provisioner.close();

      // ── The real substrate (eleven-role registry; four retrieval roles
      //     routed to oMLX, Ollama embeddings) ──
      final SubstrateConfig substrateConfig = SubstrateConfigLoader.parse(
        _retrievalSubstrateYaml(omlx: omlx, ollama: ollama),
      );
      final InProcessTomBrainSubstrate substrate = buildSubstrate(
        substrateConfig,
        roleRegistry: bootstrapRoleRegistryWithRetrieval(),
      );
      await substrate.open(substrateConfig);

      // The prompt and the labelled corpus. The answer (`Conclusion`) is
      // phrased unlike the question — no "where" / "headquartered" overlap — so
      // it can only be surfaced by an answer-shaped (HyDE) embedding, never by
      // the question's own text. The two `Concept`s are what the semantic leg's
      // `category_selector` escalation surfaces by name / type. Two distractors
      // (an unrelated `Event` and `Claim`) make "naive returns nothing" a real
      // contrast rather than an empty store.
      const String prompt = 'Where is the French government headquartered?';
      const String hydeStatement =
          'Paris is the seat of the French Republic\'s executive and the home '
          'of its national legislature.';
      final List<_Doc> corpus = <_Doc>[
        const _Doc(
          typeName: 'Conclusion',
          values: <String, Object?>{
            'statement': hydeStatement,
            'rationale': 'The Élysée Palace, Hôtel Matignon, and the Palais '
                'Bourbon all stand in the capital.',
          },
          embedText: '$hydeStatement The Élysée Palace, Hôtel Matignon, and '
              'the Palais Bourbon all stand in the capital.',
        ),
        const _Doc(
          typeName: 'Concept',
          values: <String, Object?>{
            'name': 'Paris',
            'description': 'The capital city of France and its seat of '
                'national government.',
          },
          embedText: 'Paris — the capital city of France and its seat of '
              'national government.',
        ),
        const _Doc(
          typeName: 'Concept',
          values: <String, Object?>{
            'name': 'France',
            'description': 'A country in Western Europe; a unitary semi-'
                'presidential republic.',
          },
          embedText: 'France — a country in Western Europe; a unitary semi-'
              'presidential republic.',
        ),
        const _Doc(
          typeName: 'Event',
          values: <String, Object?>{
            'summary': 'A cook simmered fresh basil into a pot of tomato '
                'sauce for the evening pasta.',
            'payload': <String, Object?>{},
            'occurred_at': '2026-01-02T18:30:00Z',
          },
          embedText: 'A cook simmered fresh basil into a pot of tomato sauce '
              'for the evening pasta.',
        ),
        const _Doc(
          typeName: 'Claim',
          values: <String, Object?>{
            'statement':
                'Succulents tolerate low office light and infrequent watering.',
          },
          embedText:
              'Succulents tolerate low office light and infrequent watering.',
        ),
      ];

      // ── Seed + query, all inside the profile-bound handle ──
      final SqliteTomBrainMemory store = SqliteTomBrainMemory();
      await store.open(baseConfig.withProfile(_profileName));
      String? hydeTargetId;
      try {
        const Scope seedScope = Scope(producer: 'r35:retrieval_e2e:seed');
        for (var i = 0; i < corpus.length; i++) {
          final _Doc doc = corpus[i];
          final result = await substrate.embed(doc.embedText);
          final Vec vec = result.vec;
          final id = await store.persist(
            NodeDraft(
              typeName: doc.typeName,
              values: doc.values,
              embedding: vec,
            ),
            scope: Scope(
              producer: seedScope.producer,
              idempotencyKey: 'r35:doc:$i',
            ),
          );
          if (doc.typeName == 'Conclusion') hydeTargetId = id.value;
        }
        expect(hydeTargetId, isNotNull,
            reason: 'the HyDE-target Conclusion was seeded');

        // The engine over the full system resolver (the conductor + every
        // `recall_*` sub-procedure it dispatches), the profile store, and the
        // real substrate. `MemoryBridge` with a null agent is read-only —
        // retrieval never writes.
        final Directory scriptsDir = await _resolveProcedurePrototypeScripts();
        final ProcedureResolver system = await ProcedureResolver.fromStore(
          DiskProcedureStore(systemDir: scriptsDir),
        );
        final ProcedureEngine engine = ProcedureEngine(
          resolver: system,
          memory: store,
          memoryBridge: MemoryBridge(store, agentName: null),
          substrateBridge: SubstrateBridge(substrate),
        );

        // ── Naive: a single text-only `vector.prompt` seed → degraded → empty ──
        final naive = await _runConductor(
          engine,
          prompt,
          MemoryRetrievalConfig.defaults().withOnly(<String>['vector.prompt']),
        );
        expect(naive.status, TrailOutcomeStatus.accepted,
            reason: 'the conductor accepts even a fully-degraded run (PE-6)');
        expect(naive.nodeIds, isEmpty,
            reason: 'a null-embedding vector seed degrades to no candidates '
                'and every sub-procedure is gated off — naive misses the '
                'answer entirely');

        // ── HyDE + semantic: surfaces the Conclusion + a Concept ──
        final enriched = await _runConductor(
          engine,
          prompt,
          MemoryRetrievalConfig.defaults().withOnly(<String>[
            'vector.prompt',
            'vector.hypothetical_answers',
            'symbolic.type_filter_by_classify',
          ]),
        );
        expect(enriched.status, TrailOutcomeStatus.accepted);
        expect(enriched.nodeIds, isNotEmpty,
            reason: 'HyDE + semantic enrich the recall beyond the naive empty');

        // HyDE surfaces the answer-shaped Conclusion the question text alone
        // could never reach.
        expect(enriched.nodeIds, contains(hydeTargetId),
            reason: 'the HyDE answer embedding surfaces the Conclusion whose '
                'wording is unlike the question');

        // The semantic leg surfaces a Concept (by category_selector name /
        // node-type symbolic seed).
        expect(enriched.typeNames, contains('Concept'),
            reason: 'the semantic leg surfaces at least one Concept node');

        // The enriched recall is a strict superset of the naive one (which is
        // empty) — the migration never removes a hit, only adds (§ 23.4).
        expect(
          enriched.nodeIds.toSet().containsAll(naive.nodeIds.toSet()),
          isTrue,
          reason: 'enriched recall is a superset of naive recall',
        );

        // ── Provenance: index-aligned, non-empty seed sets, numeric scores ──
        expect(enriched.provenance, hasLength(enriched.nodes.length),
            reason: 'provenance is index-aligned with the fused node list');
        for (var i = 0; i < enriched.nodes.length; i++) {
          final node = enriched.nodes[i];
          final prov = enriched.provenance[i] as Map<Object?, Object?>;
          expect(prov['nodeId'], node['id'],
              reason: 'provenance[$i].nodeId matches nodes[$i].id');
          expect(prov['seedIndexes'], isA<List<Object?>>());
          expect((prov['seedIndexes'] as List<Object?>), isNotEmpty,
              reason: 'every fused node was contributed by at least one seed');
          expect(prov['fusedScore'], isA<num>());
        }
      } finally {
        await store.close();
        await substrate.close();
      }

      // ── Drop: the throwaway profile is gone (whole-store reset-to-zero) ──
      final SqliteTomBrainMemory dropper = SqliteTomBrainMemory();
      await dropper.open(baseConfig);
      try {
        expect(await dropper.profiles.exists(_profileName), isTrue,
            reason: 'the profile still exists before the drop');
        await dropper.profiles.dropProfile(_profileName);
        expect(await dropper.profiles.exists(_profileName), isFalse,
            reason: 'dropProfile removes the whole profile directory');
      } finally {
        await dropper.close();
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  }, skip: skipNoBinary);
}

/// One conductor run's decoded result: the run status plus the fused `recall`
/// map projected into the fields the assertions read.
class _ConductorResult {
  _ConductorResult({
    required this.status,
    required this.nodes,
    required this.provenance,
  });

  final TrailOutcomeStatus status;
  final List<Map<Object?, Object?>> nodes;
  final List<Object?> provenance;

  List<Object?> get nodeIds =>
      <Object?>[for (final n in nodes) n['id']];

  List<Object?> get typeNames =>
      <Object?>[for (final n in nodes) n['typeName']];
}

/// Invokes `retrieve_for_prompt_v1` over [engine] for [prompt] under [config]
/// (projected to the conductor's coarse surface) and decodes the fused recall.
Future<_ConductorResult> _runConductor(
  ProcedureEngine engine,
  String prompt,
  MemoryRetrievalConfig config,
) async {
  final outcome = await engine
      .invoke(ProcedureInvocation(
        procedureId: _conductorId,
        arguments: <String, Object?>{
          'text': prompt,
          'retrievalConfig': config.toConductorMap(),
        },
      ))
      .outcome;
  final recall = outcome.result?.outputs['recall'];
  final nodes = <Map<Object?, Object?>>[];
  List<Object?> provenance = const <Object?>[];
  if (recall is Map) {
    final rawNodes = recall['nodes'];
    if (rawNodes is List) {
      for (final n in rawNodes) {
        if (n is Map<Object?, Object?>) nodes.add(n);
      }
    }
    final rawProv = recall['provenance'];
    if (rawProv is List) provenance = rawProv;
  }
  return _ConductorResult(
    status: outcome.status,
    nodes: nodes,
    provenance: provenance,
  );
}

/// Resolves the procedure prototype's shipped `scripts/system` directory (where
/// the conductor + `recall_*` strategies live) via its package URI, independent
/// of the test's working directory. Mirrors #34's resolution.
Future<Directory> _resolveProcedurePrototypeScripts() async {
  final Uri? libUri = await Isolate.resolvePackageUri(
    Uri.parse(
      'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart',
    ),
  );
  if (libUri == null) {
    throw StateError(
      'cannot resolve the tom_brain_procedure_prototype package URI — '
      'is it on the package config?',
    );
  }
  // libUri → <package-root>/lib/...; the scripts live at
  // <package-root>/scripts/system.
  return Directory.fromUri(libUri.resolve('../scripts/system'));
}
