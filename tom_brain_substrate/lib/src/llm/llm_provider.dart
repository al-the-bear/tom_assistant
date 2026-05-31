// B.11 — `LlmProvider` abstract interface.
//
// `substrate_specification.md` § 4.1 names the full provider
// surface; this step lands the *core LLM half* — the two methods
// every consumer of a provider needs:
//
//   - `Future<LlmCallReport> complete(WirePrompt, LlmOptions)`
//   - `Stream<LlmStreamEvent> completeStream(WirePrompt, LlmOptions)`
//
// Plus the minimum identification surface (`String get id`) without
// which the router (B.18+) cannot log a routing decision and the
// trail cannot attribute a call. `id` is the route key into the
// substrate's `providers` config map; dropping it from B.11 would
// force the very first provider implementation (B.14
// `OllamaLlmProvider`) to add it back, churning the interface.
//
// What this step deliberately defers (per the narrow plan-text):
//
//   - `Future<EmbeddingResult> embed(String text)` — lands at B.25
//     when the embedding service does. The provider abstraction is
//     the same per spec § 7.2, but the surface is added to this
//     interface at B.25 in the same change that ships the embedding
//     service so consumers and the conformance test land together.
//   - `Future<List<EmbeddingResult>> embedBatch(...)` — same, B.26.
//   - `Future<HealthSnapshot> health()` — the router (B.18+) consumes
//     it to decide cooldowns. Adding it now would require defining
//     `HealthSnapshot` here too, which the router owns. The router
//     and `health()` land in the same step.
//
// Each deferred member is listed as a comment-only placeholder in
// this file so a future reader sees the full eventual shape without
// being misled into thinking it is implemented today.
//
// Why a single abstract class, not a mixin or a typedef:
//
//   - The three prototype providers (Ollama, OpenAI passthrough,
//     stub; B.14–B.16) share *no* implementation — Ollama goes
//     through `tom_core_kernel.HttpClient` against
//     `localhost:11434`, OpenAI passthrough goes through the same
//     client against a configured base URL with bearer auth, the
//     stub is in-process and deterministic. A mixin would invite
//     shared base behaviour that does not exist; a typedef would
//     not let the analyzer enforce method-set completeness on
//     subclasses.
//   - The router (B.18+) holds a `Map<String, LlmProvider>` keyed
//     by `id`. A single abstract class makes that map type-precise.
//
// Why this lives under `lib/src/llm/` and is NOT exported from the
// top-level package barrel:
//
//   - Substrate's consumer-facing surface is `TomBrainSubstrateClient`
//     (api/, B.9). Consumers never construct or invoke an
//     `LlmProvider` directly — they submit `LlmCall` values and the
//     router selects a provider. Exposing the provider surface in
//     the package barrel would invite consumers to bypass the
//     router (and thus the role registry, and thus the anchor).
//   - Provider implementations (B.14–B.16) and the router (B.18+)
//     are the only legitimate consumers. They live under the same
//     `lib/src/` root and import the relative path
//     `package:tom_brain_substrate/src/llm/llm_provider.dart`.
//   - The `llm_provider_barrel.dart` re-export pattern (used by
//     `mcp_client/mcp_client_barrel.dart` and `api/api.dart`) is
//     deferred here until there is a second `llm/` file worth
//     exporting alongside `WirePrompt` + `LlmProvider`. B.14 adds
//     `OllamaLlmProvider` and at that point the barrel lands.

import '../api/llm_call.dart' show LlmCallReport, LlmOptions;
import '../api/llm_stream_event.dart' show LlmStreamEvent;
import 'wire_prompt.dart';

/// One LLM backend the substrate can route a call to.
///
/// Implemented by:
///
///   - `OllamaLlmProvider` (B.14) — talks Ollama's
///     `/api/chat` (and at B.25 `/api/embeddings`, `/api/tags`).
///   - `OpenAiPassthroughProvider` (B.15) — OpenAI-format Chat
///     Completions against OpenRouter / Groq / Cerebras / SambaNova
///     / OpenAI itself, with bearer-token auth.
///   - `StubLlmProvider` (B.16) — deterministic, in-process, no
///     network. Mandatory for the LLM-free conformance test on
///     memory (`memory_specification.md` § 1, invariant 2).
///
/// Every provider is constructed once at `TomBrainSubstrate.open(...)`
/// (B.40+) and held in the router's `providers` map keyed by [id].
/// Providers are not consumer-facing — consumers submit `LlmCall`
/// values through `TomBrainSubstrateClient.complete` /
/// `completeStream` (api/, B.9), which the router translates into a
/// provider call via the role registry (B.21+).
///
/// **Anchor invariant.** Every [complete] / [completeStream]
/// implementation MUST stamp the prompt's [WirePrompt.anchorHash]
/// onto the resulting [LlmCallReport.anchorHash]. The conformance
/// test at plan step B.46 asserts equality with
/// `tom_brain_shared.AnchorRegistry.currentHash` on every emitted
/// report and fails the build if a provider drops the hash.
///
/// **No prompt mutation.** Providers MUST NOT prepend, append, or
/// reorder the body of the prompt they receive. The role registry
/// has already wrapped the body with the anchor; any mutation here
/// would either (a) corrupt the anchor block and trip the
/// [LlmCallReport.anchorHash] regression, or (b) inject text the
/// audit trail cannot attribute to a role template. Providers
/// translate `WirePrompt.body` into whatever wire shape the backend
/// expects (e.g. a single `messages: [{role: user, content: body}]`
/// JSON object for Ollama / OpenAI Chat Completions) but the body
/// content goes through unchanged.
///
/// **Cancellation.** `LlmOptions` does not carry a cancellation
/// token — `LlmCall.cancellationToken` lives one layer above and is
/// the router's responsibility to propagate. Providers receive the
/// token through a per-call binding that the router establishes
/// (mechanics land with the router at B.18+). At B.11 the interface
/// alone does not yet expose the token; implementations will receive
/// it through the router-mediated call site.
abstract class LlmProvider {
  /// Stable identifier for this provider instance.
  ///
  /// Matches the `id` field in `SubstrateConfig.providers[*].id`
  /// (spec § 9). Examples from the prototype config:
  ///
  ///   - `ollama:local`
  ///   - `openai:passthrough`
  ///   - `stub`
  ///
  /// The router uses [id] as the key into its provider map and as
  /// the `providerId` field on `LlmCallReport`. Two `LlmProvider`
  /// instances with the same [id] in the same substrate is a config
  /// error caught at `open()` (B.36+).
  String get id;

