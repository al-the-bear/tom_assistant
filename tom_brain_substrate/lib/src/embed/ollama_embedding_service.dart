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
//     service instance. B.27 added a boot-time probe
//     ([probeIdentity]) that surfaces an `EmbeddingIdentityChanged`
//     event when the new instance's identity differs from the last
//     one memory stored, but the identity itself is still
//     constructor-bound.
//   - Validate the configured dimension against the backend's
//     advertised dimension at construction time. Ollama's
//     `/api/embeddings` does not expose per-model dims through
//     `/api/tags`; the only way to learn the true dimension is to
//     do an embedding call. B.27's [probeIdentity] is the
//     boot-time round-trip: it calls `embed(probeText)` and lets
//     the existing `embed()` dim check surface
//     `EmbeddingDimensionMismatch` before the first real call
//     corrupts memory's vector index.
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
import '../api/substrate_event.dart' show EmbeddingIdentityChanged;
import '../llm/ollama_llm_provider.dart';
import 'embedding_probe_result.dart';
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
///   // Optional: tune the embedBatch fan-out cap. Default 4 matches
///   // substrate_specification.md § 7.3.
///   batchConcurrency: 4,
/// );
/// final result = await embed.embed('the quick brown fox');
/// // result.vec.dimension == 768
/// // result.modelIdentity.providerId == 'ollama:local'
/// // result.modelIdentity.modelId == 'nomic-embed-text'
/// // result.modelIdentity.normalized == true
///
/// final batch = await embed.embedBatch(['alpha', 'bravo', 'charlie']);
/// // batch.length == 3, batch[i] == embed(texts[i]) under same identity.
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

  /// Worker-pool size for [embedBatch] fan-out.
  ///
  /// Per `substrate_specification.md` § 7.3, the default is 4. A
  /// larger value increases the daemon's per-call load (every worker
  /// holds one open HTTP connection at a time); a smaller value
  /// increases the wall-clock for large batches.
  ///
  /// The effective worker count for any given batch is
  /// `min(batchConcurrency, texts.length)` — there is no benefit to
  /// spinning up more workers than there are inputs.
  final int batchConcurrency;

  /// Clock seam for tests. Used by [probeIdentity] to stamp
  /// `occurredAt` on the emitted [EmbeddingIdentityChanged] event.
  /// Defaults to `DateTime.now` (UTC normalisation happens inside
  /// `BrainEvent`'s constructor). Test code injects a fixed function
  /// so probe-event timestamps are reproducible.
  ///
  /// Kept as a function-typed field rather than a `Clock` interface
  /// to match the existing substrate convention (`LlmRouter` exposes
  /// the same shape). The cost of the shared convention is one
  /// allocation-per-call of `DateTime`; the benefit is a single
  /// substrate-wide rule for time injection.
  final DateTime Function() now;

  OllamaEmbeddingService({
    required this.provider,
    required this.model,
    required int dims,
    required bool normalize,
    this.batchConcurrency = 4,
    DateTime Function()? now,
  })  : _identity = EmbeddingModelIdentity(
          providerId: provider.id,
          modelId: model,
          dims: dims,
          normalized: normalize,
        ),
        _normalize = normalize,
        now = now ?? DateTime.now {
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
    if (batchConcurrency <= 0) {
      throw ArgumentError.value(
        batchConcurrency,
        'batchConcurrency',
        'OllamaEmbeddingService.batchConcurrency must be > 0',
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
  Future<List<EmbeddingResult>> embedBatch(List<String> texts) async {
    // Empty fast-path. Returning a const empty list keeps the contract
    // ("results.length == texts.length") trivially satisfied without
    // spinning up workers or touching the backend.
    if (texts.isEmpty) return const <EmbeddingResult>[];

    // Pre-size the result list so workers can write in any order
    // without resizing. Holding nullable slots until the worker fills
    // them lets `List.unmodifiable` at the end produce a tightly
    // typed `List<EmbeddingResult>` view for callers.
    final results = List<EmbeddingResult?>.filled(
      texts.length,
      null,
      growable: false,
    );

    // Shared cursor. Workers atomically pick the next index by
    // post-incrementing this value. Atomicity is free in Dart's
    // single-threaded event loop: the `nextIndex++` expression
    // completes before any `await` runs, so two workers can never
    // see the same value.
    var nextIndex = 0;

    // Pool size is bounded by both the constructor knob and the
    // input length — spinning up a worker per input is fine for
    // small batches, and a worker that never picks up an index would
    // be wasted overhead.
    final workerCount = math.min(batchConcurrency, texts.length);

    Future<void> worker() async {
      while (true) {
        final i = nextIndex++;
        if (i >= texts.length) return;
        // Per-input failure (EmbeddingDimensionMismatch /
        // EmbeddingBackendEmpty / transport exception) flows out of
        // the worker; Future.wait(eagerError: true) surfaces it on
        // the batch future and stops dispatching new work. Other
        // in-flight workers run to completion (no embedRaw-side
        // cancellation yet), but their results are discarded.
        results[i] = await embed(texts[i]);
      }
    }

    await Future.wait(
      List<Future<void>>.generate(
        workerCount,
        (_) => worker(),
        growable: false,
      ),
      eagerError: true,
    );

    // Every slot is now populated (Future.wait would have surfaced
    // any failure before we got here). Cast through a fresh list so
    // the public surface gets a non-nullable element type without
    // exposing the mutable storage to the caller.
    return List<EmbeddingResult>.unmodifiable(
      results.map((r) => r!),
    );
  }

  @override
  Future<EmbeddingProbeResult> probeIdentity({
    EmbeddingModelIdentity? previousIdentity,
    String probeText = 'tom-brain embedding probe',
  }) async {
    // The probe IS an embed call: it exercises the same wire path,
    // the same dim check, the same empty-vector check. A divergent
    // probe path would risk masking failures the real path would
    // hit (e.g. a probe that bypassed normalisation would not catch
    // a backend whose post-normalisation dim differed from the
    // pre-normalisation dim). Reusing `embed()` keeps the failure
    // surface identical between probe and steady-state.
    final probeResult = await embed(probeText);

    // Drift detection: structural equality on
    // `(providerId, modelId, dims, normalized)`. `EmbeddingModelIdentity`
    // overrides `==` to compare all four fields, so two identities
    // produced by separate service instances with the same
    // configuration compare equal even though they are not
    // `identical`. The drift event is built only when the caller
    // supplied a `previousIdentity` AND it differs from the current
    // one — first-boot (`previousIdentity == null`) and unchanged
    // restart (`previousIdentity == _identity`) both return
    // `driftEvent: null`.
    EmbeddingIdentityChanged? driftEvent;
    if (previousIdentity != null && previousIdentity != _identity) {
      driftEvent = EmbeddingIdentityChanged(
        occurredAt: now(),
        fromIdentity: previousIdentity,
        toIdentity: _identity,
      );
    }

    return EmbeddingProbeResult(
      currentIdentity: _identity,
      probeResult: probeResult,
      driftEvent: driftEvent,
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
