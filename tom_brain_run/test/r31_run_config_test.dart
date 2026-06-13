// #31 — the whole-process configuration.
//
// Plan-2 step #31 (verbatim, `prototype_implementation_plan_2.md`):
//
//   "Whole-process configuration. A single YAML config wiring oMLX endpoint +
//    model, Ollama embed endpoint + model, memory directory, the four channel
//    ports/tokens (Telegram optional), and role routing. Read via the plain-map
//    loader; if the process ever rewrites it, write via the `yaml_edit` AST
//    writer (item 6). Test: config loads to a fully-populated runtime config; a
//    representative invalid config fails with a located error. Verify: the
//    process starts from the config file unmodified."
//
// ── How #31 realises the single config ───────────────────────────────
//
// The whole-process YAML has five sibling sections — `substrate:`, `memory:`,
// `engine:`, `dispatcher:`, `access:` — the same five the access package's
// loader tolerates. `BrainRunConfigLoader` parses the three the run assembly
// consumes by delegating each to its *owning* loader (the design the access
// config sub-barrel documents): `substrate:` → `SubstrateConfigLoader`,
// `memory:` → `MemoryConfigLoader`, `access:` → `AccessConfigLoader`. Each
// section loader owns its schema, its `${env:NAME}` expansion, and its located
// (dotted-key-path) errors — so the run loader needs no error plumbing of its
// own.
//
// `buildSubstrate` is the genuinely-missing `SubstrateConfig →
// InProcessTomBrainSubstrate` manufacturer: the substrate facade is a wirer,
// not a manufacturer, so the run package (a composition root) builds the live
// providers/router/embedding from the parsed config.
//
// ── What this suite proves ───────────────────────────────────────────
//
//   Group A — BrainRunConfigLoader (pure): a fully-populated whole-process
//   YAML loads to a `BrainRunConfig` whose three sub-configs are each fully
//   populated; representative invalid configs each fail with the owning
//   loader's located error.
//
//   Group B — buildSubstrate (pure): the manufacturer turns the real
//   deployment substrate config into a live facade whose routed roles validate
//   against the bootstrap registry, and refuses the config shapes it cannot
//   manufacture (stub/anthropic kinds, secretRef auth, a non-Ollama embedding
//   provider) with located errors. Pure construction — no provider opens a
//   socket until a chat/embedding call runs, which this group never triggers.
//
//   Group C — Verify (vec0 skip-gated): the process starts from the config
//   *file* — `loadFromFile` → `standUpBrainProcessFromConfig` — binds a real
//   port, answers `/healthz` + `/v1/models`, and the config file bytes are
//   unchanged after boot (the loader reads; it never rewrites).
//
// ── Why no live oMLX / Ollama is needed ──────────────────────────────
//
// Standing the process up and hitting `/healthz` + `/v1/models` never issues a
// chat completion or an embedding call, so the oMLX / Ollama transports are
// constructed but never dialed (same rationale as the #30 suite). Group C's
// only precondition is the packaged `vec0` binary the real on-disk memory loads
// at `open`; absent it, Group C is *skipped*, not failed.

import 'dart:convert';
import 'dart:io';

import 'package:tom_basics/tom_basics.dart' show TomPlatformUtils;
import 'package:tom_brain_access/tom_brain_access.dart'
    show AccessConfigException, serveWithShelfIo;
import 'package:tom_brain_memory/tom_brain_memory.dart'
    show MemoryConfigException, SqliteVecBinaryResolver;
import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show
        DefaultWebFetch,
        DefaultWebSearch,
        OllamaLlmProvider,
        OpenAiPassthroughProvider,
        SubstrateConfig,
        SubstrateConfigException,
        SubstrateConfigLoader,
        WebFetchConfig,
        WebSearchConfig,
        WebSearchProviderConfig;
import 'package:tom_core_server/tom_core_server.dart'
    show standalonePlatformUtils;
