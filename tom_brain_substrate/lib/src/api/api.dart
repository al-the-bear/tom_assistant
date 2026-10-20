// Barrel for the `api/` module — the consumer-facing surface of
// the Tom Brain substrate (B.9 / substrate_specification.md § 3.1).
//
// Module surface:
//
//   * `TomBrainSubstrateClient` — the substitutable contract every
//     consumer binds against (dispatcher, engine bridge, access
//     layer, tests).
//   * `TomBrainSubstrate` — the in-process marker base class
//     (`implements TomBrainSubstrateClient`); the concrete v1
//     `InProcessTomBrainSubstrate` (B.40+) extends this.
//   * Value types in the surface: `LlmCall`, `LlmOptions`,
//     `ToolCatalogue`, `ToolDescriptor`, `LlmCallReport`; sealed
//     `LlmEvent` family + `LlmFailure`; `EmbeddingResult` +
//     `EmbeddingModelIdentity`; web-tool types
//     (`WebSearchResult`, `WebSearchOptions`, `SearchHit`,
//     `WebFetchResult`, `WebFetchOptions`, `BinaryFetchMeta`);
//     `McpEndpoint`; sealed `SubstrateEvent` family;
//     `SubstrateStats`.
//   * `CancellationToken` / `CancellationTokenSource` — minimal
//     cancellation primitive used by `LlmCall.cancellationToken`.
//   * `SubstrateConfig` — concrete configuration root (B.36).
//     Re-exported from `../config/config_barrel.dart` so the api/
//     surface keeps offering the type under the same import path
//     as it did at B.9 when it was an opaque placeholder. The
//     loader (`SubstrateConfigLoader`) and the per-section value
//     types ride along on the same re-export.
//
// What this barrel does NOT export:
//
//   * `WirePrompt` — the post-role-assembly prompt shape consumed
//     by `LlmProvider`. Lives under `lib/src/llm/` (B.11+); it is
//     a provider-layer concept, not consumer-facing.
//   * The MCP client surface (`McpClient`, `McpSession`,
//     `McpToolInfo`, `McpToolResult`, `McpClientException`,
//     `McpTransport`, transport implementations). Those live
//     under `lib/src/mcp_client/` (B.8) and are re-exported from
//     the top-level package barrel directly. The api/ surface
//     only references `McpClient` as the return type of
//     `mcpClient(McpEndpoint)`.
//
// Phase B build order:
//
//   * B.9 ✅ — Everything in this barrel.
//   * B.10 — Wire into `.tom_metadata/tom_master.yaml` (no-op per
//            policy override 5; see plan preamble).
//   * B.11+ — LLM provider abstraction lands under `lib/src/llm/`.
//   * B.18+ — Router lands under `lib/src/router/`.
//   * B.21+ — Roles + anchor injection land under
//             `lib/src/roles/`.
//   * B.25+ — Embedding service lands under `lib/src/embed/`.
//   * B.29+ — Web tools land under `lib/src/web/`.
//   * B.36+ — Config / observability land under `lib/src/config/`
//             and `lib/src/obs/`.
//   * B.40+ — In-process facade
//             (`InProcessTomBrainSubstrate`) lands under
//             `lib/src/facade/`.

export 'cancellation.dart';
export 'embedding_result.dart';
export 'llm_call.dart';
export 'package:tom_core_llm/tom_core_llm.dart'
    show
        CapturedWirePrompt,
        LlmEvent,
        LlmFailure,
        LlmRunCompleted,
        LlmRunEnded,
        LlmRunFailed,
        LlmRunOutcome,
        LlmRunStarted,
        LlmTextDelta,
        LlmToolCall;
export 'mcp_endpoint.dart';
// B.36 — `SubstrateConfig` migrated from a B.9 placeholder under
// api/ to the concrete typed model under config/. The api/ barrel
// re-exports the full config barrel so the consumer-facing import
// path is unchanged for `SubstrateConfig` and is widened (additive
// only) to cover `SubstrateConfigLoader` + the per-section value
// types.
export '../config/config_barrel.dart';
export 'substrate_event.dart';
export 'substrate_stats.dart';
export 'tom_brain_substrate.dart';
export 'tom_brain_substrate_client.dart';
export 'web_results.dart';
