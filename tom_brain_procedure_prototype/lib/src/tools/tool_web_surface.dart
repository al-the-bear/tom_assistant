// ToolWebSurface — the narrow web capability the `web.*` tools route through
// (`tom_brain_procedure_prototype_specification.md` § 21.4).
//
// `web.search` / `web.fetch` overlap the substrate `search` / `fetch`
// primitives, so they open **no new effect path** (Q-F.5): they call this
// method-only surface, which the engine binds over the substrate web client
// (`webSearch` / `webFetch`) at wiring time (step 15). The surface returns
// plain JSON-serialisable maps — a tool result is data, never a live handle
// (PE-1), so holding a `ToolContext` grants no raw network capability.
//
// Budget note: `tool.invoke` pre-charges one `toolCalls` unit per call (PE-8),
// and a web call *is* that one tool call — so a `ToolWebSurface` implementation
// routes through the substrate **client**, not the budget-charging
// `SubstrateBridge`, to avoid double-counting the same call.

/// The web search / fetch capability a `web.*` `BrainTool` may use.
///
/// Method-only and result-as-data: an implementation adapts the substrate web
/// client into the two calls the tools need, and nothing a tool can reach past
/// (PE-1). Optional on a `ToolContext` — a memory-only run carries none.
abstract interface class ToolWebSurface {
  /// Issues a web search for [query], returning at most [k] hits as a plain
  /// map (`{query, hits: [...]}`-shaped, mirroring the substrate `search`
  /// primitive).
  Future<Map<String, Object?>> search(String query, {int k});

  /// Fetches [url] (optionally capped at [budgetBytes]), returning a plain map
  /// (`{url, status, ...}`-shaped, mirroring the substrate `fetch` primitive).
  Future<Map<String, Object?>> fetch(String url, {int? budgetBytes});
}
