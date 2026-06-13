// buildSubstrate — the real `SubstrateConfig → InProcessTomBrainSubstrate`
// manufacturer for the prototype's run assembly (Plan-2 step #31).
//
// The substrate facade `InProcessTomBrainSubstrate` is a *wirer*, not a
// *manufacturer*: its constructor takes already-assembled collaborators (a role
// registry, a provider map, a router, an embedding service, web tools). The
// substrate package deliberately ships no `SubstrateConfig → facade` builder —
// "The composition root (test, app boot) constructs providers + router +
// embedding service + web tools and hands them to the facade" (the facade's own
// header). This file IS that composition root for the prototype's run shape: it
// reads a parsed [SubstrateConfig] (loaded from the whole-process YAML's
// `substrate:` section by `SubstrateConfigLoader`) and manufactures the live
// facade.
//
// ── What it builds, from the config ──────────────────────────────────
//
//   * One concrete `LlmProvider` per `config.providers` row, keyed by id:
//       - `ProviderKind.openai` → `OpenAiPassthroughProvider` against the
//         row's `baseUrl` (oMLX speaks the OpenAI `/v1/chat/completions`
//         dialect, so the passthrough provider is the right transport).
//       - `ProviderKind.ollama` → `OllamaLlmProvider` against the row's
//         `baseUrl`.
//       - `ProviderKind.anthropic` / `ProviderKind.stub` → a located
//         `SubstrateConfigException`: the run builder manufactures only the
//         two real transports the prototype's run shape uses. (A stub belongs
//         in a *test* composition root — `SmokeSubstrate` — not the real run
//         assembly; Anthropic is out of the prototype's substrate scope.)
//   * The router — `LlmRouter` over the manufactured provider map, with the
//     `RouterPolicy` the config projects (`config.buildRouterPolicy()`:
//     role → ordered route chain, cooldown / retry tunables). Routing is
//     entirely config-driven; the builder owns no route table.
//   * The embedding service — an `OllamaEmbeddingService` over the *same*
//     manufactured Ollama provider named by `config.embedding.providerId`
//     (Ollama's `/api/embeddings` rides the same transport as its chat LLM).
//     The embedding dims / model / normalize come straight from
//     `config.embedding`.
//   * Web tools — real, config-driven by default. `config.webSearch` always
//     resolves to at least the DuckDuckGo HTML provider (the loader defaults the
//     whole block when the YAML omits it), so [buildWebSearch] manufactures a
//     live `DefaultWebSearch` over the configured providers and [buildWebFetch]
//     a `DefaultWebFetch` over the configured budget / user-agent. The web.*
//     tools and the scripted `sub.search` / `sub.fetch` therefore reach a real
//     search engine. A caller that wants a different posture (an offline test,
//     a custom provider) passes its own [WebSearch] / [WebFetch] in;
//     [NoWebSearch] / [NoWebFetch] remain as the explicit no-web doubles.
//
// ── What it deliberately does NOT do ─────────────────────────────────
//
//   * It does not resolve secret references. A provider whose `auth` carries a
//     `secretRef` (rather than an inline token) is a located error: the run
//     builder has no secret-file resolver, and silently dropping the
//     credential would route unauthenticated. Inline tokens flow through.
//   * It does not call `facade.open(config)`. Role-registry validation is the
//     boot's job — `BrainProcessBoot.boot` calls `substrate.open(...)` when
//     `provisionBrain` threads the parsed `SubstrateConfig` through
//     `BrainProcessConfig.substrateConfig`. Validating here too would be a
//     second, redundant validation surface.

import 'dart:io';

import 'package:tom_brain_substrate/tom_brain_substrate.dart';
import 'package:tom_vscode_scripting_api/tom_vscode_scripting_api.dart';

import 'agent_sdk_llm_provider.dart';
import 'agent_sdk_session.dart';

