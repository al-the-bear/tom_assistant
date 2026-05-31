// Barrel for the `llm/` module — the *provider-layer* surface of the
// substrate (B.11 / substrate_specification.md § 4).
//
// Module surface:
//
//   * `WirePrompt` — the post-role-assembly, post-anchor-injection
//     prompt that providers consume. Produced only by the role
//     registry (B.21+ `lib/src/roles/`). Carries `body`,
//     `anchorHash`, `roleId`, optional `templateSha`.
//   * `LlmProvider` — abstract interface every provider implements.
//     At B.11 the surface is `String get id`, `complete(...)`,
//     `completeStream(...)`. Embedding (`embed`, `embedBatch`) lands
//     at B.25/26 in the same change that ships the embedding
//     service. Health (`health()`) lands at B.18 in the same change
//     that ships the router.
//
// Why this barrel is re-exported from the top-level package barrel
// (and not hidden behind a `lib/src/` deep import):
//
//   * Tests (`test/b11_llm_provider_contract_test.dart`) need to
//     `implement LlmProvider` to construct dummy / fake providers,
//     and the dart lints/recommended rule forbids
//     `package:tom_brain_substrate/src/...` self-imports.
//   * The `mcp_client_barrel.dart` pattern (B.8) is the precedent:
//     each subfolder owns its own barrel; the top-level package
//     barrel re-exports each subfolder's barrel; the api/ barrel
//     and the subfolder barrels stay independent.
//
// Why this barrel does NOT pull in api/ types:
//
//   * `LlmProvider.complete` and `completeStream` reference
//     `LlmCallReport`, `LlmOptions`, and `LlmStreamEvent` — those
//     live in api/ (B.9). Importing the api/ barrel here would
//     create a (harmless but noisy) circular re-export. The
//     llm_provider.dart implementation file imports api/ types
//     directly via relative paths.
//
// What this barrel does NOT export:
//
//   * The router or failure classifier — those live under
//     `lib/src/router/` (B.18+) with their own barrel.
//   * The role registry — lives under `lib/src/roles/` (B.21+) with
//     its own barrel. The roles surface is the only producer of
//     `WirePrompt`; everything else (substrate-internal or test)
//     consumes the type.
//
// What this barrel adds at B.14:
//
//   * `OllamaLlmProvider` — first concrete provider against Ollama's
//     `/api/chat` (non-streaming + streaming) on top of the
//     [OllamaHttpClient] wire-shape seam.
//   * `OllamaHttpClient` (interface) + `DefaultOllamaHttpClient`
//     (production impl) — the testable wire seam. Exported so test
//     fakes and the (future) router-layer cancellable variant can
//     bind against the contract without a `package:foo/src/...`
//     deep-import.
//   * The Ollama-side value classes (`OllamaMessage`,
//     `OllamaGenerationOptions`, `OllamaChatResponse`,
//     `OllamaStreamFragment`, `OllamaTagEntry`) and the
//     `OllamaHttpException` thrown by the production transport.
//
// What this barrel adds at B.15:
//
//   * `OpenAiPassthroughProvider` — second concrete provider against
//     any OpenAI-format Chat Completions endpoint (OpenAI itself,
//     OpenRouter, Groq, Cerebras, SambaNova, …) on top of the
//     [OpenAiHttpClient] wire-shape seam. Carries bearer-token auth +
//     extra-headers plumbing and exposes off-interface helpers
//     `embedRaw`, `embedBatchRaw`, `listAvailableModels` for the
//     embedding service (B.25 / B.26) and router (B.18+) to consume.
//   * `OpenAiHttpClient` (interface) + `DefaultOpenAiHttpClient`
//     (production impl) — the testable wire seam.
//   * The OpenAI-side value classes (`OpenAiMessage`,
//     `OpenAiGenerationOptions`, `OpenAiChatResponse`,
//     `OpenAiStreamFragment`, `OpenAiEmbeddingResponse`,
//     `OpenAiModelEntry`) and the `OpenAiHttpException` thrown by
//     the production transport.
//
// What this barrel adds at B.16:
//
//   * `StubLlmProvider` — third concrete provider. Deterministic,
//     in-process, NO network. Drives the LLM-free conformance test
//     on memory (`memory_specification.md` § 1 invariant 2) plus
//     every downstream module's test suite (router, embedding
//     service, dispatcher, access). Three response-generation modes
//     (scripted queue, custom responder callback, default echo) with
//     `StubLlmProvider.alwaysFails` factory for the failure path.
//   * The associated typedefs (`StubResponder`, `StubChunkSplitter`)
//     and the helper splitters (`StubLlmProvider.singleChunk`,
//     `StubLlmProvider.splitByWord`) so tests can compose multi-chunk
//     stream shapes without redefining boilerplate.

// What this barrel adds at B.23:
//
//   * `AnchorRegistry` — substrate-side accounting of the assistant-
//     dedication anchor (the shared layer carries the text; the
//     substrate computes the sha256 because A.9 forbids
//     `package:crypto` at the shared-types layer). Static-only
//     surface: `currentHash` (`sha256:<lowercase-hex>` of
//     `AssistantDedicationAnchor.text`), `currentVersion`,
//     `isCurrent(candidate)`.
//   * `AnchorViolation` — typed exception the substrate raises when
//     an outbound report's `anchorHash` does not equal
//     `AnchorRegistry.currentHash`. Spec § 12 fatal event. The
//     runtime hook lands at the `TomBrainSubstrate` facade (B.40);
//     B.46 conformance test exercises every emitted report against
//     the registry.

export 'anchor_registry.dart';
export 'llm_provider.dart';
export 'ollama_http_client.dart';
export 'ollama_llm_provider.dart';
export 'openai_http_client.dart';
export 'openai_passthrough_provider.dart';
export 'stub_llm_provider.dart';
export 'wire_prompt.dart';
