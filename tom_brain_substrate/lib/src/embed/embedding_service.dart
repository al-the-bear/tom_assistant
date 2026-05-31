// B.25 — `EmbeddingService` abstract interface.
//
// substrate_specification.md § 7.1 defines the surface:
//
// ```dart
// Future<EmbeddingResult> embed(String text);
// Future<List<EmbeddingResult>> embedBatch(List<String> texts);
// EmbeddingModelIdentity get currentModelIdentity;
// ```
//
// This file lands the contract; `OllamaEmbeddingService`
// (`ollama_embedding_service.dart`) lands the prototype implementation
// behind it. Memory (Phase A) and the inbound-classification path in
// Phase E both consume this surface — not the provider helper
// (`OllamaLlmProvider.embedRaw`) directly — so a future second backend
// (OpenAI passthrough, on-device model) is a constructor swap.
//
// Step boundaries:
//
//   * B.25 — `embed(text)` + `currentModelIdentity` (this step).
//     The identity getter is "free" at B.25 because every
//     `EmbeddingResult` returned by `embed` already carries the
//     identity stamp; exposing it as a separate getter on the service
//     surfaces the substrate's commitment without an extra call.
//   * B.26 ✅ — `embedBatch(texts)` with concurrency-capped fan-out
//     (default cap 4, per `substrate_specification.md` § 7.3).
//     Ollama's `/api/embeddings` accepts one input per call, so the
//     prototype's batching shape is a worker-pool that picks indices
//     off a shared counter and dispatches `embed()` calls — order in
//     the returned list matches input order regardless of completion
//     order. The first failure short-circuits the batch via
//     `Future.wait(eagerError: true)`; in-flight calls run to
//     completion (no `embedRaw`-side cancellation yet), but no new
//     dispatch happens after the failure surfaces.
//   * B.27 ✅ — Identity reporting: `probeIdentity()` plus
//     `EmbeddingIdentityChanged` event production. The probe is the
//     boot-time validator (dim / empty-vector check on a fixed
//     probe text) and the drift detector (compares
//     `currentModelIdentity` to a caller-supplied `previousIdentity`,
//     returning a non-null event on mismatch). Memory invokes the
//     probe at `TomBrainMemory.open` with the identity it persisted
//     from the last service instance; the substrate facade (B.40+)
//     forwards the produced event onto `events()`.
//   * B.28 — Conformance tests covering both implementations.

import '../api/embedding_result.dart';
import 'embedding_probe_result.dart';

/// Embedding-substrate contract.
///
/// One implementation per backend (Ollama at B.25, OpenAI passthrough
/// at a later step). The substrate facade (B.40+) holds exactly one
/// concrete instance; consumers depend on this abstract surface only.
///
/// **Identity invariant.** Every [EmbeddingResult] returned by
/// [embed] / [embedBatch] carries the same [EmbeddingModelIdentity]
/// that [currentModelIdentity] reports at the time of the call.
/// Memory uses the identity to mark per-vector rows so cross-model
/// vectors are never silently mixed in cosine math
/// (`memory_specification.md` § 7.4).
///
/// **Identity stability.** [currentModelIdentity] is stable across
/// the lifetime of a single service instance. A substrate-side model
/// change (operator swaps `nomic-embed-text` for a different model,
/// or rotates to a different provider) requires constructing a new
/// service instance — the prototype does not hot-swap identities
/// inside a running service. B.27 will add a startup probe that
/// surfaces an `EmbeddingIdentityChanged` event when the new
/// instance's identity differs from the last one memory stored.
abstract class EmbeddingService {
  /// Produces an embedding for [text] under the configured model.
  ///
  /// Returns the vector plus the model identity that produced it.
  /// The vector's dimension equals [currentModelIdentity].`dims`;
  /// implementations MUST throw [EmbeddingDimensionMismatch] when the
  /// backend returns a vector with a different dimension (a backend
  /// behaviour change that would silently corrupt memory).
  ///
  /// Implementations MAY normalise the returned vector to unit norm.
  /// The normalisation choice is reported on
  /// [currentModelIdentity].`normalized` — a `true` value means the
  /// returned vector has L2 norm equal to 1 (within float32
  /// rounding); `false` means the substrate returns the backend's
  /// raw vector as-is. Memory stamps the flag alongside the vector
  /// so a cosine consumer never has to second-guess.
  ///
  /// Implementations MUST surface transport / backend failures as
  /// exceptions (the prototype does not wrap them into typed
  /// `LlmFailure`s — that lives at the router; this surface is for
  /// callers who want the raw signal). The router-level retry /
  /// rotation policy will wrap this surface in a later step.
  Future<EmbeddingResult> embed(String text);

