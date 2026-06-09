// #34 — LIVE end-to-end, a cognitive agent (the Extractor dream pass).
//
// Plan-2 step #34 (verbatim, `prototype_implementation_plan_2.md`):
//
//   "LIVE end-to-end — a cognitive agent. Manually trigger `dream_extract_v1`
//    (item 23) over the trail produced by item 32 against the real store + real
//    substrate LLM (oMLX); assert it writes Claims/edges within scope/budget.
//    Verify: a real dream pass mutates the real memory and is inspectable via
//    MCP."
//
// ── What this suite proves (and how it differs from #32) ─────────────
//
// #32 drives the foreground answer chain live (prompt → `answer_with_memory_v1`
// → oMLX → answer → memory). #34 drives the *background dreaming* chain live:
// it first stands the real process up and POSTs one chat completion to lay down
// the exact "item-32 trail" (a real on-disk `Event`), then re-opens that store
// in-host and triggers the Extractor cognitive agent through the **same item-23
// path the dispatcher uses** — `FreeTimeScheduler.triggerMaintenance` over a
// `ProcedureEngine` bound to the real store + the **real oMLX substrate**.
//
//   prompt → live answer chain → real on-disk `Event`  (Phase 1, item 32)
//   re-open store in-host → register the Extractor agent → engine over the
//     real store + live oMLX → `dream_extract_v1`: recall the Event, extract a
//     Claim with **live oMLX**, embed it with **live Ollama**, persist it under
//     the agent's `node:Claim` write scope → MCP-inspect the new Claim
//                                                       (Phase 2, item 34)
//
// The substrate here is the *real* `InProcessTomBrainSubstrate` the run package
// manufactures (`buildSubstrate`), routed so the `extractor` role hits oMLX. So
// this suite only passes when both daemons are live; off-host it skips (a
// per-test reachability probe) and on a platform with no packaged vec0 the whole
// group skips (the on-disk store loads the extension at `open`).
//
// ── Why a phase-2 substrate config that routes `extractor` ───────────
//
// `dream_extract_v1` issues `sub.llm(..., role: 'extractor')`, but the bootstrap
// role registry (`bootstrapRoleRegistry`) defines only the five prototype roles
// — there is no `extractor`. Against the real substrate `open()` validates that
// every *routed* role is registered, and `complete()` resolves the role
// template, so the agent cannot run without an `extractor` template + route.
// The fix is a composition-root concern, not a production-bootstrap change: this
// suite injects a registry = the bootstrap five **plus** an `extractor` template
// through the documented `buildSubstrate(config, roleRegistry:)` seam, and routes
// `extractor` → oMLX in a substrate config used *only* for the dream pass. The
// phase-1 process keeps the unmodified bootstrap registry (routing `extractor`
// in phase 1 would fail its boot-time role-registry validation). The two phases
// therefore use two distinct substrate configs by design.
//
// ── Why MCP inspection asserts on the returned ids, not a recall ─────
//
// The Claim statement is whatever live oMLX distils — non-deterministic text.
// So the assertion reads the ids the dream pass *returned* (`claimIds`) and
// `memory.get`s them through the MCP server: a deterministic proof the new Claim
// nodes are real, persisted, and inspectable over the brain's external surface,
// independent of the live wording.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dart_mcp/client.dart' as mcp_client;
import 'package:dart_mcp/server.dart' as mcp_server;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tom_basics/tom_basics.dart' show TomPlatformUtils;
import 'package:tom_brain_access/tom_brain_access.dart'
    show serveWithShelfIo;
import 'package:tom_brain_memory/tom_brain_memory.dart'
    show
        AgentScopeViolation,
        SqliteTomBrainMemory,
        SqliteVecBinaryResolver,
        TomBrainMemory,
        TomBrainMemoryMcpServer;
import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show
        DiskProcedureStore,
        FreeTimeScheduler,
        LoadedProcedure,
        MemoryBridge,
        ProcedureEngine,
        ProcedureOutcome,
        ProcedureResolver,
        RunCoordinator,
        SubstrateBridge;
import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show AgentRegistration, TrailOutcomeStatus, WriteBudget;
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show
        AllowedAction,
        InProcessTomBrainSubstrate,
        RoleBudgetDefaults,
        RoleRegistry,
        RoleTemplate,
        SubstrateConfig,
        SubstrateConfigLoader,
        bootstrapRoleRegistry;
import 'package:tom_core_server/tom_core_server.dart'
    show standalonePlatformUtils;