/// Builds the prototype's real substrate from a parsed [SubstrateConfig]
/// (Plan-2 step #31).
///
/// [config] is the typed `substrate:` section of the whole-process YAML,
/// produced by `SubstrateConfigLoader`. Every endpoint, model, route, and
/// embedding tunable is read from it — the builder owns no defaults beyond the
/// no-web posture.
///
/// [roleRegistry] overrides the bootstrap registry (the registry the boot later
/// validates routed roles against); [webSearch] / [webFetch] override the
/// no-web default. All three are seams for a richer assembly to inject through.
///
/// [agentSdkSessionRoot] is the run's history/memory root under which a
/// `sessionMode: brain` agent-SDK provider persists its
/// `agent_sdk_sessions.json` (`{ brainSessionId → claudeSessionId }`) store
/// (design-spec § 1.4). `provisionBrain` threads `MemoryConfig.root` here; it is
/// only required when a provider row actually selects `sessionMode: brain`.
///
/// Throws [SubstrateConfigException] with a located message when a provider row
/// names an unmanufacturable kind (`anthropic` / `stub`), a network provider
/// declares no `baseUrl`, an `auth` uses an unresolved `secretRef`, or the
/// embedding provider is absent or not an Ollama provider.
InProcessTomBrainSubstrate buildSubstrate(
  SubstrateConfig config, {
  RoleRegistry? roleRegistry,
  WebSearch? webSearch,
  WebFetch? webFetch,
  String? agentSdkSessionRoot,
}) {
  // ── Manufacture one concrete provider per config row. ──
  final Map<String, LlmProvider> providers = <String, LlmProvider>{};
  for (final ProviderProfile profile in config.providers) {
    providers[profile.id] =
        _buildProvider(profile, agentSdkSessionRoot: agentSdkSessionRoot);
  }

  // ── The router: every route comes from the config's projected policy. ──
  final LlmRouter router = LlmRouter(
    providers: providers,
    policy: config.buildRouterPolicy(),
  );

  // ── Embeddings: reuse the manufactured Ollama provider the config names.
  //    The seam type is the `EmbeddingService` *interface* (G-S2): the only
  //    concrete `OllamaEmbeddingService` mention is the manufacture inside
  //    `_buildEmbeddingService`. Callers downstream (the substrate, the agents)
  //    see only the interface, so no Ollama assumption leaks past this builder. ──
  final EmbeddingService embeddingService =
      _buildEmbeddingService(config, providers);

  return InProcessTomBrainSubstrate(
    // The full live roster (the six bootstrap roles — the prototype five plus
    // `researcher`, § 6.2b — plus the six Extension-H retrieval roles plus the
    // three Todo-7 procedure roles). The run shape's procedures dispatch the
    // four-strategy retrieval conductor, whose `recall_*` legs call
    // `sub.retrievalRole('recall_planner' | 'hypothesis_writer' |
    // 'query_term_writer' | 'category_selector', …)`; the access layer calls
    // `profile_selector`; the authoring branch (`author_new_procedure_v1`)
    // calls `procedure_author` / `procedure_critic` / `procedure_selector`.
    // Registering only the bootstrap roles (`bootstrapRoleRegistry()`) left
    // every LLM recall leg unroutable, so the conductor silently degraded to
    // the two non-LLM seeds (PE-6) — recall ran far weaker than designed;
    // registering only the retrieval-enabled roster left the authoring branch
    // unroutable; registering only the procedure roster left the creation
    // loop's `creator` / `tester` / `reviewer` calls unroutable; and
    // registering only the creation roster left the planning loop's `planner` /
    // `decomposer` / `estimator` / `plan_evaluator` / `re_planner` calls
    // unroutable; and registering only the planning roster left the dreaming
    // agents' `extractor` / `connector` / `synthesiser` / `inquisitor` /
    // `pruner` / `reconsolidator` / `repetition_detector` calls unroutable.
    // This roster registers all their templates; the config's `roleRoutes`
    // supplies their routes (both halves are required for a role to dispatch).
    roleRegistry: roleRegistry ??
        bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningAndDream(),
    providers: providers,
    router: router,
    embeddingService: embeddingService,
    webSearch: webSearch ?? buildWebSearch(config.webSearch),
    webFetch: webFetch ?? buildWebFetch(config.webFetch),
  );
}

/// Builds a config-driven [WebSearch] from the substrate's `webSearch:` block.
///
/// Each `webSearch.providers` row is manufactured to its concrete
/// [WebSearchProvider]. The only kind the run builder manufactures is
/// `ddg_html` — the no-key DuckDuckGo HTML provider; any other kind (including
/// `brave`, which needs an auth resolver the run builder lacks) is a located
/// [SubstrateConfigException].
///
/// `config.defaultProvider` names a *config key*, not a provider id; the
/// returned [DefaultWebSearch]'s `defaultProviderId` is the built provider's
/// stable `.id` for that key. The loader cross-validates that
/// `defaultProvider` is a known key, so the lookup miss here only fires for a
/// hand-built config — it is still reported with a located message.
WebSearch buildWebSearch(WebSearchConfig config) {
  final List<WebSearchProvider> providers = <WebSearchProvider>[];
  String? defaultProviderId;
  config.providers.forEach((String key, WebSearchProviderConfig profile) {
    final WebSearchProvider provider = _buildWebSearchProvider(key, profile);
    providers.add(provider);
    if (key == config.defaultProvider) defaultProviderId = provider.id;
  });
  final String? resolvedDefault = defaultProviderId;
  if (resolvedDefault == null) {
    throw SubstrateConfigException(
      'substrate.webSearch.defaultProvider "${config.defaultProvider}" does '
      'not match any key in substrate.webSearch.providers.',
    );
  }
  return DefaultWebSearch(
    defaultProviderId: resolvedDefault,
    providers: providers,
  );
}

