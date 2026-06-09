// SubstrateToolWebSurface — the [ToolWebSurface] the `web.*` tools route
// through, adapting a `TomBrainSubstrateClient`'s web tools
// (`tom_brain_procedure_prototype_specification.md` § 21.4).
//
// `web.search` / `web.fetch` overlap the substrate `search` / `fetch`
// primitives (Q-F.5), so they open no new effect path: this adapter calls the
// substrate client's `webSearch` / `webFetch` and shapes the result into the
// same plain JSON map the scripted `sub.search` / `sub.fetch` bridge produces.
//
// Budget note: it wraps the substrate **client**, not the budget-charging
// `SubstrateBridge`. `tool.invoke` already pre-charges one `toolCalls` unit per
// call (PE-8), and a web call *is* that one tool call — routing through the
// bridge would double-count it. The map shaping mirrors
// `SubstrateBridge._searchToMap` / `_fetchToMap`; the two stay in lock-step
// because both mirror the substrate's `WebSearchResult` / `WebFetchResult`
// value types.

import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show
        BinaryFetchMeta,
        SearchHit,
        TomBrainSubstrateClient,
        WebFetchOptions,
        WebFetchResult,
        WebSearchOptions,
        WebSearchResult;

import 'tool_web_surface.dart';

/// Adapts a [TomBrainSubstrateClient] into the narrow [ToolWebSurface] the
/// `web.*` tools need.
///
/// Holds the raw substrate client (never the budget-charging bridge) so a web
/// tool call is counted exactly once, by the `tool.invoke` pre-charge (PE-8).
final class SubstrateToolWebSurface implements ToolWebSurface {
  /// The substrate client the two calls route through.
  final TomBrainSubstrateClient client;

  /// Wraps [client]'s web tools as a [ToolWebSurface].
  const SubstrateToolWebSurface(this.client);

  @override
  Future<Map<String, Object?>> search(String query, {int k = 10}) async {
    final result = await client.webSearch(query, options: WebSearchOptions(k: k));
    return _searchToMap(result);
  }

  @override
  Future<Map<String, Object?>> fetch(String url, {int? budgetBytes}) async {
    final result = await client.webFetch(
      Uri.parse(url),
      options: WebFetchOptions(budgetBytes: budgetBytes),
    );
    return _fetchToMap(result);
  }

  static Map<String, Object?> _searchToMap(WebSearchResult result) =>
      <String, Object?>{
        'provider': result.provider,
        'query': result.query,
        'hits': result.hits.map(_hitToMap).toList(),
      };

  static Map<String, Object?> _hitToMap(SearchHit hit) => <String, Object?>{
        'title': hit.title,
        'url': hit.url.toString(),
        'snippet': hit.snippet,
        'rank': hit.rank,
      };

  static Map<String, Object?> _fetchToMap(WebFetchResult result) =>
      <String, Object?>{
        'url': result.url.toString(),
        'status': result.status,
        'contentType': result.contentType,
        'truncated': result.truncated,
        if (result.text != null) 'text': result.text,
        if (result.json != null) 'json': result.json,
        if (result.binaryMeta != null) 'binaryMeta': _binaryMetaToMap(result.binaryMeta!),
      };

  static Map<String, Object?> _binaryMetaToMap(BinaryFetchMeta meta) =>
      <String, Object?>{
        'contentType': meta.contentType,
        if (meta.contentLength != null) 'contentLength': meta.contentLength,
      };
}
