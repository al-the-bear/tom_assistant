// B.25 — `OllamaEmbeddingService`.
//
// First concrete [EmbeddingService] implementation. Talks Ollama's
// `/api/embeddings` through [OllamaLlmProvider.embedRaw] (which in
// turn delegates to the [OllamaHttpClient] wire seam from B.14).
//
// Why compose over the *provider* (and not the HTTP client directly):
//
//   - The provider already owns the resolved `(baseUri, defaultModel,
//     requestTimeout)` triple for the Ollama backend; binding through
//     it keeps the substrate from carrying two parallel "where does
//     Ollama live" configurations.
//   - The router-side circuit-breaker / health policy at B.18 wraps
//     the provider; an embedding call that goes through the provider
//     participates in the same backend-availability bookkeeping as
//     chat calls. (Today the embedding path is direct; the wrapping
//     lands at the router-aware step. The composition shape is set
//     here so that lands as a constructor swap, not a rewrite.)
//   - `OllamaLlmProvider` is already documented at B.14 as exposing
//     `embedRaw` "so the embedding service can bind against it in
//     the same change that grows the interface" — this step honours
//     that staged-handoff plan.
//
// What this implementation deliberately does NOT do:
//
//   - Hot-swap the model identity. The identity is fixed at
//     construction; a substrate-side model change requires a new
//     service instance. B.27 will add a boot-time probe that
//     surfaces an `EmbeddingIdentityChanged` event when the new
//     instance's identity differs from the last one memory stored,
//     but the identity itself is still constructor-bound.
//   - Fan out [embedBatch]. Per the interface contract, this lands
//     at B.26. Until then, [embedBatch] throws `UnimplementedError`
//     so the contract failure is loud rather than a slow concurrent
//     loop that obscures the surface gap.
//   - Validate the configured dimension against the backend's
//     advertised dimension. Ollama's `/api/embeddings` does not
//     expose per-model dims through `/api/tags`; the only way to
//     learn the true dimension is to do an embedding call. B.27's
//     boot-time probe will round-trip a fixed string and assert
//     `actualDims == expectedIdentity.dims`; today the first real
//     `embed()` call's dimension check serves the same role.
//   - Cache embeddings. Per-text caching for the inbound classifier
//     is plan step E.34, owned by the access layer, not by the
//     substrate. Caching at this layer would mix per-call freshness
//     and per-text identity in a way that complicates memory's
//     drift detection.
//   - Apply a request-level timeout. Inherits the provider's
//     `requestTimeout`. The embedding path is a single short HTTP
//     round-trip; a separate timeout knob would just shadow the
//     provider's.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:tom_brain_shared/tom_brain_shared.dart' show Vec;

import '../api/embedding_result.dart';
import '../llm/ollama_llm_provider.dart';
import 'embedding_service.dart';

/// `EmbeddingService` backed by Ollama's `/api/embeddings` endpoint.
///
/// Default backend for the prototype per
/// `substrate_specification.md` § 7.2 (`nomic-embed-text`, 768 dims,
/// L2-normalised).
///
/// Construction:
///
/// ```dart
/// final provider = OllamaLlmProvider(
///   id: 'ollama:local',
///   baseUri: Uri.parse('http://127.0.0.1:11434/'),
///   defaultModel: 'gemma3:27b',
/// );
/// final embed = OllamaEmbeddingService(
///   provider: provider,
///   model: 'nomic-embed-text',
///   dims: 768,
///   normalize: true,
/// );
/// final result = await embed.embed('the quick brown fox');
/// // result.vec.dimension == 768
/// // result.modelIdentity.providerId == 'ollama:local'
/// // result.modelIdentity.modelId == 'nomic-embed-text'
/// // result.modelIdentity.normalized == true
/// ```
///
/// The service does not own [provider]'s lifetime — [close] does not
/// close the provider. The substrate facade (B.40+) owns both and
/// closes them in the correct order.
final class OllamaEmbeddingService implements EmbeddingService {
  /// The Ollama provider that exposes `/api/embeddings` through its
  /// `embedRaw` helper. Owned by the substrate facade, not by this
  /// service.
  final OllamaLlmProvider provider;

  /// The Ollama model id to send on every request (e.g.
  /// `nomic-embed-text`). Distinct from the provider's
  /// `defaultModel` — the chat default and the embedding model are
  /// independent.
  final String model;

  /// The substrate's commitment to the per-result identity. Built
  /// from the constructor arguments; immutable for the lifetime of
  /// the service.
  ///
  /// `providerId` echoes [provider]'s `id`; `modelId` echoes [model];
  /// `dims` and `normalized` are constructor arguments.
  final EmbeddingModelIdentity _identity;