/// Manufactures one concrete [WebSearchProvider] for a config [profile] under
/// the catalogue [key]; an unmanufacturable kind is a located error.
WebSearchProvider _buildWebSearchProvider(
  String key,
  WebSearchProviderConfig profile,
) {
  switch (profile.kind) {
    case 'ddg_html':
      return DuckDuckGoHtmlSearchProvider();
    default:
      throw SubstrateConfigException(
        'substrate.webSearch.providers["$key"].kind = "${profile.kind}": the '
        'run substrate builder manufactures only the `ddg_html` web-search '
        'provider (DuckDuckGo HTML). A keyed provider such as `brave` needs an '
        'auth resolver the run builder does not carry.',
      );
  }
}

/// Builds a config-driven [WebFetch] from the substrate's `webFetch:` block.
///
/// The budget and forced `User-Agent` come straight from `config`; the run
/// builder adds no defaults of its own (the loader already defaults the block).
WebFetch buildWebFetch(WebFetchConfig config) => DefaultWebFetch(
      defaultBudgetBytes: config.defaultBudgetBytes,
      userAgent: config.userAgent,
    );

/// Manufactures one concrete [LlmProvider] for a config [profile].
///
/// `openai` / `ollama` map to their real transports; `anthropic` / `stub` are
/// out of the run builder's scope and surface as located errors.
/// [agentSdkSessionRoot] is forwarded to a `sessionMode: brain` agent-SDK row's
/// JSON store; see [buildSubstrate].
LlmProvider _buildProvider(
  ProviderProfile profile, {
  String? agentSdkSessionRoot,
}) {
  switch (profile.kind) {
    case ProviderKind.openai:
      return OpenAiPassthroughProvider(
        id: profile.id,
        baseUri: _requireBaseUrl(profile),
        // The provider's *default* model; the router selects the actual model
        // per route. The loader guarantees `models` is non-empty.
        defaultModel: profile.models.first,
        apiKey: _inlineApiKey(profile),
      );
    case ProviderKind.ollama:
      return OllamaLlmProvider(
        id: profile.id,
        baseUri: _requireBaseUrl(profile),
        defaultModel: profile.models.first,
      );
    case ProviderKind.agentSdk:
      return _buildAgentSdkProvider(
        profile,
        agentSdkSessionRoot: agentSdkSessionRoot,
      );
    case ProviderKind.anthropic:
    case ProviderKind.stub:
      throw SubstrateConfigException(
        'substrate.providers["${profile.id}"].kind = ${profile.kind.name}: the '
        'run substrate builder manufactures only `openai` and `ollama` '
        'providers. A `stub` belongs in a test composition root (SmokeSubstrate), '
        'and `anthropic` is outside the prototype run shape.',
      );
  }
}