  /// Batched embedding. Returns one [EmbeddingResult] per input, in
  /// input order.
  ///
  /// Defers to the implementation's batching strategy (single HTTP
  /// round-trip when the backend supports it; bounded concurrent
  /// fan-out otherwise). Every returned result carries the same
  /// identity as [currentModelIdentity] at call time.
  ///
  /// **Empty input.** An empty [texts] list returns an empty result
  /// list immediately; no backend calls are dispatched.
  ///
  /// **Order preservation.** The returned list has
  /// `results.length == texts.length` and `results[i]` is the
  /// embedding of `texts[i]`, regardless of the order in which the
  /// underlying calls completed. Consumers can zip the two lists
  /// without re-sorting.
  ///
  /// **Failure semantics.** If the underlying backend surfaces a
  /// failure on any input (boundary failure from [embed] —
  /// [EmbeddingDimensionMismatch] / [EmbeddingBackendEmpty] — or a
  /// transport exception), the future completes with that error.
  /// In-flight backend calls for other indices run to completion (no
  /// cancellation token on the prototype's wire path), but their
  /// results are discarded and no further dispatch happens after the
  /// failure surfaces. Whether the surfaced error corresponds to the
  /// first input by index or the first to complete is implementation-
  /// defined; consumers should treat batch failure as "one or more
  /// inputs failed" and retry the batch (or fall back to per-input
  /// [embed] for diagnostics).
  Future<List<EmbeddingResult>> embedBatch(List<String> texts);

  /// The model identity stamped on every result this service
  /// produces. Stable across the service instance's lifetime; see
  /// the class-level docs for the rationale.
  EmbeddingModelIdentity get currentModelIdentity;

  /// Boot-time identity probe. Round-trips [probeText] through the
  /// backend so the substrate can:
  ///
  ///   1. **Validate the backend dimension** matches the
  ///      constructor-declared [EmbeddingModelIdentity.dims]. A
  ///      silent backend-side model swap (Ollama re-pulled a tag and
  ///      got different weights with a different head; the operator
  ///      pointed `embedding.model` at a different model id) surfaces
  ///      as [EmbeddingDimensionMismatch] from this call, before the
  ///      first real `embed()` corrupts memory's vector index.
  ///   2. **Validate the backend is reachable and functional**.
  ///      Transport failures (`OllamaHttpException`) propagate
  ///      verbatim; the [EmbeddingBackendEmpty] case surfaces a
  ///      daemon-side refusal-to-embed.
  ///   3. **Detect identity drift** relative to a caller-supplied
  ///      [previousIdentity]. When the caller supplies the identity
  ///      memory persisted from the last service instance, the probe
  ///      compares it to [currentModelIdentity] (value equality on
  ///      `(providerId, modelId, dims, normalized)`) and, on
  ///      mismatch, populates [EmbeddingProbeResult.driftEvent] with
  ///      an [EmbeddingIdentityChanged] carrying `(from: previous,
  ///      to: current)`. Memory uses the event to stamp the new
  ///      identity on subsequent rows; old vectors keep their old
  ///      identity (`memory_specification.md` § 7.4 — cross-model
  ///      vectors are never silently mixed in cosine math).
  ///
  /// When [previousIdentity] is `null` the probe still runs the
  /// dimension / reachability checks but returns
  /// `driftEvent: null` — a first-time boot has nothing to compare
  /// against. When [previousIdentity] equals [currentModelIdentity]
  /// the probe also returns `driftEvent: null` (no drift).
  ///
  /// [probeText] defaults to a short, stable, deployment-independent
  /// string. The default is deliberately not the empty string —
  /// some backends refuse to embed empty input. A future
  /// drift-detection upgrade (Q-B.3.5) will additionally cosine-
  /// compare the probe vector to a persisted one under the same
  /// identity to catch silent weight swaps; the result's
  /// [EmbeddingProbeResult.probeResult] is the seed for that
  /// upgrade.
  ///
  /// **Failure semantics.** The probe surfaces the same boundary
  /// failures as `embed()`: [EmbeddingDimensionMismatch],
  /// [EmbeddingBackendEmpty], or any transport exception the
  /// backend raises. A failed probe is the substrate's loud signal
  /// that the embedding path is broken — callers should NOT proceed
  /// to use the service.
  Future<EmbeddingProbeResult> probeIdentity({
    EmbeddingModelIdentity? previousIdentity,
    String probeText = 'tom-brain embedding probe',
  });

