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
///   `SubstrateStats`, `CancellationToken` /
///   `CancellationTokenSource`). The B.9 `SubstrateConfig` placeholder
///   was replaced at B.36 by the concrete `SubstrateConfig` (rooted in
///   `lib/src/config/`); the api/ barrel re-exports the config barrel
///   so the consumer-facing import path is unchanged. No
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

// B.8 / B.33 / B.34 — Outbound MCP client surface (Substrate Spec § 3.2).
//
// Exposes the transport abstraction plus the two prototype transports
// (stdio, Streamable-HTTP-JSON), the `ChannelMcpTransport` used by
// tests and in-process colocation, the typed error taxonomy, and the
// `McpClient` / `McpSession` pair that wraps `dart_mcp`'s outbound
// client.
//
// B.34 layers config-side bearer-token plumbing on top of the B.8
// `McpBearerCredential`:
//
//   * `McpAuthConfig` (sealed) — `none` / `bearer(token | secretRef)`.
//   * `McpAuthResolver` — turns config + endpoint metadata into a
//     concrete `McpBearerCredential` (or `null`), reading secret
//     files once at resolve time and rejecting stdio + auth pairs
//     before any `connect()` is attempted.
//   * `McpAuthConfigInvalid` — operator-side config error, distinct
//     from the runtime-side `McpAuthFailed` (HTTP 401/403).
//   * `McpBearerCredential.fingerprint` / redacted `toString` — the
//     only token-identifying surface allowed in logs.
export 'src/mcp_client/mcp_client_barrel.dart';

// B.9 / B.40 — Consumer-facing api/ surface (Substrate Spec § 3.1).
//
// `TomBrainSubstrate` (in-process marker), `TomBrainSubstrateClient`
// (substitutable contract), and every value type listed in spec
// § 3.1. The api/ barrel intentionally does NOT re-export the
// mcp_client surface — that surface is exported above so the two
// independent module barrels stay independent.
//
// **B.40 binding rule (engine-bridge contract).** The procedure
// engine — `MemoryBridge` / `SubstrateBridge` in plan steps
// C.12–C.14, see `substrate_specification.md` § 16 — holds the
// substrate as a `TomBrainSubstrateClient`, never as
// `TomBrainSubstrate` and never as the concrete
// `InProcessTomBrainSubstrate` (B.41+). The interface is the only
// substitutable contract; the marker base class reserves an
// in-process-only seam but at B.40 ships no extra abstract
// members on top of the client. `test/b40_engine_bridge_contract_
// test.dart` locks the rule with a structural `_EngineBridgeStub`
// that takes only `TomBrainSubstrateClient` and exercises every
// member on the surface — a future widening of the engine to need
// the marker class or a concrete impl breaks this test first.
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

// B.21 / B.22 / B.23 — Role-layer surface (Substrate Spec § 6).
//
// B.21: `AllowedAction` (closed enum of action tokens),
// `RoleBudgetDefaults` (router-side merge target for per-call
// `LlmOptions`), `RoleTemplate` (the value class the registry holds at
// B.22 and the assemble path produces `WirePrompt` from at B.23).
//
// B.22: `RoleRegistry` (immutable holder of `RoleTemplate` instances
// with `get` / `lookup` / `contains` / `ids` / `templates` / `length`
// lookup APIs and a duplicate-id rejection at construction),
// `RoleTemplateNotFound` (the registry-specific miss exception, distinct
// from the router's `RoleNotFound`), `bootstrapRoleRegistry` (top-level
// factory producing the five prototype roles — `assistant_to_user`,
// `analyser`, `sub_thinker`, `recaller`, `evaluator` — in code; file-
// backed loading from `_ai/prompts/<role>.system.md` is deferred to
// B.36 per the bootstrap-file header), `prototypeRoleIds` (the canonical
// iteration order of those five ids).
//
// B.23: `RoleTemplate.assemble({inputs})` — the anchor-injecting
// producer of `WirePrompt`. Every assembled prompt has its body
// starting with `AssistantDedicationAnchor.text` (via
// `AssistantDedicationAnchor.wrap`, idempotent) and its `anchorHash`
// equal to `AnchorRegistry.currentHash`. There is no per-role override
// of the wrap; there is no "skip anchor" flag. The conformance suite
// at `test/b23_anchor_injection_test.dart` proves the invariant for
// every bootstrap role and every tampering vector enumerated in
// `assistant_dedication_anchor.dart`. The provider-side anchor stamp
// (every `LlmCallReport.anchorHash` equals the prompt's `anchorHash`)
// is the responsibility of each provider (B.14 / B.15 / B.16 comply)
// and is re-verified by the B.46 conformance test. The runtime hook
// at the `TomBrainSubstrate` facade (B.40) reads `AnchorRegistry.
// currentHash` off this barrel and raises `AnchorViolation`
// (exported via the `src/llm/llm_barrel.dart` surface) on mismatch.
//
// Plan-2 item 11: `loadFileBackedRoleRegistry({promptsDir})` — the
// on-disk counterpart to `bootstrapRoleRegistry`. For each prototype
// role it reads `<promptsDir>/<role>.system.md` and, when present and
// non-blank, substitutes the file content for the role's `personaText`;
// an absent or blank file falls back to the in-code bootstrap template.
// Only the persona voice is sourced from disk — `objective`, the
// allowed / forbidden action sets, the output schema, and the budget
// defaults remain the in-code authority, so a markdown file can never
// widen a role's capability surface. Every assembled prompt still goes
// through the same `RoleTemplate.assemble` path, so the anchor stays
// injected unconditionally and `anchorHash` still records
// `AnchorRegistry.currentHash`. `WirePrompt.templateSha` stays null.
//
// Still pending at B.23: the `templateRef` git-sha field (lands with
// the B.36 file-backed loader); the cross-validation step that asserts
// every routed role id has a registered template (Q-B.22.4); the B.40
// facade-level runtime hook that throws `AnchorViolation` on every
// emitted report whose `anchorHash` does not equal
// `AnchorRegistry.currentHash`. See the file headers under
// `lib/src/roles/` and `lib/src/llm/anchor_registry.dart` for the
// staged-handoff plan.
export 'src/roles/roles_barrel.dart';

