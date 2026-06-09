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

import 'package:tom_brain_substrate/tom_brain_substrate.dart';

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
/// Throws [SubstrateConfigException] with a located message when a provider row
/// names an unmanufacturable kind (`anthropic` / `stub`), a network provider
/// declares no `baseUrl`, an `auth` uses an unresolved `secretRef`, or the
/// embedding provider is absent or not an Ollama provider.
InProcessTomBrainSubstrate buildSubstrate(
  SubstrateConfig config, {
  RoleRegistry? roleRegistry,
  WebSearch? webSearch,
  WebFetch? webFetch,
}) {
  // ── Manufacture one concrete provider per config row. ──
  final Map<String, LlmProvider> providers = <String, LlmProvider>{};
  for (final ProviderProfile profile in config.providers) {
    providers[profile.id] = _buildProvider(profile);
  }

  // ── The router: every route comes from the config's projected policy. ──
  final LlmRouter router = LlmRouter(
    providers: providers,
    policy: config.buildRouterPolicy(),
  );

  // ── Embeddings: reuse the manufactured Ollama provider the config names. ──
  final OllamaEmbeddingService embeddingService =
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
    // unroutable; and registering only the procedure roster left the creation
    // loop's `creator` / `tester` / `reviewer` calls unroutable. This roster
    // registers all their templates; the config's `roleRoutes` supplies their
    // routes (both halves are required for a role to dispatch).
    roleRegistry: roleRegistry ??
        bootstrapRoleRegistryWithRetrievalProcedureAndCreation(),
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
LlmProvider _buildProvider(ProviderProfile profile) {
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

/// Builds the embedding service from `config.embedding`, reusing the already
/// manufactured Ollama provider it names.
///
/// The loader cross-validates that `embedding.providerId` references a known
/// provider, so the lookup miss here only fires if a hand-built config skipped
/// that invariant — it is still reported with a located message.
OllamaEmbeddingService _buildEmbeddingService(
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