/// The bearer token the live access config binds; the phase-1 request
/// authenticates with it.
const String _bearerToken = 'run-token';

/// The agent / procedure id the Extractor dream pass runs under (the dream
/// procedures' id equals their agent name, memory § 9).
const String _extractorId = 'dream_extract_v1';

/// Locates `<workspace>/tom_binaries/sqlite_vec`. Mirrors the #32 suite.
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
/// a separate, awaited TCP probe done inside the test body. Mirrors #32.
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

/// Builds the whole-process YAML for the phase-1 live run: the real oMLX +
/// Ollama substrate (routing the user-facing role to oMLX), the on-disk memory
/// rooted at [memoryRoot] (vec0 from [binariesRoot]), and a permissive
/// single-bearer access config. Mirrors #32's run YAML.
String _liveRunYaml({
  required _LiveEndpoint omlx,
  required _LiveEndpoint ollama,
  required String memoryRoot,
  required String binariesRoot,
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
    assistant_to_user:
      - providerId: omlx
        model: ${omlx.model}
  embedding:
    providerId: ollama
    model: ${ollama.model}
    dims: 768
    normalize: true
memory:
  root: "$memoryRoot"
  sqliteVec:
    binariesRoot: "$binariesRoot"
access:
  openai:
    port: 8080
    basePath: /v1
  users:
    - id: owner
      displayName: Owner
      openaiBearerTokens:
        - $_bearerToken
  rateLimit:
    capacity: 1000000
    refillTokens: 1000000
    refillPeriodSeconds: 1
  quota:
    dailyCap: 1000000
''';

/// Builds the phase-2 substrate-only YAML: the same oMLX + Ollama transports,
/// but routing the **`extractor`** role to oMLX (the dream pass's only routed
/// role) plus the Ollama embedding the Claim's statement is embedded through.
String _extractorSubstrateYaml({
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
    extractor:
      - providerId: omlx
        model: ${omlx.model}
  embedding:
    providerId: ollama
    model: ${ollama.model}
    dims: 768
    normalize: true
''';

/// The `extractor` role template the dream pass dispatches under. Absent from
/// the bootstrap roster, so it is spliced in for the dream pass only (see the
/// file header). Carries the three actions `dream_extract_v1` needs:
/// `llm_call` (extraction), `memory_read` (recall), `memory_write` (persist).
RoleTemplate _extractorRole() => RoleTemplate(
      id: 'extractor',
      personaText: 'I am the extractor. I read one recorded event and distil '
          'it into a single atomic, self-contained factual claim.',
      objective: 'Read the recorded event summary and produce exactly one '
          'atomic, self-contained factual claim it supports. Emit only the '
          'claim sentence — no preamble, no enumeration, no commentary.',
      allowedActions: const <AllowedAction>{
        AllowedAction.llmCall,
        AllowedAction.memoryRead,
        AllowedAction.memoryWrite,
      },
      budgetDefaults: RoleBudgetDefaults.empty,
    );

/// The role registry the dream-pass substrate validates against: the bootstrap
/// five plus the [_extractorRole]. Built fresh per call (the bootstrap factory
/// returns a fresh registry each time).
RoleRegistry _registryWithExtractor() => RoleRegistry(
      templates: <RoleTemplate>[
        ...bootstrapRoleRegistry().templates,
        _extractorRole(),
      ],
    );

/// Registers the Extractor agent with the given write [scopes]. The happy path
/// passes `{node:Claim}` (its real lane); the scope-enforcement case passes a
/// deliberately wrong scope so the Claim write is refused. The wide
/// [WriteBudget] only has to be large enough not to interfere — the run is
/// bounded by `dream_extract_v1`'s own header budget.
AgentRegistration _extractorAgent(Set<String> scopes) => AgentRegistration(
      agentName: _extractorId,
      procedureId: _extractorId,
      defaultBudget: WriteBudget(
        maxNodes: 1000,
        maxEdges: 1000,
        maxStackEntries: 1000,
      ),
      readScopes: const <String>{AgentRegistration.globalWildcard},
      writeScopes: scopes,
    );

/// A `chat/completions` request body for [prompt].
Map<String, Object?> _chatBody(String prompt) => <String, Object?>{
      'model': 'tom-assistant',
      'messages': <Object?>[
        <String, Object?>{'role': 'user', 'content': prompt},
      ],
      'stream': false,
    };

/// Issues a JSON `POST` and returns status + decoded JSON body.
Future<({int statusCode, Object? body})> _postJson(
  int port,
  String path,
  Object body, {
  required String token,
}) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request =
        await client.postUrl(Uri.parse('http://127.0.0.1:$port$path'));
    request.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    request.add(utf8.encode(jsonEncode(body)));
    final HttpClientResponse response = await request.close();
    final String text = await response.transform(utf8.decoder).join();
    return (
      statusCode: response.statusCode,
      body: text.isEmpty ? null : jsonDecode(text),
    );
  } finally {
    client.close(force: true);
  }
}