// B.25 / B.26 / B.27 — Embedding-service surface (Substrate Spec § 7).
//
// `EmbeddingService` (abstract contract; one implementation per
// backend), `OllamaEmbeddingService` (prototype default backed by
// Ollama `nomic-embed-text`), the typed boundary failures
// `EmbeddingDimensionMismatch` / `EmbeddingBackendEmpty` that
// `embed()` and `embedBatch()` surface on backend defects (dim
// mismatch ⇒ silent model swap; empty vector ⇒ daemon refused),
// and `EmbeddingProbeResult` (B.27).
//
// B.26 fills in `embedBatch(texts)` with concurrency-capped fan-out
// over the same `embed()` path (Ollama's `/api/embeddings` is
// per-input). The `batchConcurrency` constructor knob on
// `OllamaEmbeddingService` (default 4 per spec § 7.3) caps how many
// `embed()` calls are in flight at once; the returned list preserves
// input order regardless of completion order.
//
// B.27 adds `EmbeddingService.probeIdentity()` — the boot-time
// round-trip that validates the backend dim against the configured
// identity and detects identity drift relative to a caller-supplied
// `previousIdentity`. On drift, the returned `EmbeddingProbeResult`
// carries a non-null `EmbeddingIdentityChanged` event (spec §
// 10.2); the substrate facade (B.40+) forwards it onto
// `events()`. Memory consumes the event to stamp the new identity
// on subsequent vector rows while keeping old rows under their
// original identity (`memory_specification.md` § 7.4 — cross-model
// vectors are never silently mixed in cosine math).
//
// The consumer-facing value types (`EmbeddingResult`,
// `EmbeddingModelIdentity`, `EmbeddingIdentityChanged`) ship
// through the `api/` barrel above (B.9); the embedding service is
// the *producer* of those values.
//
// B.28 closes the embed/ module: the cross-implementation conformance
// suite at `test/b28_embedding_service_conformance_test.dart` runs the
// four plan-specified guarantees (single + batch embedding, dimension
// stability, identity surfaces unchanged across calls) against every
// registered implementation. The Ollama harness binds against
// `OllamaEmbeddingService` with an in-test HTTP fake; a second in-test
// `_InMemoryEmbeddingService` harness anchors the contract on an impl
// that has nothing in common with Ollama (no transport, deterministic
// per-input output), so a regression to the abstract surface is caught
// regardless of which production backend ships next.
export 'src/embed/embed_barrel.dart';

// B.29 / B.30 — Web-tools surface (Substrate Spec § 8).
//
// Search (B.29):
//
//   * `WebSearch` — abstract substrate-side contract every consumer
//     binds against.
//   * `DefaultWebSearch` — registry-driven impl; the only concrete
//     `WebSearch` shipped at B.29.
//   * `WebSearchProvider` — plug-in shape for one concrete engine.
//   * `DuckDuckGoHtmlSearchProvider` — no-key default provider.
//   * `UnknownWebSearchProvider`, `WebSearchProviderException` — typed
//     search-side error surfaces.
//
// Fetch (B.30):
//
//   * `WebFetch` — abstract substrate-side contract every consumer
//     binds against.
//   * `DefaultWebFetch` — content-type-dispatching impl backed by the
//     shared `WebHttpClient` seam.
//   * `WebFetchHttpException` — non-2xx response surface.
//   * `WebFetchUnsupportedType` — spec § 8.2 unsupported-content-type
//     refusal (PDF at v1).
//   * `extractReadableHtml` / `extractReadableHtmlString` — HTML →
//     prose strip helper; used by `DefaultWebFetch`'s HTML branch.
//
// Shared HTTP seam (B.29, extended by B.30):
//
//   * `WebHttpClient` — abstract `get` / `postForm` / `getBytes`
//     surface. Test fakes implement this; the production seam is
//     `DefaultWebHttpClient`.
//   * `DefaultWebHttpClient` — `package:http`-backed production impl.
//     B.31 swaps this for a `tom_core_kernel.HttpClient`-backed
//     variant; `WebSearch` / `WebFetch` code does not change.
//   * `WebHttpResponse` — string-bodied response (used by `WebSearch`).
//   * `WebHttpBytesResponse` — byte-streamed response with budget
//     truncation (used by `WebFetch`).
//   * `WebHttpTransportException` — transport-level failure
//     (DNS / connection-refused / socket close / timeout).
//
// The consumer-facing value types (`WebSearchResult`, `WebSearchOptions`,
// `SearchHit`, `WebFetchResult`, `WebFetchOptions`, `BinaryFetchMeta`)
// ship through the `api/` barrel above (B.9); the web tools are the
// *producers* of those values.
//
// Plan steps B.31 (HttpClient wiring), B.32 (conformance tests) build
// out the rest of `web/`. B.29 landed the search half plus the shared
// HTTP seam; B.30 lands the fetch half on the same seam so B.31 only
// has to swap one transport class.
export 'src/web/web_barrel.dart';

