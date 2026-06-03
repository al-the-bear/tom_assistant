// Barrel for the `web/` module — the substrate's web tools surface
// (B.29–B.32 / substrate_specification.md § 8).
//
// Module surface:
//
//   * `WebSearch` — abstract contract every consumer binds against
//     (the facade B.40+, dispatcher D-phase).
//   * `DefaultWebSearch` — registry-driven implementation; the only
//     concrete `WebSearch` shipped at B.29.
//   * `WebSearchProvider` — plug-in shape for one concrete search
//     engine.
//   * `DuckDuckGoHtmlSearchProvider` — no-key default provider.
//   * `WebSearchProviderException`, `UnknownWebSearchProvider` —
//     typed search-side error surfaces.
//   * `WebFetch` — abstract fetch contract (B.30).
//   * `DefaultWebFetch` — content-type-dispatching fetch impl backed
//     by the shared `WebHttpClient` seam (B.30).
//   * `WebFetchHttpException`, `WebFetchUnsupportedType`,
//     `WebFetchRobotsDenied` + `RobotsDenialReason` — typed fetch-side
//     error surfaces (B.30 / Q-B.30.3).
//   * `RobotsGate` + `RobotsRules` + `parseRobotsTxt` +
//     `robotsProductToken` + `robotsMatchPath` — robots.txt enforcement
//     policy consulted by `DefaultWebFetch` before every fetch
//     (Q-B.30.3).
//   * `extractReadableHtml` / `extractReadableHtmlString` — HTML →
//     prose strip helper, shared between fetch's HTML branch and
//     anywhere else the substrate needs to read prose out of HTML.
//   * `WebHttpClient` + `DefaultWebHttpClient` + `WebHttpResponse` +
//     `WebHttpBytesResponse` + `WebHttpTransportException` — narrow
//     wire-shape seam shared across all web tools (B.29 search +
//     B.30 fetch).
//
// What this barrel does NOT export:
//
//   * `WebSearchResult`, `WebSearchOptions`, `SearchHit`,
//     `WebFetchResult`, `WebFetchOptions`, `BinaryFetchMeta` — those
//     value types live under `lib/src/api/web_results.dart` and ship
//     through the `api/` barrel (consumer-facing surface). The web
//     tools are the *producers* of those values; the consumer-facing
//     contract on `TomBrainSubstrateClient` ships through `api/`.
//   * `WebSearchCompleted` / `WebFetchCompleted` substrate events —
//     those live under `lib/src/api/substrate_event.dart` and ship
//     through the `api/` barrel.
//
// Phase B build order for `web/`:
//
//   * B.29 ✅ — `WebSearch.search(query, {provider, k})` with
//     DuckDuckGo HTML as the default no-key provider, plug-in points
//     for SerpAPI / Brave / Tavily. This barrel.
//   * B.30 ✅ — `WebFetch.fetch(url, {budget})` with content-type-aware
//     extraction (HTML → readable text, JSON passthrough, binary →
//     metadata only).
//   * B.31 ✅ — Wire the web HTTP seam to `tom_core_kernel`'s
//     `TomHttpClientFactory` (`TomKernelWebHttpClient`) and add a
//     retry + circuit-breaker decorator (`RetryingWebHttpClient`) that
//     stacks around any inner `WebHttpClient`. `WebSearch` / `WebFetch`
//     code stays unchanged. The kernel itself does NOT ship a
//     `RetryPolicy` / `CircuitBreaker` surface (see Q-B.31.1); the
//     prototype implements both inside the substrate's web seam.
//   * B.32 — Conformance tests covering search structure, fetch
//     budget, large-page truncation, non-200 typed error.

export 'default_web_fetch.dart';
export 'default_web_search.dart';
export 'duckduckgo_search_provider.dart';
export 'html_readable_extractor.dart';
export 'retrying_web_http_client.dart';
export 'robots_policy.dart';
export 'tom_kernel_web_http_client.dart';
export 'web_fetch.dart';
export 'web_http_client.dart';
export 'web_search.dart';
export 'web_search_provider.dart';