void main() {
  // The real providers source their wire HTTP client from the `tom_core_kernel`
  // factory via the active `TomPlatformUtils`; a bare `dart test` runs the
  // fallback platform, whose `httpClient()` throws. Install the standalone
  // platform so the live HTTP path is exercised end-to-end (mirrors #32).
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

  group('#34 LIVE end-to-end — a cognitive agent (Extractor dream pass)', () {
    /// Phase 1: stands a fresh live cognition up over a unique on-disk memory
    /// root and POSTs one non-stream chat completion, laying down the exact
    /// item-32 trail (a real on-disk `Event` whose summary is [prompt]). Stops
    /// the process (disposing the memory isolate + closing the DB handles) so
    /// the same on-disk store can be re-opened in-host for the dream pass.
    /// Returns the parsed config (its `memory` section re-opens the store).
    Future<BrainRunConfig> layDownItem32Trail({
      required _LiveEndpoint omlx,
      required _LiveEndpoint ollama,
      required String prompt,
    }) async {
      final Directory memoryRoot =
          Directory.systemTemp.createTempSync('tom_brain_run_34_mem_');
      addTearDown(() {
        if (memoryRoot.existsSync()) memoryRoot.deleteSync(recursive: true);
      });

      final BrainRunConfig config = BrainRunConfigLoader.parse(
        _liveRunYaml(
          omlx: omlx,
          ollama: ollama,
          memoryRoot: memoryRoot.path,
          binariesRoot: vecRoot!,
        ),
      );
      final BrainProcess process = await standUpBrainProcessFromConfig(
        config,
        // Bind an OS-assigned ephemeral port; read the real one back.
        serve: (handler, _) => serveWithShelfIo(handler, 0),
      );
      try {
        final result = await _postJson(
          process.port,
          '/v1/chat/completions',
          _chatBody(prompt),
          token: _bearerToken,
        );
        expect(result.statusCode, 200);
        final body = result.body as Map<String, Object?>;
        final choices = body['choices'] as List<Object?>;
        final message = (choices.single as Map<String, Object?>)['message']
            as Map<String, Object?>;
        final answer = message['content'] as String;
        expect(answer.trim(), isNotEmpty,
            reason: 'live oMLX must return a non-empty completion (the trail '
                'is only laid down once the answer chain ran)');
      } finally {
        // Stop first: dispose the memory isolate + close the DB handles so the
        // on-disk store can be re-opened in-host for the dream pass.
        await process.stop();
      }
      return config;
    }

    /// Phase 2: re-opens the on-disk store [config] in-host, registers the
    /// Extractor agent with [writeScopes], builds the real oMLX substrate (with
    /// the `extractor` role spliced in and routed to oMLX), and triggers
    /// `dream_extract_v1` through the item-23 path
    /// (`FreeTimeScheduler.triggerMaintenance`) over [source]. Hands the open
    /// store and the run outcome to [body], then tears the substrate + store
    /// down.
    Future<void> dreamOverTrail({
      required BrainRunConfig config,
      required _LiveEndpoint omlx,
      required _LiveEndpoint ollama,
      required String source,
      required Set<String> writeScopes,
      required Future<void> Function(
        SqliteTomBrainMemory store,
        ProcedureOutcome outcome,
      ) body,
    }) async {
      final SqliteTomBrainMemory store = SqliteTomBrainMemory();
      await store.open(config.memory);
      // The store's AgentRegistry confines every write the agent body issues to
      // these scopes (memory § 9); a write outside them is refused before any
      // row is written.
      store.registerAgent(_extractorAgent(writeScopes));

      final SubstrateConfig substrateConfig = SubstrateConfigLoader.parse(
        _extractorSubstrateYaml(omlx: omlx, ollama: ollama),
      );
      // Inject the bootstrap-five + `extractor` registry through the documented
      // builder seam, then `open` so the routed `extractor` role validates.
      final InProcessTomBrainSubstrate substrate = buildSubstrate(
        substrateConfig,
        roleRegistry: _registryWithExtractor(),
      );
      await substrate.open(substrateConfig);

      try {
        final Directory scriptsDir = await _resolveProcedurePrototypeScripts();
        final ProcedureResolver system = await ProcedureResolver.fromStore(
          DiskProcedureStore(systemDir: scriptsDir),
        );
        final ProcedureEngine engine = ProcedureEngine(
          resolver: ProcedureResolver(
            <LoadedProcedure>[system.resolve(_extractorId)],
          ),
          memory: store,
          memoryBridge: MemoryBridge(store, agentName: _extractorId),
          substrateBridge: SubstrateBridge(substrate),
        );
        final FreeTimeScheduler scheduler = FreeTimeScheduler(
          coordinator: RunCoordinator(),
          memory: store,
          // Only `triggerMaintenance` is exercised; the stack-harvest tick path
          // (and so this factory) is never reached.
          workFactory: (_) => null,
          engine: engine,
        );

        // The faithful item-23 trigger: one engine-backed `dream_extract_v1`
        // run on the background slot, against the real store + live oMLX.
        final ProcedureOutcome outcome = await scheduler.triggerMaintenance(
          _extractorId,
          arguments: <String, Object?>{'source': source},
        );
        await body(store, outcome);
      } finally {
        await substrate.close();
        await store.close();
      }
    }

    test(
        'a real dream pass extracts a Claim from the item-32 trail within '
        'scope/budget and the Claim is inspectable via MCP', () async {
      final omlx = _omlx();
      final ollama = _ollama();
      final omlxSkip = await omlx.unreachableReason();
      if (omlxSkip != null) return markTestSkipped(omlxSkip);
      final ollamaSkip = await ollama.unreachableReason();
      if (ollamaSkip != null) return markTestSkipped(ollamaSkip);

      // A salient, distinctive prompt: the run persists it as the Event summary,
      // and the dream pass recalls the Event by BM25 over this same text.
      const String prompt = 'In one short sentence, what is the capital of '
          'France?';

      final BrainRunConfig config = await layDownItem32Trail(
        omlx: omlx,
        ollama: ollama,
        prompt: prompt,
      );

      await dreamOverTrail(
        config: config,
        omlx: omlx,
        ollama: ollama,
        // Recall the seeded Event by its own indexed summary text.
        source: prompt,
        writeScopes: <String>{AgentRegistration.nodeScope('Claim')},
        body: (store, outcome) async {
          // Accepted ⇒ the run stayed within `dream_extract_v1`'s header budget
          // (a breach would close it `budgetExceeded`, not `accepted`) — the
          // "within budget" half of #34.
          expect(outcome.status, TrailOutcomeStatus.accepted);

          // The body returns the ids it persisted as `claimIds`.
          final claimIds = outcome.result!.output<List<Object?>>('claimIds');
          expect(claimIds, isNotNull);
          expect(claimIds, isNotEmpty,
              reason: 'the live extractor distilled at least one Claim from '
                  'the recalled Event');

          // The Verify (real memory mutated): Claim rows exist in the real
          // store, one per recalled Event, all under the agent's `node:Claim`
          // write scope — the "within scope" half of #34.
          final stats = await store.stats();
          expect(stats.nodeCountByType['Claim'] ?? 0, greaterThan(0));
          expect(stats.nodeCountByType['Claim'], claimIds!.length);

          // The Verify (inspectable via MCP): the new Claim ids resolve to real
          // Claim nodes over the brain's external memory-inspection surface.
          final ids = claimIds.cast<String>();
          await _inspectViaMcp(store, (mcp) async {
            final fetched = await mcp.get(ids: ids);
            expect(fetched, hasLength(ids.length));
            expect(
              fetched.every((n) => n['typeName'] == 'Claim'),
              isTrue,
              reason: 'every returned id is a persisted Claim node',
            );
          });
        },
      );
    }, timeout: const Timeout(Duration(minutes: 5)));

    test(
        'an out-of-scope Extractor write is refused with AgentScopeViolation '
        'and mutates no Claim', () async {
      final omlx = _omlx();
      final ollama = _ollama();
      final omlxSkip = await omlx.unreachableReason();
      if (omlxSkip != null) return markTestSkipped(omlxSkip);
      final ollamaSkip = await ollama.unreachableReason();
      if (ollamaSkip != null) return markTestSkipped(ollamaSkip);

      const String prompt = 'In one short sentence, name a primary colour.';

      final BrainRunConfig config = await layDownItem32Trail(
        omlx: omlx,
        ollama: ollama,
        prompt: prompt,
      );

      await dreamOverTrail(
        config: config,
        omlx: omlx,
        ollama: ollama,
        source: prompt,
        // The WRONG write scope (Concept, not Claim): the first
        // `mem.persist('Claim', …)` is rejected by the store's AgentRegistry
        // before any row is written — the scope-enforcement half of #34.
        writeScopes: <String>{AgentRegistration.nodeScope('Concept')},
        body: (store, outcome) async {
          // The refusal surfaces as a run error carrying the typed violation.
          expect(outcome.status, isNot(TrailOutcomeStatus.accepted));
          expect(outcome.error, isA<AgentScopeViolation>());

          // A scope-denied write must not create a row.
          final stats = await store.stats();
          expect(stats.nodeCountByType['Claim'] ?? 0, equals(0),
              reason: 'the Claim write was refused, so no Claim row exists');
        },
      );
    }, timeout: const Timeout(Duration(minutes: 5)));
  }, skip: skipNoBinary);
}