// B.41 — In-process facade surface (Substrate Spec § 3.1 / § 16
// composition root).
//
// `InProcessTomBrainSubstrate` — the concrete v1 facade that extends
// `TomBrainSubstrate` (the in-process marker base, B.9) and composes
// the substrate's per-subsystem collaborators: a `RoleRegistry`
// (B.22), a `Map<String, LlmProvider>` (B.11+ provider impls), an
// `LlmRouter` (B.18) bound to those providers via a `RouterPolicy`,
// an `EmbeddingService` (B.25), `WebSearch` / `WebFetch` (B.29 /
// B.30), a `SubstrateEventBus` (B.38), and a lazy MCP-client cache
// keyed by `McpEndpoint.id` (B.8 / B.34).
//
// The facade is the only authority that:
//
//   * Calls `roleRegistry.get(roleId).assemble(...)` to produce
//     `WirePrompt`s — the assemble path is the only producer of the
//     anchored prompt body (B.23).
//   * Enforces `report.anchorHash == AnchorRegistry.currentHash`
//     on every `LlmCallReport` that crosses the consumer-facing
//     surface (`complete` + the terminal `LlmStreamCompleted` of
//     `completeStream`). A mismatch raises `AnchorViolation`
//     (fatal — spec § 12). The B.46 conformance test pins this.
//   * Dispatches to `LlmRouter.dispatch` / `dispatchStream` —
//     there is no provider call path in the facade that bypasses
//     the router.
//   * Emits the surface-owned `SubstrateEvent` variants
//     (`LlmCallCompleted`, `LlmCallFailed`, `EmbeddingComputed`,
//     `WebSearchCompleted`, `WebFetchCompleted`). Per-subsystem
//     variants (`LlmCallStarted` / `Chunk`, `ProviderFailover`,
//     `CredentialCooldownStarted`, `EmbeddingIdentityChanged`,
//     `McpHandshakeCompleted`, `McpCallCompleted`) are emitted by
//     their owning layers — see Q-B.41.2 / Q-B.41.3 in
//     `prototype_implementation_questions.md`.
//
// The isolate adapter variant the substrate spec § 16 mentions is
// deferred to `completion_steps.tom_brain.md`. The engine bridge
// (plan B.40) binds against `TomBrainSubstrateClient`, so the
// future isolate adapter ships through the same consumer surface
// without touching engine code.
export 'src/facade/facade_barrel.dart';

// B.37 / B.38 — Observability surface (Substrate Spec § 10.1 / § 10.2).
//
// B.37: `SubstrateLog` (the const-instance facade) +
// `SubstrateLogCategory` (the closed enum of six categories —
// `tom_brain.substrate.llm`, `…roles`, `…embed`, `…web`, `…mcp`,
// `…router`). Wraps the global `tomLog` instance from `tom_basics`
// with a category prefix; lazy `() => String` messages are preserved
// through the wrap. Spec § 10.1 is authoritative — plan step B.37
// lists five categories; the spec adds `router`. The wrapper carries
// all six; Q-B.37.1 captures the spec-vs-plan divergence.
//
// B.38: `SubstrateEventBus` — the broadcast `Stream<SubstrateEvent>`
// the composition root hands to every per-subsystem emitter (router,
// providers, embedding service, web tools, MCP client) and exposes
// as `TomBrainSubstrateClient.events()`. Direct shape-mirror of
// `MemoryEventBus` (A.85): asynchronous broadcast, idempotent
// close, emit-after-close raises `StateError`. The sealed
// `SubstrateEvent` sum the bus carries (twelve variants) already
// ships on the api/ barrel above (B.9). Plan step B.38 names five
// variants (`LlmCallStarted`, `LlmCallCompleted`, `ProviderFailover`,
// `EmbeddingComputed`, `WebFetchCompleted`); spec § 10.2 names
// twelve. The bus is typed on the abstract base, so the divergence
// is purely a test-side lock (Q-B.38.1).
//
// B.39 will land the behavioural tests across both legs (config
// roundtrip + event ordering + logger categorisation).
export 'src/obs/obs_barrel.dart';