  /// Whether to L2-normalise the backend's vector before returning.
  ///
  /// When `true`, the returned vector has L2 norm equal to 1 within
  /// float32 rounding. When `false`, the backend's raw vector flows
  /// through unmodified.
  ///
  /// Kept as a separate field rather than read off [_identity] so
  /// the normalisation pass does not have to touch the identity
  /// object on every call.
  final bool _normalize;

  OllamaEmbeddingService({
    required this.provider,
    required this.model,
    required int dims,
    required bool normalize,
  })  : _identity = EmbeddingModelIdentity(
          providerId: provider.id,
          modelId: model,
          dims: dims,
          normalized: normalize,
        ),
        _normalize = normalize {
    if (dims <= 0) {
      throw ArgumentError.value(
        dims,
        'dims',
        'OllamaEmbeddingService.dims must be > 0',
      );
    }
    if (model.isEmpty) {
      throw ArgumentError.value(
        model,
        'model',
        'OllamaEmbeddingService.model must be non-empty',
      );
    }
  }

  @override
  EmbeddingModelIdentity get currentModelIdentity => _identity;

  @override
  Future<EmbeddingResult> embed(String text) async {
    // Note: we do NOT validate empty / whitespace input here. Some
    // models accept the empty string and return a "neutral" vector;
    // others reject it. The boundary belongs to the backend, not the
    // substrate — surfacing the backend's decision verbatim keeps
    // the contract minimal.
    final raw = await provider.embedRaw(prompt: text, model: model);

    if (raw.isEmpty) {
      throw EmbeddingBackendEmpty(
        expectedIdentity: _identity,
        inputPreview: _previewOf(text),
      );
    }

    if (raw.length != _identity.dims) {
      throw EmbeddingDimensionMismatch(
        expectedIdentity: _identity,
        actualDims: raw.length,
        inputPreview: _previewOf(text),
      );
    }

    // Materialise into a Float32List up-front so the (optional)
    // normalisation pass operates in float32 from the start. Doing
    // it in two steps (List<double> → normalise → Float32List) would
    // make a transient large allocation on high-dimensional vectors.
    final values = Float32List(raw.length);
    for (var i = 0; i < raw.length; i++) {
      values[i] = raw[i];
    }

    if (_normalize) {
      _l2NormaliseInPlace(values);
    }

    return EmbeddingResult(
      vec: Vec(values),
      modelIdentity: _identity,
    );
  }

  @override
  Future<List<EmbeddingResult>> embedBatch(List<String> texts) {
    // Per spec § 7.3, batching is preferred when the backend supports
    // it; Ollama's `/api/embeddings` accepts one input per call, so
    // the prototype's batching is concurrency-capped fan-out. That
    // pass lands at B.26. Until then this surface throws so callers
    // see the contract failure loudly rather than silently get a
    // partial / serial loop.
    throw UnimplementedError(
      'EmbeddingService.embedBatch — deferred to B.26. '
      'Batching for the Ollama backend is concurrency-capped fan-out '
      'over single-input `/api/embeddings` calls; the prototype '
      'implementation is owed at B.26 with the configurable '
      'concurrency cap (default 4) per substrate_specification.md '
      '§ 7.3. Callers needing per-text embeddings at B.25 should '
      'invoke `embed()` in a loop until B.26 lands.',
    );
  }

  @override
  Future<void> close() async {
    // No resources owned by the embedding service itself — the HTTP
    // client lives on [provider] and is closed by whoever owns it
    // (substrate facade at B.40+).
  }

  /// L2-normalises [values] in place. After the call, `Σ vᵢ² == 1`
  /// within float32 rounding error.
  ///
  /// Defensive on the zero-vector input: a zero vector cannot be
  /// normalised (division by zero); the method leaves it alone
  /// rather than producing NaNs. A zero-vector embedding is itself
  /// a backend defect (semantically "no signal"), but propagating
  /// NaNs would corrupt every downstream cosine call. The cosine
  /// invariant declared on [EmbeddingModelIdentity] is then "the
  /// returned vector has L2 norm ≤ 1, equal to 1 except for the
  /// zero-vector edge case" — which is the strongest property the
  /// substrate can promise without lying about the backend.
  static void _l2NormaliseInPlace(Float32List values) {
    var sumSq = 0.0;
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      sumSq += v * v;
    }
    if (sumSq == 0.0) return; // zero vector; leave alone.
    // sqrt in double, then narrow at the per-element divide so the
    // accumulated error stays at the float32 rounding bound rather
    // than the float32 multiply-add chain bound.
    final invNorm = 1.0 / math.sqrt(sumSq);
    for (var i = 0; i < values.length; i++) {
      values[i] = values[i] * invNorm;
    }
  }

  /// Truncates [text] for inclusion in exception messages. Keeps
  /// stack-trace lines readable when the input is a multi-page
  /// document.
  static String _previewOf(String text) {
    const limit = 64;
    if (text.length <= limit) return text;
    return '${text.substring(0, limit)}…';
  }
}