/// Resolves the procedure prototype's shipped `scripts/system` directory (where
/// `dream_extract_v1` lives) via its package URI, independent of the test's
/// working directory. Mirrors `provision_brain.dart`'s resolution.
Future<Directory> _resolveProcedurePrototypeScripts() async {
  final Uri? libUri = await Isolate.resolvePackageUri(
    Uri.parse(
      'package:tom_brain_procedure/tom_brain_procedure.dart',
    ),
  );
  if (libUri == null) {
    throw StateError(
      'cannot resolve the tom_brain_procedure package URI — '
      'is it on the package config?',
    );
  }
  // libUri → <package-root>/lib/...; the scripts live at
  // <package-root>/scripts/system.
  return Directory.fromUri(libUri.resolve('../scripts/system'));
}

/// Stands the memory MCP server up over [memory] (anonymous mode), runs the
/// handshake, hands an [_McpInspector] to [body], then tears the connection
/// down. Mirrors #32's in-process MCP harness: eager construction so the server
/// is listening before the client starts `initialize`.
Future<void> _inspectViaMcp(
  TomBrainMemory memory,
  Future<void> Function(_McpInspector mcp) body,
) async {
  final clientController = StreamController<String>();
  final serverController = StreamController<String>();

  final clientChannel = StreamChannel<String>.withCloseGuarantee(
    serverController.stream,
    clientController.sink,
  );
  final serverChannel = StreamChannel<String>.withCloseGuarantee(
    clientController.stream,
    serverController.sink,
  );

  final client = _RunMcpClient();
  final server = TomBrainMemoryMcpServer(serverChannel, memory: memory);
  final connection = client.connectServer(clientChannel);

  final init = await connection.initialize(
    mcp_server.InitializeRequest(
      protocolVersion: mcp_server.ProtocolVersion.latestSupported,
      capabilities: client.capabilities,
      clientInfo: client.implementation,
    ),
  );
  if (init.protocolVersion?.isSupported == true) {
    connection.notifyInitialized(mcp_server.InitializedNotification());
    await server.initialized;
  }

  try {
    await body(_McpInspector(connection));
  } finally {
    await client.shutdown();
    await server.shutdown();
  }
}