import 'package:tom_vscode_scripting_api/tom_vscode_scripting_api.dart'
    show PermissionMode;
import 'package:test/test.dart';

/// Locates `<workspace>/tom_binaries/sqlite_vec`. Mirrors the #30 suite.
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

/// The `substrate:` section in the prototype's real deployment shape: oMLX
/// (OpenAI-compatible LLM) for the two routed roles, Ollama for embeddings.
const String _substrateSection = '''
substrate:
  providers:
    - id: omlx
      kind: openai
      baseUrl: http://10.8.0.7:8000/v1/
      models:
        - gemma-4-26b-a4b-it-4bit
    - id: ollama
      kind: ollama
      baseUrl: http://10.8.0.9:11434
      models:
        - nomic-embed-text
  roleRoutes:
    analyser:
      - providerId: omlx
        model: gemma-4-26b-a4b-it-4bit
    assistant_to_user:
      - providerId: omlx
        model: gemma-4-26b-a4b-it-4bit
  embedding:
    providerId: ollama
    model: nomic-embed-text
    dims: 768
    normalize: true''';

/// The `access:` section: one OpenAI port, one bearer-bound user, the required
/// rate-limit / quota blocks. (Telegram omitted — optional per the plan.)
const String _accessSection = '''
access:
  openai:
    port: 8080
    basePath: /v1
  users:
    - id: owner
      displayName: Owner
      openaiBearerTokens:
        - run-token
  rateLimit:
    capacity: 1000000
    refillTokens: 1000000
    refillPeriodSeconds: 1
  quota:
    dailyCap: 1000000''';

/// Builds a whole-process YAML doc with a `memory:` section pointed at
/// [memoryRoot] + [binariesRoot] (the packaged vec0 root).
String _runYaml({required String memoryRoot, required String binariesRoot}) =>
    '$_substrateSection\n'
    'memory:\n'
    '  root: "$memoryRoot"\n'
    '  sqliteVec:\n'
    '    binariesRoot: "$binariesRoot"\n'
    '$_accessSection\n';

/// Issues a `GET` against a bound process and returns the status + decoded body.
Future<({int statusCode, Object? body})> _get(int port, String path) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request =
        await client.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
    final HttpClientResponse response = await request.close();
    final String text = await response.transform(utf8.decoder).join();
    final Object? body = text.isEmpty ? null : jsonDecode(text);
    return (statusCode: response.statusCode, body: body);
  } finally {
    client.close(force: true);
  }
}