  /// Runs the prompt to completion and returns the report.
  ///
  /// Implementations buffer the underlying response into a single
  /// [LlmCallReport]; non-streaming backends call into their HTTP
  /// surface directly, streaming backends drain the stream and
  /// return the final report. The substrate does not require
  /// providers to implement [complete] in terms of [completeStream]
  /// or vice versa — both methods are first-class and may choose
  /// the most efficient path on their backend.
  ///
  /// Failure shape:
  ///
  ///   - Providers MUST surface backend failures as exceptions whose
  ///     runtime classification comes from `LlmFailureClassifier`
  ///     (B.18+) — providers do NOT classify locally. The router
  ///     wraps the raw exception, decides whether to retry or rotate,
  ///     and only surfaces a typed failure to the consumer when the
  ///     route chain is exhausted.
  ///   - Cancellation (when wired at the router layer) surfaces as
  ///     an exception whose class maps to `cancelled_by_consumer`.
  ///
  /// **Anchor stamp.** The returned report's
  /// [LlmCallReport.anchorHash] MUST equal [prompt].[WirePrompt.anchorHash].
  /// A provider that loses the hash is a defect.
  ///
  /// **Provenance stamp.** The returned report's `providerId` MUST
  /// equal [id]; the `modelId` MUST equal [options].`model`-equivalent
  /// (router-resolved at submission); the `promptHash` MUST be the
  /// content hash of [prompt].[WirePrompt.body]. These fields are
  /// the trail's only way to attribute a call without storing the
  /// prompt text itself.
  Future<LlmCallReport> complete(WirePrompt prompt, LlmOptions options);

  /// Streams the prompt's completion.
  ///
  /// Returned stream lifecycle (spec § 3.1 + § 4.3):
  ///
  ///   1. Exactly one [LlmStreamStarted] is emitted first.
  ///   2. Zero or more [LlmStreamChunk] events follow, in order.
  ///   3. Zero or more [LlmStreamToolCallProposed] events may be
  ///      interleaved with chunks. After emitting a tool-call event
  ///      the provider pauses until the dispatcher posts a tool
  ///      result back through the (Phase D) tool-result channel.
  ///   4. The stream terminates with exactly one of
  ///      [LlmStreamCompleted] or [LlmStreamFailed].
  ///
  /// **Non-streaming backends.** Per spec § 4.3, a provider whose
  /// backend has no streaming API MUST still implement
  /// [completeStream] by buffering the final response and emitting
  /// it as a single [LlmStreamChunk] followed by
  /// [LlmStreamCompleted]. Consumers cannot distinguish a
  /// non-streaming provider from one that simply chose to emit one
  /// large chunk — and that is the point. The router's choice of
  /// whether to expose a provider for SSE forwarding is policy
  /// (B.18+), not a provider-side capability flag.
  ///
  /// **Anchor + provenance.** Same invariants as [complete]: the
  /// [LlmStreamCompleted.report] (and [LlmStreamFailed.report]) MUST
  /// carry the prompt's anchor hash, this provider's [id], the
  /// resolved model id, and the prompt body hash.
  Stream<LlmStreamEvent> completeStream(WirePrompt prompt, LlmOptions options);

  // ─── Deferred surface ────────────────────────────────────────
  //
  // Spec § 4.1 also names:
  //
  //   - Future<EmbeddingResult> embed(String text);
  //   - Future<List<EmbeddingResult>> embedBatch(List<String> texts);
  //   - Future<HealthSnapshot> health();
  //
  // These lands in subsequent steps so each one is paired with the
  // consumer that needs it:
  //
  //   - `embed` / `embedBatch` — B.25 / B.26 (embedding service +
  //     identity reporting). Adding them here at B.11 would force
  //     stub implementations across providers before the embedding
  //     surface exists.
  //   - `health` — B.18 (router cooldown logic). `HealthSnapshot` is
  //     a router-layer type; defining it here would invert the
  //     dependency.
  //
  // The conformance suite (B.17) tests the post-B.11 surface; the
  // suite grows by step as members land.
}
