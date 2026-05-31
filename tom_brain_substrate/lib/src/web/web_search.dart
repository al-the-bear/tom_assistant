// B.29 — `WebSearch`: substrate-side abstract surface for the
// `webSearch(query, options)` method on `TomBrainSubstrateClient`.
//
// substrate_specification.md § 8.1: the substrate exposes
// `WebSearch.search(query, { provider, k, locale, safeSearch })` and
// returns `WebSearchResult { items: List<SearchHit> }`. The
// consumer-facing surface (`TomBrainSubstrateClient.webSearch`) is
// already in place from B.9 (`lib/src/api/tom_brain_substrate_client.dart`)
// with the value vocabulary in `web_results.dart`.
//
// This file declares the *substrate-internal* `WebSearch` abstract
// surface — the contract the facade (B.40+) binds against. The
// `WebSearch` interface is to web tools what `EmbeddingService` is to
// embeddings: one abstract type, swappable implementations, the facade
// holds exactly one concrete instance per substrate.
//
// At B.29 the only concrete implementation is `DefaultWebSearch`
// (`default_web_search.dart`), which dispatches to a registry of
// `WebSearchProvider` plug-ins (`web_search_provider.dart`). The
// shape lets a future B.x step swap the entire `WebSearch` engine
// (for example a router-aware variant that fans out across multiple
// providers and merges results) without touching consumers.

import '../api/web_results.dart';

/// Substrate-side web-search contract.
///
/// One implementation per engine-routing strategy:
///
///   - `DefaultWebSearch` (B.29) — single-provider dispatch backed by
///     the `WebSearchProvider` registry. The substrate's default; the
///     facade (B.40+) constructs one of these from `SubstrateConfig`.
///   - Future router-aware variants (not in scope at B.29) — could fan
///     out to multiple providers, merge / re-rank, fall over on
///     provider-side errors. They implement this same surface; the
///     facade swap is a constructor argument.
///
/// **Failure surfaces** propagate unchanged from the underlying
/// provider:
///
///   - `UnknownWebSearchProvider` — caller pinned a provider id that
///     is not registered.
///   - `WebSearchProviderException` (`web_search_provider.dart`) —
///     engine returned an engine-side error.
///   - `WebHttpTransportException` (`web_http_client.dart`) — transport
///     failed before any HTTP response arrived.
///
/// The router-level retry / failover layer (B.31) wraps these into a
/// typed `LlmFailure`-style taxonomy at the boundary; until then the
/// raw exception is what consumers see.
abstract class WebSearch {
  /// Runs [query] through the configured provider (default or pinned
  /// via [options.provider]) and returns at most [options.k] hits.
  ///
  /// The returned [WebSearchResult] carries:
  ///
  ///   - `provider` — the engine id that served the query (matches
  ///     the pinned id when [options.provider] was set; otherwise the
  ///     substrate's default).
  ///   - `query` — the original query, verbatim.
  ///   - `hits` — at most [options.k] hits in engine-supplied rank
  ///     order (1-based `rank`).
  ///
  /// Empty result sets are returned as `WebSearchResult(hits: [])`,
  /// not as exceptions — "no results" is a legitimate engine answer.
  Future<WebSearchResult> search(
    String query, {
    WebSearchOptions options = WebSearchOptions.empty,
  });

  /// Releases any provider resources this engine owns. Idempotent.
  void close();
}

/// Thrown by [WebSearch.search] when the caller pinned a provider id
/// via [WebSearchOptions.provider] that is not registered in the
/// substrate's provider registry.
///
/// Distinct from `WebSearchProviderException` (which the provider
/// itself raises when the engine returned an engine-side error) and
/// from `WebHttpTransportException` (which the transport raised
/// before any HTTP response arrived).
class UnknownWebSearchProvider implements Exception {
  /// The pinned provider id the caller passed via
  /// `WebSearchOptions.provider`.
  final String requestedProvider;

  /// The set of provider ids currently registered, for diagnostics.
  /// The list order matches the order they were registered (i.e. the
  /// order they appear in `SubstrateConfig.webSearch.providers`).
  final List<String> registeredProviders;

  UnknownWebSearchProvider({
    required this.requestedProvider,
    required this.registeredProviders,
  });

  @override
  String toString() => 'UnknownWebSearchProvider: requested '
      '"$requestedProvider"; registered providers: '
      '[${registeredProviders.join(', ')}]';
}