/// Manufactures the agent-SDK provider for an `agent_sdk` config row
/// (design-spec § 1).
///
/// Reads the provider-specific knobs out of [ProviderProfile.options]:
///   * `bridgeHost` (default `127.0.0.1`) / `bridgePort`
///     (default [defaultVSCodeBridgePort]) — the VS Code Scripting-API CLI
///     server the provider drives Claude Code through;
///   * `permissionMode` (default `default`) — Claude Code's own tool-loop
///     permission posture, validated against the SDK's wire alphabet;
///   * `maxTurns` (optional) — Claude Code's internal agentic-loop turn cap;
///   * `sessionMode` (default `none`) — `none` (every call is a first call),
///     `brain` (persist the Claude session id keyed by the tom_brain session,
///     under [agentSdkSessionRoot]`/agent_sdk_sessions.json`), or `quest` (read
///     the window's quest history `.session.json`, requiring `questId` /
///     `sessionKey` / `questHistoryRoot` options). An unknown mode is a located
///     error.
///
/// The [AgentSdkLlmProvider.clientFactory] connects the bridge socket lazily
/// on the first completion (and is memoised), so manufacturing the provider
/// here is synchronous and never touches the network — a config can be built
/// and validated without a live VS Code window.
LlmProvider _buildAgentSdkProvider(
  ProviderProfile profile, {
  String? agentSdkSessionRoot,
}) {
  final Map<String, Object?> options = profile.options;

  final String bridgeHost = (options['bridgeHost'] as String?) ?? '127.0.0.1';
  final int bridgePort =
      (options['bridgePort'] as num?)?.toInt() ?? defaultVSCodeBridgePort;
  final int? maxTurns = (options['maxTurns'] as num?)?.toInt();
  final PermissionMode permissionMode =
      _parsePermissionMode(profile, options['permissionMode']);
  final AgentSdkSessionStrategy sessionStrategy =
      _buildSessionStrategy(profile, options, agentSdkSessionRoot);

  return AgentSdkLlmProvider(
    id: profile.id,
    // The route default; the router resolves the actual model per route.
    // The loader guarantees `models` is non-empty.
    defaultModel: profile.models.first,
    bridgePort: bridgePort,
    maxTurns: maxTurns,
    permissionMode: permissionMode,
    sessionStrategy: sessionStrategy,
    // The port flows as the factory argument (not the captured `bridgePort`),
    // so a runtime `/cli_server_port` rebind reconnects on the chosen port.
    clientFactory: (port) async {
      final VSCodeBridgeClient client =
          VSCodeBridgeClient(host: bridgeHost, port: port);
      final bool connected = await client.connect();
      if (!connected) {
        throw AgentSdkQueryException(
          'Could not connect to the VS Code bridge at $bridgeHost:$port '
          'for agent-SDK provider "${profile.id}".',
        );
      }
      return AgentSdkClient(VSCodeBridgeAgentSdkTransport(client));
    },
    // On a rebind, disconnect the old bridge socket so the old port is freed.
    // The transport is the run-layer `VSCodeBridgeAgentSdkTransport`, which
    // exposes the live `VSCodeBridgeClient`; the substrate `AgentSdkTransport`
    // contract has no disconnect, so the disposal lives here at the run seam.
    clientDisposer: (client) async {
      final AgentSdkTransport transport = client.transport;
      if (transport is VSCodeBridgeAgentSdkTransport) {
        await transport.client.disconnect();
      }
    },
  );
}

/// Builds the [AgentSdkSessionStrategy] the `sessionMode` option selects
/// (design-spec § 1.4): `none` → [NoSessionStrategy]; `brain` →
/// [BrainSessionStrategy] over `agent_sdk_sessions.json` under
/// [agentSdkSessionRoot] (required); `quest` → [QuestSessionStrategy] over the
/// `questId` / `sessionKey` / `questHistoryRoot` options (all required). An
/// unknown mode, or a missing required option, is a located error.
AgentSdkSessionStrategy _buildSessionStrategy(
  ProviderProfile profile,
  Map<String, Object?> options,
  String? agentSdkSessionRoot,
) {
  final Object sessionModeRaw = options['sessionMode'] ?? 'none';
  switch (sessionModeRaw) {
    case 'none':
      return const NoSessionStrategy();
    case 'brain':
      if (agentSdkSessionRoot == null) {
        throw SubstrateConfigException(
          'substrate.providers["${profile.id}"].options.sessionMode = "brain" '
          'needs the run history/memory root, but none was provided to '
          'buildSubstrate (agentSdkSessionRoot). provisionBrain threads it from '
          'the memory config; a hand-built substrate must pass it explicitly.',
        );
      }
      return BrainSessionStrategy(
        AgentSdkSessionStore(
          File('$agentSdkSessionRoot/agent_sdk_sessions.json'),
        ),
      );
    case 'quest':
      final String questId =
          _requireStringOption(profile, options, 'questId');
      final String sessionKey =
          _requireStringOption(profile, options, 'sessionKey');
      final String questHistoryRoot =
          _requireStringOption(profile, options, 'questHistoryRoot');
      return QuestSessionStrategy(
        questHistoryRoot: questHistoryRoot,
        questId: questId,
        sessionKey: sessionKey,
      );
    default:
      throw SubstrateConfigException(
        'substrate.providers["${profile.id}"].options.sessionMode = '
        '"$sessionModeRaw" is not a valid agent-SDK session mode. Valid values: '
        'none, brain, quest.',
      );
  }
}

/// Reads a required non-empty string [key] out of the agent-SDK [options] bag,
/// or a located error when it is absent / empty / not a string.
String _requireStringOption(
  ProviderProfile profile,
  Map<String, Object?> options,
  String key,
) {
  final Object? raw = options[key];
  if (raw is String && raw.isNotEmpty) return raw;
  throw SubstrateConfigException(
    'substrate.providers["${profile.id}"].options.$key is required for '
    'sessionMode "quest" but was ${raw == null ? 'absent' : '"$raw"'}.',
  );
}

