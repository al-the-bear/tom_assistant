// Barrel for the `embed/` module — the substrate's embedding service
// (B.25–B.28 / substrate_specification.md § 7).
//
// Module surface:
//
//   * `EmbeddingService` — abstract contract every consumer
//     (chiefly `tom_brain_memory`) binds against.
//   * `OllamaEmbeddingService` — prototype default backend, talks
//     `nomic-embed-text` through `OllamaLlmProvider.embedRaw`.
//   * `EmbeddingDimensionMismatch`, `EmbeddingBackendEmpty` — typed
//     boundary failures the prototype surfaces from `embed()`.
//
// What this barrel does NOT export:
//
//   * `EmbeddingResult` / `EmbeddingModelIdentity` — value types
//     used by both the embedding service and its consumers. They
//     live under `lib/src/api/embedding_result.dart` and ship
//     through the `api/` barrel (consumer-facing surface).
//   * The Ollama wire seam (`OllamaHttpClient`,
//     `OllamaLlmProvider.embedRaw`). Lives under `lib/src/llm/` and
//     is exposed only as the substrate's provider-layer surface.
//
// Phase B build order for `embed/`:
//
//   * B.25 ✅ — `EmbeddingService.embed(text)` +
//     `currentModelIdentity` (this barrel).
//   * B.26 ✅ — `EmbeddingService.embedBatch(texts)` with
//     concurrency-capped fan-out (default cap 4 per
//     `substrate_specification.md` § 7.3). Tunable per service
//     instance via the `batchConcurrency` constructor argument.
//   * B.27 — Identity reporting / boot-time identity probe / event
//     emission on identity drift.
//   * B.28 — Conformance tests across implementations.

export 'embedding_service.dart';
export 'ollama_embedding_service.dart';
