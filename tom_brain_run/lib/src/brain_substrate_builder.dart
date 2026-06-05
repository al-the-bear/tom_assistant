// buildOmlxOllamaSubstrate — the real substrate composition root for the
// prototype's run assembly (Plan-2 step #30).
//
// The substrate facade `InProcessTomBrainSubstrate` is a *wirer*, not a
// *manufacturer*: its constructor takes already-assembled collaborators (a role
// registry, a provider map, a router, an embedding service, web tools). The
// substrate package deliberately ships no `SubstrateConfig → facade` builder —
// "The composition root (test, app boot) constructs providers + router +
// embedding service + web tools and hands them to the facade" (the facade's own
// header). This file IS that composition root for the prototype's run shape:
// the LLM substrate routed through an OpenAI-format passthrough provider against
// an oMLX endpoint, embeddings through Ollama's `nomic-embed-text`.
//
// ── What it builds ───────────────────────────────────────────────────
//
//   * The LLM provider — an `OpenAiPassthroughProvider` pointed at the oMLX
//     endpoint. oMLX speaks the OpenAI `/v1/chat/completions` dialect, so the
//     passthrough provider is the right transport.
//   * The router — every role the bootstrap registry knows routes to that one
//     LLM provider. The prototype's `answer_with_memory_v1` only ever calls the
//     `assistant_to_user` role, but routing every registered role to the same
//     provider means a procedure that reaches another role (analyser /
//     sub_thinker / recaller / evaluator) gets the substrate LLM rather than a
//     `NoRouteAvailable` surprise — a defensive, single-provider routing table.
//   * The embedding service — an `OllamaEmbeddingService` over its own
//     `OllamaLlmProvider` (Ollama's `/api/embeddings` is a separate transport
//     from the chat LLM). 768-dim `nomic-embed-text`, normalized, matching the
//     memory bootstrap embedding identity.
//   * Web tools — the no-web posture by default (see [NoWebSearch] /
//     [NoWebFetch]). The prototype's procedures do not search or fetch; this is
//     an honest "no web configured" stance, not a cognition double. A caller
//     that wires real `DefaultWebSearch` / `DefaultWebFetch` passes them in.
//
// Everything is parameter-driven: the endpoint URIs, the model ids, and the
// embedding tunables are arguments, so the run assembly (or a future
// whole-process config loader, Plan-2 step #31) supplies them without this
// builder owning any config-file parsing.

import 'package:tom_brain_substrate/tom_brain_substrate.dart';

/// The default embedding model — Ollama-hosted `nomic-embed-text` (768-dim),
/// matching the memory subsystem's bootstrap embedding identity.
const String defaultEmbeddingModel = 'nomic-embed-text';

/// The dimensionality `nomic-embed-text` returns. Pinned so a misconfigured
/// model swap surfaces as an `EmbeddingDimensionMismatch` rather than silently
/// corrupting the vector index.
const int defaultEmbeddingDims = 768;

/// The provider id the LLM substrate registers under (the router's route
/// target). Stable so a route table built elsewhere can reference it.
const String defaultLlmProviderId = 'omlx';

/// The provider id the embedding transport registers under. Distinct from
/// [defaultLlmProviderId] — embeddings flow through Ollama, the chat LLM
/// through the oMLX passthrough.
const String defaultEmbeddingProviderId = 'ollama';

/// Builds the prototype's real substrate: an oMLX-backed OpenAI-passthrough LLM
/// routed for every bootstrap role, plus Ollama embeddings, behind the
/// `InProcessTomBrainSubstrate` facade (Plan-2 step #30).
///
/// [omlxBaseUri] is the oMLX OpenAI-format base (e.g. `http://127.0.0.1:8080`);
/// [llmModel] the model id the substrate asks oMLX for. [omlxApiKey] is the
/// optional bearer the passthrough provider sends (oMLX usually needs none).
///
/// [ollamaBaseUri] is the Ollama base (e.g. `http://127.0.0.1:11434`);
/// [embeddingModel] / [embeddingDims] / [embeddingNormalize] tune the embedding
/// identity (defaults: `nomic-embed-text`, 768, normalized).
///
/// [roleRegistry] overrides the bootstrap registry (every role it carries is
/// routed to the LLM provider); [webSearch] / [webFetch] override the no-web
/// default. All four are seams for a richer assembly to inject through.
InProcessTomBrainSubstrate buildOmlxOllamaSubstrate({
  required Uri omlxBaseUri,
  required String llmModel,
  required Uri ollamaBaseUri,
  String? omlxApiKey,
  String embeddingModel = defaultEmbeddingModel,
  int embeddingDims = defaultEmbeddingDims,
  bool embeddingNormalize = true,
  String llmProviderId = defaultLlmProviderId,
  String embeddingProviderId = defaultEmbeddingProviderId,
  RoleRegistry? roleRegistry,
  WebSearch? webSearch,
  WebFetch? webFetch,
}) {
  final RoleRegistry registry = roleRegistry ?? bootstrapRoleRegistry();

  // ── The chat LLM: OpenAI-format passthrough against oMLX. ──
  final OpenAiPassthroughProvider llmProvider = OpenAiPassthroughProvider(
    id: llmProviderId,
    baseUri: omlxBaseUri,
    defaultModel: llmModel,
    apiKey: omlxApiKey,
  );
  final Map<String, LlmProvider> providers = <String, LlmProvider>{
    llmProvider.id: llmProvider,
  };

  // Every registered role routes to the single LLM provider (see file header
  // for why every role, not just `assistant_to_user`).
  final RouterPolicy policy = RouterPolicy(
    roleRoutes: <String, List<RouteEntry>>{
      for (final String roleId in registry.ids)
        roleId: <RouteEntry>[
          RouteEntry(providerId: llmProvider.id, model: llmModel),
        ],
    },
  );
  final LlmRouter router = LlmRouter(providers: providers, policy: policy);

  // ── Embeddings: a separate Ollama transport. ──
  final OllamaLlmProvider embeddingProvider = OllamaLlmProvider(
    id: embeddingProviderId,
    baseUri: ollamaBaseUri,
    defaultModel: embeddingModel,
  );
  final OllamaEmbeddingService embeddingService = OllamaEmbeddingService(
    provider: embeddingProvider,
    model: embeddingModel,
    dims: embeddingDims,
    normalize: embeddingNormalize,
  );

  return InProcessTomBrainSubstrate(
    roleRegistry: registry,
    providers: providers,
    router: router,
    embeddingService: embeddingService,
    webSearch: webSearch ?? const NoWebSearch(),
    webFetch: webFetch ?? const NoWebFetch(),
  );
}

/// The no-web search posture: every query resolves to an empty hit list.
///
/// Not a stub double — an honest "no web search is configured for this process"
/// stance. The prototype's procedures never search; a richer assembly that
/// wants live search passes a `DefaultWebSearch` to [buildOmlxOllamaSubstrate]
/// instead.
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