/// Parses the optional `permissionMode` option into a [PermissionMode], or a
/// located error when it is present but not a valid SDK wire string.
PermissionMode _parsePermissionMode(ProviderProfile profile, Object? raw) {
  if (raw == null) return PermissionMode.default_;
  if (raw is String) {
    for (final PermissionMode mode in PermissionMode.values) {
      if (mode.wire == raw) return mode;
    }
  }
  final String valid =
      PermissionMode.values.map((PermissionMode m) => m.wire).join(', ');
  throw SubstrateConfigException(
    'substrate.providers["${profile.id}"].options.permissionMode = "$raw" is '
    'not a valid agent-SDK permission mode. Valid values: $valid.',
  );
}

/// Builds the embedding service from `config.embedding`, reusing the already
/// manufactured Ollama provider it names.
///
/// The loader cross-validates that `embedding.providerId` references a known
/// provider, so the lookup miss here only fires if a hand-built config skipped
/// that invariant — it is still reported with a located message.
/// Returns the [EmbeddingService] interface, not the concrete Ollama type: the
/// only place this run package names a concrete embedding implementation is the
/// manufacture below. Tightening the return type to the interface (G-S2) keeps
/// the one Ollama-specific decision (the `is! OllamaLlmProvider` guard) bounded
/// to this factory; everything the builder hands out is interface-typed.
EmbeddingService _buildEmbeddingService(
  SubstrateConfig config,
  Map<String, LlmProvider> providers,
) {
  final EmbeddingChoice choice = config.embedding;
  final LlmProvider? provider = providers[choice.providerId];
  if (provider == null) {
    throw SubstrateConfigException(
      'substrate.embedding.providerId "${choice.providerId}" does not match '
      'any provider in substrate.providers.',
    );
  }
  if (provider is! OllamaLlmProvider) {
    throw SubstrateConfigException(
      'substrate.embedding.providerId "${choice.providerId}" is not an Ollama '
      'provider; the run substrate builder embeds only through Ollama '
      '(/api/embeddings).',
    );
  }
  return OllamaEmbeddingService(
    provider: provider,
    model: choice.model,
    dims: choice.dims,
    normalize: choice.normalize,
  );
}

/// Returns a network provider's `baseUrl`, or a located error when absent.
Uri _requireBaseUrl(ProviderProfile profile) {
  final Uri? baseUrl = profile.baseUrl;
  if (baseUrl == null) {
    throw SubstrateConfigException(
      'substrate.providers["${profile.id}"] is a ${profile.kind.name} provider '
      'but declares no baseUrl; a network transport requires one.',
    );
  }
  return baseUrl;
}

/// Returns the inline API key for a provider, or `null` when its auth is
/// `none`. A `secretRef` (file-backed credential) is a located error — the run
/// builder has no secret resolver.
String? _inlineApiKey(ProviderProfile profile) {
  final ProviderAuthConfig auth = profile.auth;
  if (auth.isNone) return null;
  final String? secretRef = auth.apiKeySecretRef;
  if (secretRef != null) {
    throw SubstrateConfigException(
      'substrate.providers["${profile.id}"].auth uses secretRef "$secretRef"; '
      'the run substrate builder does not resolve secret files — supply an '
      'inline token or wire a secret resolver.',
    );
  }
  return auth.apiKeyInlineToken;
}

/// The no-web search posture: every query resolves to an empty hit list.
///
/// Not a stub double — an honest "no web search is configured for this process"
/// stance. The prototype's procedures never search; a richer assembly that
/// wants live search passes a `DefaultWebSearch` to [buildSubstrate] instead.
final class NoWebSearch implements WebSearch {
  /// Builds the no-web search.
  const NoWebSearch();

  @override
  Future<WebSearchResult> search(
    String query, {
    WebSearchOptions options = WebSearchOptions.empty,
  }) async =>
      WebSearchResult(
        provider: 'no-web',
        query: query,
        hits: const <SearchHit>[],
      );

  @override
  void close() {}
}

/// The no-web fetch posture: every fetch resolves to an empty `200` body.
///
/// The fetch-side counterpart of [NoWebSearch] — an honest "no web fetch is
/// configured" stance rather than a test double.
final class NoWebFetch implements WebFetch {
  /// Builds the no-web fetch.
  const NoWebFetch();

  @override
  Future<WebFetchResult> fetch(
    Uri url, {
    WebFetchOptions options = WebFetchOptions.empty,
  }) async =>
      WebFetchResult(
        url: url,
        status: 200,
        contentType: 'text/plain',
        text: '',
      );

  @override
  void close() {}
}