/// A thin read-only view over an MCP [mcp_client.ServerConnection] that calls
/// the memory MCP tools and decodes their JSON payloads.
class _McpInspector {
  final mcp_client.ServerConnection _connection;

  _McpInspector(this._connection);

  /// `memory.get` → the fetched node maps.
  Future<List<Map<String, Object?>>> get({required List<String> ids}) async {
    final payload = await _call('memory.get', <String, Object?>{'ids': ids});
    return _maps(payload['nodes']);
  }

  Future<Map<String, Object?>> _call(
    String name,
    Map<String, Object?> arguments,
  ) async {
    final result = await _connection.callTool(
      mcp_server.CallToolRequest(name: name, arguments: arguments),
    );
    expect(result.isError, isNot(isTrue),
        reason: 'MCP tool $name returned an error');
    final text = (result.content.first as mcp_server.TextContent).text;
    return jsonDecode(text) as Map<String, Object?>;
  }

  List<Map<String, Object?>> _maps(Object? raw) => <Map<String, Object?>>[
        for (final item in (raw as List)) item as Map<String, Object?>,
      ];
}

base class _RunMcpClient extends mcp_client.MCPClient {
  _RunMcpClient()
      : super(
          mcp_client.Implementation(name: 'r34-run-client', version: '0.0.1'),
        );
}
