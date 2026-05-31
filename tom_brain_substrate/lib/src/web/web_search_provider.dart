// B.29 — `WebSearchProvider`: the plug-in surface every concrete search
// engine implements.
//
// substrate_specification.md § 8.1 enumerates the candidate providers:
//
//   - DuckDuckGo HTML — no key, default for the prototype.
//   - SerpAPI / Brave Search / Tavily / Kagi — optional, key-bearing,
//     configured per route.
//
// All of them slot into the same plug-in shape declared here: an
// id (matched against `WebSearchOptions.provider`) plus a `search`
// method that takes the query + the caller-supplied `k` cap and
// returns the engine's structured hits.
//
// B.29 ships exactly one concrete provider — `DuckDuckGoHtmlSearchProvider`
// — plus the plug-in interface. The remaining providers (Brave,
// SerpAPI, Tavily, Kagi) are deliberately out of scope at B.29: the
// plug-in contract is the deliverable, and a downstream change can land
// any of them as a one-file drop-in below `web_barrel.dart` whenever
// the operator wants the corresponding key configured.

import '../api/web_results.dart';

/// One pluggable search engine.
///
/// Concrete implementations:
///
///   - `DuckDuckGoHtmlSearchProvider` (`duckduckgo_search_provider.dart`)
///     — default no-key provider, ships with B.29.
///   - `BraveSearchProvider` / `SerpApiSearchProvider` /
///     `TavilySearchProvider` / `KagiSearchProvider` — not implemented
///     at B.29; the plug-in shape exists so they can be added later
///     without touching `DefaultWebSearch`.
abstract class WebSearchProvider {
  /// Stable identifier (e.g. `duckduckgo`, `brave`, `serpapi`).
  ///
  /// Used by `DefaultWebSearch` to look up the provider when the
  /// caller pins one via `WebSearchOptions.provider`. The substrate
  /// config (`webSearch.providers.<id>.kind` at B.36) maps a route's
  /// declared `kind` onto a registered provider with this id.
  String get id;

  /// Run [query] through this engine and return at most [k] hits.
  ///
  /// Implementations MUST:
  ///
  ///   - Honour the [k] cap. Engines may return fewer hits; the
  ///     substrate does not pad. Engines may return more hits than
  ///     requested in their wire response; the provider truncates to
  ///     [k] before returning.
  ///   - Number the returned [SearchHit.rank] field 1-based, in
  ///     engine-supplied order. Consumers can re-rank without losing
  ///     the engine's original order.
  ///   - Set [WebSearchResult.provider] to this provider's [id].
  ///   - Set [WebSearchResult.query] to the caller-supplied [query]
  ///     verbatim (the engine MAY have rewritten the query internally;
  ///     the returned `query` field is what the caller asked for).
  ///   - Surface transport failures as exceptions. Engine-side errors
  ///     that arrive on the response body (e.g. DDG's anti-bot block
  ///     page, a Brave / SerpAPI `error` JSON object) are surfaced as
  ///     [WebSearchProviderException].
  ///
  /// Implementations MUST NOT:
  ///
  ///   - Re-rank, re-score, or filter the hits beyond honouring [k].
  ///     Synthesis is procedure code (spec § 8.1).
  ///   - Cache results in the provider. Caching is a router / config
  ///     concern (not in scope for the prototype).
  ///   - Inject the assistant-dedication anchor — the anchor lives at
  ///     the LLM-call boundary, not on a tool call. Web tools never
  ///     prompt the LLM directly.
  Future<WebSearchResult> search(String query, {required int k});

  /// Releases any backend resources the provider owns (e.g. an HTTP
  /// client when the provider constructed it). Idempotent.
  void close();
}

/// Thrown by a [WebSearchProvider] when the engine returned an
/// engine-side error (anti-bot block, malformed response, billing /
/// quota exceeded). Distinct from a transport-layer exception
/// ([WebHttpTransportException] from `web_http_client.dart`) so the
/// router-side classifier (B.31) can react differently.
///
/// [providerId] is the [WebSearchProvider.id] that raised the error;
/// [statusCode] is the HTTP status when available (null for engines
/// that wrap engine errors inside a 200 OK body); [message] is a
/// human-readable description for the trail; [bodyExcerpt] is the
/// first ~512 bytes of the response body for forensic logging.
class WebSearchProviderException implements Exception {
  final String providerId;
  final int? statusCode;
  final String message;
  final String bodyExcerpt;

  WebSearchProviderException({
    required this.providerId,
    required this.message,
    this.statusCode,
    this.bodyExcerpt = '',
  });

  @override
  String toString() =>
      'WebSearchProviderException($providerId${statusCode != null ? ' status=$statusCode' : ''}): '
      '$message${bodyExcerpt.isEmpty ? '' : ' (body excerpt: $bodyExcerpt)'}';
}