void main() {
  // The real providers `buildSubstrate` manufactures source their default wire
  // HTTP client from the `tom_core_kernel` factory via the active
  // `TomPlatformUtils`; a bare `dart test` process runs the fallback platform,
  // whose `httpClient()` throws `UnimplementedError`. The production entrypoint
  // installs the standalone platform at startup — the test does the same so the
  // manufacturer's construction path (and the stood-up process) work. Off-host
  // Group C still skips before any HTTP call, so this init is harmless there.
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

  group('#31 BrainRunConfigLoader.parse — whole-process config', () {
    test('loads a fully-populated config to a BrainRunConfig (all three '
        'sub-configs populated)', () {
      final BrainRunConfig config = BrainRunConfigLoader.parse(
        _runYaml(
          memoryRoot: '/var/lib/tom_brain/memory',
          binariesRoot: '/opt/tom_binaries/sqlite_vec',
        ),
      );

      // substrate: providers, routing, embedding all read from the section.
      expect(config.substrate.providers.map((p) => p.id),
          containsAll(<String>['omlx', 'ollama']));
      expect(config.substrate.roleRoutes.keys,
          containsAll(<String>['analyser', 'assistant_to_user']));
      expect(config.substrate.roleRoutes['assistant_to_user']!.first.providerId,
          'omlx');
      expect(config.substrate.embedding.providerId, 'ollama');
      expect(config.substrate.embedding.model, 'nomic-embed-text');
      expect(config.substrate.embedding.dims, 768);

      // memory: root + sqlite-vec binary root read from the section.
      expect(config.memory.root, '/var/lib/tom_brain/memory');
      expect(config.memory.sqliteVec.binariesRoot, '/opt/tom_binaries/sqlite_vec');

      // access: the OpenAI port + the declared bearer-bound user.
      expect(config.access.openAiPort, 8080);
      expect(config.access.openAiBasePath, '/v1');
      expect(config.access.users.map((u) => u.id), contains('owner'));
      expect(config.access.users.first.openAiBearerTokens, contains('run-token'));
    });

    test('an mcpServers section parses into config.mcpServers; its absence '
        'yields an empty registry', () {
      // With the section: the two external servers parse onto the run config,
      // in declaration order, with their transports and descriptions.
      final String withMcp = '$_substrateSection\n'
          'memory:\n'
          '  root: /tmp/x\n'
          '  sqliteVec:\n'
          '    binariesRoot: /opt/vec\n'
          'mcpServers:\n'
          '  - id: files\n'
          '    transport: stdio\n'
          '    description: local filesystem tools\n'
          '    command: mcp-files\n'
          '  - id: weather\n'
          '    transport: http\n'
          '    url: https://example.test/mcp\n'
          '$_accessSection\n';

      final BrainRunConfig config = BrainRunConfigLoader.parse(withMcp);

      expect(config.mcpServers.servers.map((s) => s.id),
          <String>['files', 'weather']);
      final files = config.mcpServers.byId('files')!;
      expect(files.transport.name, 'stdio');
      expect(files.description, 'local filesystem tools');
      expect(files.command, 'mcp-files');
      expect(config.mcpServers.byId('weather')!.url, 'https://example.test/mcp');

      // Without the section: the registry is empty, never null.
      final String withoutMcp = '$_substrateSection\n'
          'memory:\n'
          '  root: /tmp/x\n'
          '  sqliteVec:\n'
          '    binariesRoot: /opt/vec\n'
          '$_accessSection\n';
      expect(BrainRunConfigLoader.parse(withoutMcp).mcpServers.servers, isEmpty);
    });

    test('a substrate section that routes to an unknown provider fails with a '
        'located SubstrateConfigException', () {
      // analyser routes to "ghost", which is not in providers — a substrate
      // cross-section invariant. The owning loader locates the offending ref.
      const String badSubstrate = '''
substrate:
  providers:
    - id: omlx
      kind: openai
      baseUrl: http://10.8.0.7:8000/v1/
      models:
        - m
  roleRoutes:
    analyser:
      - providerId: ghost
        model: m
  embedding:
    providerId: omlx
    model: m
    dims: 768''';
      final String doc = '$badSubstrate\n'
          'memory:\n'
          '  root: /tmp/x\n'
          '  sqliteVec:\n'
          '    binariesRoot: /opt/vec\n'
          '$_accessSection\n';

      expect(
        () => BrainRunConfigLoader.parse(doc),
        throwsA(isA<SubstrateConfigException>()
            .having((e) => e.message, 'message', contains('ghost'))),
      );
    });

    test('an unknown top-level section fails with a located '
        'AccessConfigException', () {
      // The access loader rejects any section outside the five-section set,
      // naming the offending key — a located whole-document error.
      final String doc = '$_substrateSection\n'
          'memory:\n'
          '  root: /tmp/x\n'
          '  sqliteVec:\n'
          '    binariesRoot: /opt/vec\n'
          '$_accessSection\n'
          'bogus:\n'
          '  nope: true\n';

      expect(
        () => BrainRunConfigLoader.parse(doc),
        throwsA(isA<AccessConfigException>()
            .having((e) => e.toString(), 'toString', contains('bogus'))),
      );
    });

    test('a missing memory section fails with a located MemoryConfigException',
        () {
      final String doc = '$_substrateSection\n$_accessSection\n';

      expect(
        () => BrainRunConfigLoader.parse(doc),
        throwsA(isA<MemoryConfigException>()
            .having((e) => e.toString(), 'toString', contains('memory'))),
      );
    });

    test('loadFromFile rejects a missing path with a BrainRunConfigException',
        () {
      expect(
        () => BrainRunConfigLoader.loadFromFile(
            '/no/such/run/config/${DateTime.now().microsecondsSinceEpoch}.yaml'),
        throwsA(isA<BrainRunConfigException>()),
      );
    });
  });

  group('#31 buildSubstrate — SubstrateConfig → live facade', () {
    test('manufactures a facade whose routed roles validate against the '
        'bootstrap registry', () async {
      final SubstrateConfig cfg =
          SubstrateConfigLoader.parse('$_substrateSection\n');
      final substrate = buildSubstrate(cfg);

      // The two real transports were manufactured, keyed by their config ids.
      expect(substrate.providers['omlx'], isA<OpenAiPassthroughProvider>());
      expect(substrate.providers['ollama'], isA<OllamaLlmProvider>());

      // open() runs the registry cross-validation the boot relies on — the
      // routed roles (analyser, assistant_to_user) are bootstrap roles, so it
      // completes without throwing.
      await substrate.open(cfg);
      await substrate.close();
    });

    test('a config routing the Extension-H retrieval roles validates — the run '
        'builder registers them by default', () async {
      // Regression for the recall-degradation bug (PE-6): the run builder used
      // to default to `bootstrapRoleRegistry()` (the five prototype roles only),
      // so any config that routed a retrieval role — `recall_planner`,
      // `hypothesis_writer`, … — failed `open()`'s cross-validation because the
      // routed role was not registered. The conductor then silently degraded its
      // LLM recall legs to the two non-LLM seeds. The builder now defaults to
      // `bootstrapRoleRegistryWithRetrievalProcedureAndCreation()`, so the six
      // retrieval roles (plus the three Todo-7 procedure roles and the three
      // Todo-9 creation roles) are registered live and a config routing them
      // validates.
      const String retrievalSubstrate = '''
substrate:
  providers:
    - id: omlx
      kind: openai
      baseUrl: http://10.8.0.7:8000/v1/
      models:
        - gemma-4-26b-a4b-it-4bit
    - id: ollama
      kind: ollama
      baseUrl: http://10.8.0.9:11434
      models:
        - nomic-embed-text
  roleRoutes:
    assistant_to_user:
      - providerId: omlx
        model: gemma-4-26b-a4b-it-4bit
    recall_planner:
      - providerId: omlx
        model: gemma-4-26b-a4b-it-4bit
    hypothesis_writer:
      - providerId: omlx
        model: gemma-4-26b-a4b-it-4bit
    query_term_writer:
      - providerId: omlx
        model: gemma-4-26b-a4b-it-4bit
    category_selector:
      - providerId: omlx
        model: gemma-4-26b-a4b-it-4bit
    retrieval_reranker:
      - providerId: omlx
        model: gemma-4-26b-a4b-it-4bit
    profile_selector:
      - providerId: omlx
        model: gemma-4-26b-a4b-it-4bit
  embedding:
    providerId: ollama
    model: nomic-embed-text
    dims: 768
    normalize: true''';
      final SubstrateConfig cfg =
          SubstrateConfigLoader.parse('$retrievalSubstrate\n');
      final substrate = buildSubstrate(cfg);

      // Under the old five-role default this open() would throw a
      // SubstrateConfigException naming the first unregistered retrieval role.
      await substrate.open(cfg);
      await substrate.close();
    });

    test('refuses a stub-kind provider with a located error', () {
      const String stubSubstrate = '''
substrate:
  providers:
    - id: stub-provider
      kind: stub
  roleRoutes:
    analyser:
      - providerId: stub-provider
        model: any
  embedding:
    providerId: stub-provider
    model: any
    dims: 1''';
      final SubstrateConfig cfg = SubstrateConfigLoader.parse('$stubSubstrate\n');

      expect(
        () => buildSubstrate(cfg),
        throwsA(isA<SubstrateConfigException>().having(
            (e) => e.message, 'message', allOf(contains('stub'), contains('stub-provider')))),
      );
    });

    test('refuses a provider whose auth uses a secretRef with a located error',
        () {
      const String secretSubstrate = '''
substrate:
  providers:
    - id: vendor
      kind: openai
      baseUrl: http://vendor.local/v1/
      auth:
        method: api_key
        secretRef: _ai/secrets/vendor.token
      models:
        - m
  roleRoutes:
    analyser:
      - providerId: vendor
        model: m
  embedding:
    providerId: vendor
    model: m
    dims: 768''';
      final SubstrateConfig cfg = SubstrateConfigLoader.parse('$secretSubstrate\n');

      expect(
        () => buildSubstrate(cfg),
        throwsA(isA<SubstrateConfigException>()
            .having((e) => e.message, 'message', contains('secretRef'))),
      );
    });

    test('refuses an embedding that points at a non-Ollama provider with a '
        'located error', () {
      const String openaiEmbedSubstrate = '''
substrate:
  providers:
    - id: vendor
      kind: openai
      baseUrl: http://vendor.local/v1/
      models:
        - m
  roleRoutes:
    analyser:
      - providerId: vendor
        model: m
  embedding:
    providerId: vendor
    model: m
    dims: 768''';
      final SubstrateConfig cfg =
          SubstrateConfigLoader.parse('$openaiEmbedSubstrate\n');

      expect(
        () => buildSubstrate(cfg),
        throwsA(isA<SubstrateConfigException>()
            .having((e) => e.message, 'message', contains('Ollama'))),
      );
    });
  });

  group('#31 buildSubstrate — agent_sdk provider (design-spec phase 3)', () {
    // A config that manufactures an agent-SDK provider alongside the Ollama
    // embedding provider. The agent-SDK provider's bridge socket is never
    // dialed (no completion runs in this group), so no live VS Code window is
    // needed — manufacture is synchronous and offline.
    String agentSdkSubstrate({String options = ''}) => '''
substrate:
  providers:
    - id: claude
      kind: agent_sdk
      models:
        - claude-sonnet-4-6$options
    - id: ollama
      kind: ollama
      baseUrl: http://10.8.0.9:11434
      models:
        - nomic-embed-text
  roleRoutes:
    assistant_to_user:
      - providerId: claude
        model: claude-sonnet-4-6
  embedding:
    providerId: ollama
    model: nomic-embed-text
    dims: 768
    normalize: true''';

    test('manufactures an AgentSdkLlmProvider with route default + defaults',
        () {
      final SubstrateConfig cfg =
          SubstrateConfigLoader.parse('${agentSdkSubstrate()}\n');
      final substrate = buildSubstrate(cfg);

      final provider = substrate.providers['claude'];
      expect(provider, isA<AgentSdkLlmProvider>());
      final sdk = provider as AgentSdkLlmProvider;
      expect(sdk.id, 'claude');
      expect(sdk.defaultModel, 'claude-sonnet-4-6');
      expect(sdk.maxTurns, isNull);
      expect(sdk.permissionMode, PermissionMode.default_);
    });

    test('reads permissionMode + maxTurns from options', () {
      const String options = '''

      options:
        permissionMode: acceptEdits
        maxTurns: 12''';
      final SubstrateConfig cfg =
          SubstrateConfigLoader.parse('${agentSdkSubstrate(options: options)}\n');
      final sdk = buildSubstrate(cfg).providers['claude'] as AgentSdkLlmProvider;
      expect(sdk.permissionMode, PermissionMode.acceptEdits);
      expect(sdk.maxTurns, 12);
    });

    test('the default session mode is `none` → NoSessionStrategy', () {
      final SubstrateConfig cfg =
          SubstrateConfigLoader.parse('${agentSdkSubstrate()}\n');
      final sdk = buildSubstrate(cfg).providers['claude'] as AgentSdkLlmProvider;
      expect(sdk.sessionStrategy, isA<NoSessionStrategy>());
    });

    test('sessionMode brain builds a BrainSessionStrategy under the run root',
        () {
      const String options = '''

      options:
        sessionMode: brain''';
      final SubstrateConfig cfg =
          SubstrateConfigLoader.parse('${agentSdkSubstrate(options: options)}\n');
      final sdk = buildSubstrate(cfg, agentSdkSessionRoot: '/run/store')
          .providers['claude'] as AgentSdkLlmProvider;
      expect(sdk.sessionStrategy, isA<BrainSessionStrategy>());
    });

    test('sessionMode brain without a run root is a located error', () {
      const String options = '''

      options:
        sessionMode: brain''';
      final SubstrateConfig cfg =
          SubstrateConfigLoader.parse('${agentSdkSubstrate(options: options)}\n');
      expect(
        () => buildSubstrate(cfg),
        throwsA(isA<SubstrateConfigException>().having((e) => e.message,
            'message', allOf(contains('sessionMode'), contains('brain')))),
      );
    });

    test('sessionMode quest builds a QuestSessionStrategy from its options', () {
      const String options = '''

      options:
        sessionMode: quest
        questId: tom_brain
        sessionKey: default
        questHistoryRoot: /srv/quests''';
      final SubstrateConfig cfg =
          SubstrateConfigLoader.parse('${agentSdkSubstrate(options: options)}\n');
      final sdk = buildSubstrate(cfg).providers['claude'] as AgentSdkLlmProvider;
      expect(sdk.sessionStrategy, isA<QuestSessionStrategy>());
    });

    test('sessionMode quest missing a required option is a located error', () {
      const String options = '''

      options:
        sessionMode: quest
        questId: tom_brain''';
      final SubstrateConfig cfg =
          SubstrateConfigLoader.parse('${agentSdkSubstrate(options: options)}\n');
      expect(
        () => buildSubstrate(cfg),
        throwsA(isA<SubstrateConfigException>().having((e) => e.message,
            'message', allOf(contains('sessionKey'), contains('quest')))),
      );
    });

    test('an unknown session mode is a located error listing valid values', () {
      const String options = '''

      options:
        sessionMode: nonsense''';
      final SubstrateConfig cfg =
          SubstrateConfigLoader.parse('${agentSdkSubstrate(options: options)}\n');
      expect(
        () => buildSubstrate(cfg),
        throwsA(isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('sessionMode'), contains('brain'),
                contains('quest')))),
      );
    });

    test('an invalid permissionMode is a located error listing valid values',
        () {
      const String options = '''

      options:
        permissionMode: nonsense''';
      final SubstrateConfig cfg =
          SubstrateConfigLoader.parse('${agentSdkSubstrate(options: options)}\n');
      expect(
        () => buildSubstrate(cfg),
        throwsA(isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('permissionMode'), contains('acceptEdits')))),
      );
    });
  });

  group('#31 buildWebSearch / buildWebFetch — config-driven web tools', () {
    test('the default web-search config manufactures a live DuckDuckGo search',
        () {
      // The loader always defaults `webSearch:` to a single DuckDuckGo HTML
      // provider, so a substrate config that omits the block still resolves to
      // a real search engine — the run builder no longer falls back to a no-web
      // double.
      final SubstrateConfig cfg =
          SubstrateConfigLoader.parse('$_substrateSection\n');

      final search = buildWebSearch(cfg.webSearch);

      expect(search, isA<DefaultWebSearch>());
      final ddg = search as DefaultWebSearch;
      expect(ddg.registeredProviderIds, contains('duckduckgo'));
      expect(ddg.defaultProviderId, 'duckduckgo');
      search.close();
    });

    test('an explicit ddg_html provider config is manufactured', () {
      const config = WebSearchConfig(
        defaultProvider: 'duckduckgo',
        providers: <String, WebSearchProviderConfig>{
          'duckduckgo': WebSearchProviderConfig(kind: 'ddg_html'),
        },
      );

      final search = buildWebSearch(config) as DefaultWebSearch;
      expect(search.registeredProviderIds, <String>['duckduckgo']);
      expect(search.defaultProviderId, 'duckduckgo');
      search.close();
    });

    test('an unknown web-search kind is refused with a located error', () {
      const config = WebSearchConfig(
        defaultProvider: 'mystery',
        providers: <String, WebSearchProviderConfig>{
          'mystery': WebSearchProviderConfig(kind: 'brave'),
        },
      );

      expect(
        () => buildWebSearch(config),
        throwsA(isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('webSearch.providers'), contains('mystery'),
                contains('brave'), contains('ddg_html')))),
      );
    });

    test('a defaultProvider naming no provider key is refused with a located '
        'error', () {
      const config = WebSearchConfig(
        defaultProvider: 'absent',
        providers: <String, WebSearchProviderConfig>{
          'duckduckgo': WebSearchProviderConfig(kind: 'ddg_html'),
        },
      );

      expect(
        () => buildWebSearch(config),
        throwsA(isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('defaultProvider'), contains('absent')))),
      );
    });

    test('buildWebFetch carries the config budget and user agent', () {
      const config = WebFetchConfig(
        defaultBudgetBytes: 4096,
        userAgent: 'TomBrainTest/9.9',
      );

      final fetch = buildWebFetch(config) as DefaultWebFetch;
      expect(fetch.defaultBudgetBytes, 4096);
      expect(fetch.userAgent, 'TomBrainTest/9.9');
      fetch.close();
    });
  });

  group('#31 ToolsConfigLoader — the tools two-tier file-scope section', () {
    test('a tools section loads its write and read roots onto the run config',
        () {
      final String doc = '$_substrateSection\n'
          'memory:\n'
          '  root: /tmp/x\n'
          '  sqliteVec:\n'
          '    binariesRoot: /opt/vec\n'
          'tools:\n'
          '  writeScope:\n'
          '    - /srv/project/a\n'
          '  readScope:\n'
          '    - /srv/project/b\n'
          '$_accessSection\n';

      final BrainRunConfig config = BrainRunConfigLoader.parse(doc);

      expect(config.tools, isNotNull);
      expect(config.tools!.writeScope, <String>['/srv/project/a']);
      expect(config.tools!.readScope, <String>['/srv/project/b']);
    });

    test('a read-only tools section grants reach without a writeable root', () {
      const String doc = '''
tools:
  readScope:
    - /srv/readonly''';

      final ToolsConfig? tools = ToolsConfigLoader.parse(doc);

      expect(tools!.writeScope, isEmpty);
      expect(tools.readScope, <String>['/srv/readonly']);
    });

    test('a missing tools section leaves config.tools null (engine placeholder)',
        () {
      final String doc = '$_substrateSection\n'
          'memory:\n'
          '  root: /tmp/x\n'
          '  sqliteVec:\n'
          '    binariesRoot: /opt/vec\n'
          '$_accessSection\n';

      expect(BrainRunConfigLoader.parse(doc).tools, isNull);
    });

    test('an env token in a write-scope root is expanded', () {
      const String doc = '''
tools:
  writeScope:
    - \${env:PROJECT_ROOT}/sub''';

      final ToolsConfig? tools = ToolsConfigLoader.parse(
        doc,
        envVars: const <String, String>{'PROJECT_ROOT': '/srv/proj'},
      );

      expect(tools!.writeScope, <String>['/srv/proj/sub']);
    });

    test('an empty writeScope list is refused with a located error', () {
      const String doc = '''
tools:
  writeScope: []''';

      expect(
        () => ToolsConfigLoader.parse(doc),
        throwsA(isA<ToolsConfigException>().having((e) => e.message, 'message',
            allOf(contains('tools.writeScope'), contains('at least one')))),
      );
    });

    test('a tools block with neither tier is refused with a located error', () {
      const String doc = '''
tools:
  somethingElse: true''';

      expect(
        () => ToolsConfigLoader.parse(doc),
        throwsA(isA<ToolsConfigException>().having(
            (e) => e.message, 'message', contains('somethingElse'))),
      );
    });

    test('a non-string write-scope entry is refused with a located error', () {
      const String doc = '''
tools:
  writeScope:
    - 42''';

      expect(
        () => ToolsConfigLoader.parse(doc),
        throwsA(isA<ToolsConfigException>().having((e) => e.message, 'message',
            allOf(contains('tools.writeScope[0]'), contains('string')))),
      );
    });

    test('the whole-process loader rejects an unknown top-level section', () {
      // The access loader gatekeeps top-level keys; a typo'd section name (not
      // one of substrate/memory/engine/dispatcher/trail/tools/access) is caught.
      final String doc = '$_substrateSection\n'
          'memory:\n'
          '  root: /tmp/x\n'
          '  sqliteVec:\n'
          '    binariesRoot: /opt/vec\n'
          'toolz:\n'
          '  writeScope:\n'
          '    - /srv/x\n'
          '$_accessSection\n';

      expect(
        () => BrainRunConfigLoader.parse(doc),
        throwsA(isA<AccessConfigException>()
            .having((e) => e.toString(), 'toString', contains('toolz'))),
      );
    });
  });

  group('#31 standUpBrainProcessFromConfig — starts from the config file', () {
    test('binds a port, answers /healthz + /v1/models, and leaves the config '
        'file bytes unmodified', () async {
      // Real on-disk memory root + a config file under unique temp dirs.
      final Directory memoryRoot =
          Directory.systemTemp.createTempSync('tom_brain_run_31_mem_');
      final Directory cfgDir =
          Directory.systemTemp.createTempSync('tom_brain_run_31_cfg_');
      addTearDown(() {
        if (memoryRoot.existsSync()) memoryRoot.deleteSync(recursive: true);
        if (cfgDir.existsSync()) cfgDir.deleteSync(recursive: true);
      });

      final File cfgFile = File('${cfgDir.path}/tom_brain.yaml');
      cfgFile.writeAsStringSync(
        _runYaml(memoryRoot: memoryRoot.path, binariesRoot: vecRoot!),
      );
      // Snapshot the on-disk bytes before the process touches the file.
      final List<int> bytesBefore = cfgFile.readAsBytesSync();

      // Load from the file, then stand the whole cognition up from it.
      final BrainRunConfig config = BrainRunConfigLoader.loadFromFile(cfgFile.path);
      final BrainProcess process = await standUpBrainProcessFromConfig(
        config,
        // Bind an OS-assigned ephemeral port; read the real one back.
        serve: (handler, _) => serveWithShelfIo(handler, 0),
      );

      try {
        expect(process.port, greaterThan(0));

        final health = await _get(process.port, '/healthz');
        expect(health.statusCode, 200);
        expect((health.body as Map<String, Object?>)['status'], 'ok');

        final models = await _get(process.port, '/v1/models');
        expect(models.statusCode, 200);
        final modelsBody = models.body as Map<String, Object?>;
        expect(modelsBody['object'], 'list');
        expect(modelsBody['data'], isA<List<Object?>>());

        // Verify: the process started from the config file unmodified — the
        // loader reads, it never rewrites.
        expect(cfgFile.readAsBytesSync(), equals(bytesBefore));
      } finally {
        await process.stop();
      }
    });
  }, skip: skipNoBinary);
}
