/// Substrate layer for Tom Brain — LLM provider abstraction, role /
/// persona system, embedding service, web tools, MCP client.
///
/// Every prompt the brain issues is dispatched through this layer
/// wrapped in the `AssistantDedicationAnchor` (from `tom_brain_shared`,
/// see `substrate_specification.md` § 5 and the quest overview
/// hard principle on the user-assistant framing being structural,
/// not advisory). There is no public path that bypasses the anchor;
/// B.23 will land a dedicated test that enforces this.
///
/// At B.9 the package exposes:
///   * The outbound MCP client surface (B.8) — `McpClient`,
///     `McpSession`, transports, typed errors.
///   * The consumer-facing api/ surface (B.9) — `TomBrainSubstrate`,
///     `TomBrainSubstrateClient`, plus every value type listed in
///     `substrate_specification.md` § 3.1.
///
/// The rest of `lib/src/` is still empty; subsequent steps land
/// the LLM / role / embed / web / config / facade subsystems:
///
/// - B.6 ✅ — Project skeleton (`lib/`, `test/`, `pubspec.yaml`,
///   `_copilot_guidelines/`).
/// - B.7 ✅ — Runtime dependencies (`tom_brain_shared`, `tom_basics`,
///   `tom_core_kernel`, `tom_core_server`, `dart_mcp`).
/// - B.8 ✅ — Outbound MCP client (`McpClient`, `McpSession`,
///   `McpTransport` abstraction with `StdioMcpTransport`,
///   `HttpMcpTransport`, `ChannelMcpTransport`, bearer-token auth
///   plumbing on the HTTP transport, typed [McpClientException]
///   taxonomy). Spec § 3.2 reference.
/// - B.9 ✅ — Top-level `TomBrainSubstrate` interface (the engine
///   bridge's single entry point) + `TomBrainSubstrateClient` (the
///   consumer-facing contract) + every value type from spec § 3.1
///   (`LlmCall`, `LlmOptions`, `ToolCatalogue`, `LlmCallReport`,
///   sealed `LlmStreamEvent` family, `LlmFailure`,
///   `EmbeddingResult`, `EmbeddingModelIdentity`, web-tool result /
///   option types, `McpEndpoint`, sealed `SubstrateEvent` family,
///   `SubstrateStats`, opaque `SubstrateConfig` placeholder,
///   `CancellationToken` / `CancellationTokenSource`). No
///   implementations yet — interfaces and value classes only.
/// - B.10 ✅ — Documented no-op per policy override 5
///   (`.tom_metadata/tom_master.yaml` is out of scope for Tom Brain).
/// - B.11 ✅ — `LlmProvider` abstract interface + `WirePrompt`
///   value class under `lib/src/llm/`. The provider-layer surface:
///   `String get id`, `complete(WirePrompt, LlmOptions)` returning a
///   `Future<LlmCallReport>`, `completeStream(WirePrompt, LlmOptions)`
///   returning a `Stream<LlmStreamEvent>`. `WirePrompt` is the
///   post-anchor-injection prompt; only the (B.21+) role registry
///   produces it, only providers consume it. Embedding / health
///   members of the spec § 4.1 surface land in their owning steps
///   (B.25/26 / B.18).
/// - B.12+ onwards — `LlmOptions` ratification, `LlmCallReport`
///   ratification, provider impls (Ollama / OpenAI passthrough /
///   stub), routing, roles, anchor injection wiring, embedding
///   service, web tools, config, observability, in-process facade,
///   phase-end review.
///
/// Note on plan-text vs. file-comment numbering: the plan numbers the
/// substep that is "folder layout" as B.8 in the older draft; the
/// authoritative `prototype_implementation_plan.md` Phase B section
/// re-labels B.8 as **MCP client**. The folder layout (B.6 - B.8
/// shared work) is treated as a precondition of the client work,
/// completed implicitly when the MCP client sub-folder lands.
///
/// See `_ai/quests/tom_brain/prototype_implementation_plan.md` Phase B
/// for the build order, and `_ai/quests/tom_brain/substrate_specification.md`
/// for the contract this package implements.
library;

// B.8 — Outbound MCP client surface (Substrate Spec § 3.2).
//
// Exposes the transport abstraction plus the two prototype transports
// (stdio, Streamable-HTTP-JSON), the `ChannelMcpTransport` used by
// tests and in-process colocation, the typed error taxonomy, and the
// `McpClient` / `McpSession` pair that wraps `dart_mcp`'s outbound
// client.
export 'src/mcp_client/mcp_client_barrel.dart';

// B.9 — Consumer-facing api/ surface (Substrate Spec § 3.1).
//
// `TomBrainSubstrate` (in-process marker), `TomBrainSubstrateClient`
// (substitutable contract), and every value type listed in spec
// § 3.1. The api/ barrel intentionally does NOT re-export the
// mcp_client surface — that surface is exported above so the two
// independent module barrels stay independent.
export 'src/api/api.dart';

// B.11 — Provider-layer LLM surface (Substrate Spec § 4).
//
// `LlmProvider` (abstract) + `WirePrompt` (post-anchor prompt). The
// router (B.18+) and provider implementations (B.14–B.16) consume
// this surface; the api/-side `TomBrainSubstrateClient.complete` /
// `completeStream` (B.9) is the *only* consumer-facing path that
// dispatches through it. Consumers should not implement `LlmProvider`
// directly — exposed from the top-level barrel so test fakes and
// future router code can bind against the contract under the
// `lints/recommended` "no `package:foo/src/...`" rule.
export 'src/llm/llm_barrel.dart';

// B.18 / B.19 — Router-layer surface (Substrate Spec § 5).
//
// `LlmRouter` (role-keyed dispatch with failover classification and
// per-credential cooldown), `RouterPolicy` (immutable router config
// carrying the role → chain map, per-class cooldown durations, retry
// budget, and overloaded-backoff window — B.36's YAML loader produces
// it), `LlmFailureClassifier` + the closed taxonomy from spec § 5.4,
// `RouteEntry` (per-row value class composed inside `RouterPolicy`),
// and the typed router errors (`NoRouteAvailable`, `RoleNotFound`,
// `ContextOverflowError`, `RouteAttempt`). The router is the *only*
// legitimate consumer of `LlmProvider.complete` / `completeStream`
// outside of contract tests; consumer-facing
// `TomBrainSubstrateClient.complete` (B.40+) will dispatch through it.
export 'src/router/router_barrel.dart';
