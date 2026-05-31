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
//   * `EmbeddingProbeResult` — return type of
//     `EmbeddingService.probeIdentity()`; bundles the validated
//     current identity, the probe vector, and the optional
//     `EmbeddingIdentityChanged` event the probe produces on drift.
//
// What this barrel does NOT export:
//
//   * `EmbeddingResult` / `EmbeddingModelIdentity` — value types
//     used by both the embedding service and its consumers. They
//     live under `lib/src/api/embedding_result.dart` and ship
//     through the `api/` barrel (consumer-facing surface).
//   * `EmbeddingIdentityChanged` — the substrate event the probe
//     produces. Lives under `lib/src/api/substrate_event.dart` and
//     ships through the `api/` barrel.
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
//   * B.27 ✅ — `EmbeddingService.probeIdentity()` + `EmbeddingProbeResult`.
//     Boot-time round-trip that surfaces dim / empty-vector defects
//     via the same `embed()` path AND produces an
//     `EmbeddingIdentityChanged` event on identity drift relative
//     to a caller-supplied `previousIdentity` (typically the
//     identity memory persisted from the last service instance).
//     Memory consumes the event by stamping the new identity on
//     subsequent vector rows; old vectors keep their old identity
//     so cross-model vectors are never silently mixed in cosine
//     math (`memory_specification.md` § 7.4).
//   * B.28 — Conformance tests across implementations.

export 'embedding_probe_result.dart';
export 'embedding_service.dart';
export 'ollama_embedding_service.dart';