  /// Releases any backend resources the service owns (e.g. the
  /// underlying HTTP client when this service constructed it).
  /// Idempotent — repeated calls are safe.
  Future<void> close();
}

/// Thrown by [EmbeddingService.embed] / [EmbeddingService.embedBatch]
/// when the backend returns a vector whose dimension does not match
/// the configured [EmbeddingModelIdentity.dims].
///
/// A dimension mismatch is the substrate's earliest signal that the
/// backend model has been silently swapped underneath (Ollama
/// re-pulled `nomic-embed-text` and got a different tokenizer / head;
/// the operator pointed `embedding.model` at a similar-but-not-equal
/// model id). Surfacing it as a typed exception lets memory abort
/// the write at boundary instead of corrupting the vector index.
///
/// The exception class is **not** a `LlmFailure` (spec § 5.4 is for
/// LLM-call failure classification only); the embedding surface
/// surfaces backend defects directly. The router-level retry layer
/// does not retry a dimension mismatch — it is a configuration /
/// deployment defect, not a transient transport failure.
final class EmbeddingDimensionMismatch implements Exception {
  /// The identity the substrate declared (and consumers stamped on
  /// existing memory rows).
  final EmbeddingModelIdentity expectedIdentity;

  /// The actual dimension the backend returned.
  final int actualDims;

  /// The (truncated) input text that produced the bad vector. Kept
  /// short for log readability; not used for equality.
  final String inputPreview;

  EmbeddingDimensionMismatch({
    required this.expectedIdentity,
    required this.actualDims,
    required this.inputPreview,
  });

  @override
  String toString() => 'EmbeddingDimensionMismatch: expected '
      '${expectedIdentity.dims} dims under ${expectedIdentity.providerId}/'
      '${expectedIdentity.modelId}, got $actualDims '
      '(input preview: "$inputPreview")';
}

/// Thrown by [EmbeddingService.embed] / [EmbeddingService.embedBatch]
/// when the backend returns an empty vector (no components at all).
///
/// Ollama's `/api/embeddings` returns `{embedding: []}` for inputs the
/// daemon refuses to embed (model not loaded, input rejected). The
/// prototype surfaces this as a typed exception rather than a
/// zero-length [EmbeddingResult] — cosine math on a zero-dimension
/// vector throws an `ArgumentError` from `tom_brain_shared.Vec`, and
/// a typed boundary failure is easier for callers to handle than a
/// downstream `ArgumentError`.
final class EmbeddingBackendEmpty implements Exception {
  /// The identity the substrate declared.
  final EmbeddingModelIdentity expectedIdentity;

  /// The (truncated) input text that produced the empty vector.
  final String inputPreview;

  EmbeddingBackendEmpty({
    required this.expectedIdentity,
    required this.inputPreview,
  });

  @override
  String toString() => 'EmbeddingBackendEmpty: ${expectedIdentity.providerId}/'
      '${expectedIdentity.modelId} returned an empty vector for input '
      '(preview: "$inputPreview")';
}
