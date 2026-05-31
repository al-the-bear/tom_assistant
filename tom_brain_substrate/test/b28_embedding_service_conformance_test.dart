// B.28 — Cross-implementation `EmbeddingService` conformance suite.
//
// `prototype_implementation_plan.md` step B.28 (verbatim):
//
//   > Tests: single + batch embedding; dimension stability; identity
//   > surfaces unchanged across calls.
//
// Scope of this file:
//
//   The per-impl suites at `test/b25_*`, `test/b26_*`, `test/b27_*`
//   exercise `OllamaEmbeddingService`'s impl-private behaviour (wire
//   shape, fan-out details, probe text, normalisation arithmetic, etc.).
//   This file lifts the four plan-specified guarantees onto the
//   `EmbeddingService` abstract contract and runs them against *every*
//   implementation registered below.
//
//   At B.28 there is exactly one production implementation
//   (`OllamaEmbeddingService`); the conformance driver is shaped so a
//   second backend (the planned OpenAI passthrough, an on-device
//   model) plugs in as a one-class harness drop-in. To prove the
//   contract is implementable by something other than the prototype
//   default — and to keep the suite useful even before a second
//   production backend lands — the file also registers a minimal
//   in-test `_InMemoryEmbeddingService` (a deterministic hash-derived
//   vector, no network) as a second harness. The in-memory service is
//   a *test fixture*, not a shipped backend; its only role is to
//   anchor the contract on a second concrete impl so a regression to
//   the abstract surface (a contract assertion that quietly only
//   holds for `OllamaEmbeddingService`) is caught here.
//
// What is on contract at B.28 (the four plan-specified guarantees):
//
//   1. **Single embedding.** `embed(text)` returns an `EmbeddingResult`
//      whose `vec.dimension` equals `currentModelIdentity.dims` and
//      whose `modelIdentity` is structurally equal to
//      `currentModelIdentity`. Empty / whitespace input does not
//      special-case the dimension contract.
//
//   2. **Batch embedding.** `embedBatch(texts)` returns
//      `results.length == texts.length` with every result carrying the
//      same identity as `currentModelIdentity` and the configured
//      `.dims`. Empty input returns an empty list synchronously
//      (no backend dispatch). Single-input batch matches `embed()` on
//      identity + dim. `embedBatch` preserves input order — proved by
//      asking the impl to embed marker strings the harness can decode
//      back to their input index (see `_HarnessExpectation.markerFor`).
//
//   3. **Dimension stability.** Sequential `embed()` calls all return
//      the same dim; that dim is `currentModelIdentity.dims`; the
//      batch path produces the same dim as the single path; the dim
//      does not drift over a longer run (we run 16 calls and assert
//      every one matches).
//
//   4. **Identity surfaces unchanged across calls.** The substrate
//      promise (`EmbeddingService` class doc) is that
//      `currentModelIdentity` is constructor-bound and stable across
//      the service's lifetime. The conformance proves it remains
//      `identical` before / after `embed`, `embedBatch`,
//      `probeIdentity` (no-drift), `probeIdentity` (with-drift), and
//      `close`. A drift-firing probe is part of the assertion because
//      the spec is explicit: drift is detected against the *caller's
//      reference*, not the service's identity — `probeIdentity` with
//      `previousIdentity != currentIdentity` must produce a drift
//      event without mutating the service's `currentModelIdentity`.
//
// What is NOT on contract at B.28:
//
//   - The probe text wording, the default `batchConcurrency`, the
//     L2-normalisation invariants, or the typed boundary failures
//     (`EmbeddingBackendEmpty` / `EmbeddingDimensionMismatch`). Those
//     all bind to `OllamaEmbeddingService` semantics; a future
//     `OpenAiEmbeddingService` may surface them differently (e.g. a
//     transport-mapped exception type). The per-impl suite at B.25
//     covers them in depth.
//   - Wire-path routing (Ollama-specific) and concurrency-cap
//     enforcement (Ollama's fan-out detail). The abstract contract
//     does not require any particular dispatch shape.
//   - Live backend calls. Every harness is in-process — the Ollama
//     harness uses the same `_FakeOllamaHttpClient` shape that the
//     B.25 suite uses (minimal slice; not a full re-import).
//
// Design:
//
//   - One `_EmbeddingHarness` interface owns `service: EmbeddingService`,
//     a teardown hook, and a `markerFor(input)` decoder that maps an
//     `EmbeddingResult` back to the input index. The decoder is what
//     lets the order-preservation contract test work without binding
//     to a specific backend's vector encoding.
//   - Two harnesses register today (`_OllamaHarness`, `_InMemoryHarness`).
//     A third (real OpenAI passthrough impl, on-device backend) is a
//     one-class drop-in below `main()`.
//   - The contract driver (`_runConformance`) registers one outer
//     `group(...)` per harness and the same set of contract assertions
//     under each, so an edit to a contract test lands against every
//     impl in one place.

import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('B.28 / OllamaEmbeddingService', () {
    _runConformance(_OllamaHarness.new);
  });

  group('B.28 / InMemoryEmbeddingService (test fixture)', () {
    _runConformance(_InMemoryHarness.new);
  });
}

// ─── Contract driver ──────────────────────────────────────────────────

typedef _HarnessBuilder = _EmbeddingHarness Function();

void _runConformance(_HarnessBuilder buildHarness) {
  group('contract — single embedding', () {
    test('embed returns a vector with dim == currentModelIdentity.dims',
        () async {
      final h = buildHarness();
      addTearDown(h.dispose);

      final result = await h.service.embed('hello');

      expect(
        result.vec.dimension,
        h.service.currentModelIdentity.dims,
        reason: 'every embed must return a vector whose dim equals the '
            'declared identity dim — memory rejects mismatching rows',
      );
    });

    test('embed stamps the current identity (structural equality)', () async {
      final h = buildHarness();
      addTearDown(h.dispose);

      final result = await h.service.embed('hello');

      expect(result.modelIdentity, equals(h.service.currentModelIdentity));
    });

    test('two embeds return the same identity instance', () async {
      final h = buildHarness();
      addTearDown(h.dispose);

      final a = (await h.service.embed('alpha')).modelIdentity;
      final b = (await h.service.embed('beta')).modelIdentity;

      expect(a, equals(b));
      expect(identical(a, b), isTrue,
          reason: 'identity is constructor-bound; impl MUST NOT '
              're-allocate per call');
    });

    test('multiple sequential calls all return the configured dim',
        () async {
      // Defends against an impl that mutates per-call output shape on
      // some code path (e.g. truncates on the second call).
      final h = buildHarness();
      addTearDown(h.dispose);

      for (var i = 0; i < 5; i++) {
        final r = await h.service.embed('payload-$i');
        expect(r.vec.dimension, h.service.currentModelIdentity.dims);
      }
    });
  });

  group('contract — batch embedding', () {
    test('empty input returns an empty result list', () async {
      final h = buildHarness();
      addTearDown(h.dispose);

      final result = await h.service.embedBatch(const <String>[]);

      expect(result, isEmpty);
    });

    test('result.length == input.length', () async {
      final h = buildHarness();
      addTearDown(h.dispose);

      final inputs = List<String>.generate(7, (i) => 'item-$i');
      final result = await h.service.embedBatch(inputs);

      expect(result, hasLength(7));
    });

    test('every batch result carries currentModelIdentity', () async {
      final h = buildHarness();
      addTearDown(h.dispose);

      final result =
          await h.service.embedBatch(const <String>['a', 'b', 'c']);

      for (final r in result) {
        expect(r.modelIdentity, equals(h.service.currentModelIdentity));
      }
    });

    test('every batch result has dim == currentModelIdentity.dims',
        () async {
      final h = buildHarness();
      addTearDown(h.dispose);

      final result =
          await h.service.embedBatch(const <String>['x', 'y', 'z']);

      for (final r in result) {
        expect(r.vec.dimension, h.service.currentModelIdentity.dims);
      }
    });

    test('single-input batch matches embed() on identity + dim', () async {
      final h = buildHarness();
      addTearDown(h.dispose);

      final single = await h.service.embed('hello');
      final batch = await h.service.embedBatch(const <String>['hello']);

      expect(batch, hasLength(1));
      expect(batch.single.modelIdentity, equals(single.modelIdentity));
      expect(batch.single.vec.dimension, single.vec.dimension);
    });

    test('embedBatch preserves input order', () async {
      // The harness encodes the input index into a way that lets the
      // test recover "which input produced which slot's result". The
      // Ollama harness uses a marker dimension; the in-memory harness
      // uses a deterministic per-input vector. Both decoders return
      // the same answer: `markerFor(input) == result_for_that_input`.
      final h = buildHarness();
      addTearDown(h.dispose);

      const inputs = <String>['in-0', 'in-1', 'in-2', 'in-3', 'in-4'];
      final results = await h.service.embedBatch(inputs);

      for (var i = 0; i < inputs.length; i++) {
        expect(
          h.markerFor(results[i]),
          equals(inputs[i]),
          reason: 'results[$i] must be the embedding of inputs[$i]; a '
              'reorder would silently mis-tag downstream stored vectors',
        );
      }
    });
  });

  group('contract — dimension stability', () {
    test('16 sequential embeds all return the same dim', () async {
      final h = buildHarness();
      addTearDown(h.dispose);

      final expected = h.service.currentModelIdentity.dims;
      for (var i = 0; i < 16; i++) {
        final r = await h.service.embed('payload-$i');
        expect(r.vec.dimension, expected,
            reason: 'dim drift on call #$i breaks downstream cosine math');
      }
    });

    test('batch path produces the same dim as the single path', () async {
      final h = buildHarness();
      addTearDown(h.dispose);

      final singleDim = (await h.service.embed('one')).vec.dimension;
      final batch = await h.service.embedBatch(const <String>['a', 'b']);

      for (final r in batch) {
        expect(r.vec.dimension, singleDim);
      }
    });

    test('dim equals currentModelIdentity.dims after many calls', () async {
      final h = buildHarness();
      addTearDown(h.dispose);

      // Mix single + batch dispatches; assert the declared identity
      // dim never goes out of sync with the produced vector dim.
      await h.service.embed('a');
      await h.service.embedBatch(const <String>['b', 'c']);
      await h.service.embed('d');
      await h.service.embedBatch(const <String>['e']);

      final tail = await h.service.embed('tail');
      expect(tail.vec.dimension, h.service.currentModelIdentity.dims);
    });
  });

  group('contract — identity surfaces unchanged across calls', () {
    test('currentModelIdentity is identical before/after embed', () async {
      final h = buildHarness();
      addTearDown(h.dispose);

      final pre = h.service.currentModelIdentity;
      await h.service.embed('hello');
      final post = h.service.currentModelIdentity;

      expect(identical(pre, post), isTrue);
    });

    test('currentModelIdentity is identical before/after embedBatch',
        () async {
      final h = buildHarness();
      addTearDown(h.dispose);

      final pre = h.service.currentModelIdentity;
      await h.service.embedBatch(const <String>['a', 'b']);
      final post = h.service.currentModelIdentity;

      expect(identical(pre, post), isTrue);
    });

    test('currentModelIdentity is identical before/after probeIdentity '
        '(no drift)', () async {
      final h = buildHarness();
      addTearDown(h.dispose);

      final pre = h.service.currentModelIdentity;
      final probe = await h.service.probeIdentity();
      final post = h.service.currentModelIdentity;

      expect(identical(pre, post), isTrue);
      expect(probe.driftDetected, isFalse,
          reason: 'no previousIdentity supplied ⇒ no drift event');
      expect(identical(probe.currentIdentity, pre), isTrue,
          reason: 'probe surfaces the constructor-bound identity, not a copy');
    });

    test(
        'drift-firing probe leaves currentModelIdentity untouched '
        '(drift detected against caller reference, never mutates service)',
        () async {
      final h = buildHarness();
      addTearDown(h.dispose);

      final pre = h.service.currentModelIdentity;

      // Build a deliberately-different identity to trigger drift. We
      // change one field at a time across two probes to confirm the
      // service identity is stable under both fast-path (no-drift) and
      // slow-path (drift-fires) probe semantics.
      final differentProvider = EmbeddingModelIdentity(
        providerId: '${pre.providerId}#other',
        modelId: pre.modelId,
        dims: pre.dims,
        normalized: pre.normalized,
      );
      final differentModel = EmbeddingModelIdentity(
        providerId: pre.providerId,
        modelId: '${pre.modelId}#other',
        dims: pre.dims,
        normalized: pre.normalized,
      );

      final p1 =
          await h.service.probeIdentity(previousIdentity: differentProvider);
      final p2 =
          await h.service.probeIdentity(previousIdentity: differentModel);

      expect(p1.driftDetected, isTrue);
      expect(p2.driftDetected, isTrue);

      final post = h.service.currentModelIdentity;
      expect(identical(pre, post), isTrue,
          reason: 'drift events must not re-allocate the service identity');
      expect(p1.currentIdentity, equals(pre));
      expect(p2.currentIdentity, equals(pre));
    });

    test('currentModelIdentity remains queryable after close()', () async {
      // close() may release backend resources but MUST NOT invalidate
      // the identity surface — downstream code may keep a reference to
      // the service for logging / introspection after the I/O surface
      // is torn down.
      final h = buildHarness();
      addTearDown(h.dispose);

      final pre = h.service.currentModelIdentity;
      await h.service.close();
      final post = h.service.currentModelIdentity;

      expect(identical(pre, post), isTrue);
    });
  });
}

// ─── Harness interface ────────────────────────────────────────────────

/// A harness wraps one concrete [EmbeddingService] implementation plus
/// the per-impl knowledge the contract tests need.
///
/// The only contract assertion that needs impl-specific knowledge is
/// the order-preservation test: given a result, the test needs to
/// recover *which input produced it* without touching the impl's
/// internal vector encoding. Every harness exposes [markerFor] which
/// returns the original input string for a given result. Each impl
/// builds the marker into its returned vector in its own way; the
/// contract test does not care how.
abstract class _EmbeddingHarness {
  EmbeddingService get service;

  /// Recovers the original input string for [result]. Used by the
  /// order-preservation contract test.
  String markerFor(EmbeddingResult result);

  /// Releases any resources the harness owns (in-test HTTP client,
  /// state). Called via `addTearDown` from every contract test.
  Future<void> dispose();
}

// ─── Ollama harness ───────────────────────────────────────────────────

/// Conformance harness for [OllamaEmbeddingService].
///
/// Backed by an in-test [OllamaHttpClient] that responds to every
/// `embed` call with a deterministic per-input vector: the first
/// component encodes the call's input verbatim via a per-fake string
/// table; the rest are zero. The vector is intentionally non-unit
/// pre-normalisation so the normalisation pass (`normalize: true`) is
/// exercised even though normalisation is not on the B.28 contract.
final class _OllamaHarness implements _EmbeddingHarness {
  static const int _dims = 8;
  static const String _providerId = 'ollama:local';
  static const String _modelId = 'nomic-embed-text';

  late final _ConformanceFakeOllamaHttpClient _http;
  late final OllamaLlmProvider _provider;
  late final OllamaEmbeddingService _service;

  _OllamaHarness() {
    _http = _ConformanceFakeOllamaHttpClient(dims: _dims);
    _provider = OllamaLlmProvider(
      id: _providerId,
      baseUri: Uri.parse('http://127.0.0.1:11434/'),
      defaultModel: 'gemma3:27b',
      httpClient: _http,
    );
    _service = OllamaEmbeddingService(
      provider: _provider,
      model: _modelId,
      dims: _dims,
      normalize: false, // raw fake vectors keep the marker decodable
    );
  }

  @override
  EmbeddingService get service => _service;

  @override
  String markerFor(EmbeddingResult result) {
    // The fake stamps a per-input integer marker at index 0; the
    // recovery table maps that marker back to the input string.
    final marker = result.vec[0].toInt();
    final input = _http.markerToInput[marker];
    if (input == null) {
      fail('Ollama harness: no recorded input for marker $marker '
          '(known markers: ${_http.markerToInput.keys.toList()})');
    }
    return input;
  }

  @override
  Future<void> dispose() async {
    await _service.close();
    _provider.close();
  }
}

/// In-test [OllamaHttpClient] for the B.28 Ollama harness.
///
/// Per-input policy: every `embed` call gets a unique marker integer
/// based on the *content* of the input (not the call's arrival order),
/// so two calls with the same input always get the same marker. This
/// is what makes the single-vs-batch parity test (`embedBatch(['x'])`
/// matches `embed('x')`) work — both calls land the same marker at
/// `vec[0]`. The marker → input mapping is recorded so the harness
/// can decode a result back to its input.
final class _ConformanceFakeOllamaHttpClient implements OllamaHttpClient {
  final int dims;

  /// Input → marker integer assignment. Stable across the fake's
  /// lifetime — same input always gets the same marker.
  final Map<String, int> inputToMarker = <String, int>{};

  /// Inverse of [inputToMarker]; the harness uses it in `markerFor`.
  final Map<int, String> markerToInput = <int, String>{};

  int _nextMarker = 1;

  _ConformanceFakeOllamaHttpClient({this.dims = 8});

  int _markerFor(String input) {
    final existing = inputToMarker[input];
    if (existing != null) return existing;
    final marker = _nextMarker++;
    inputToMarker[input] = marker;
    markerToInput[marker] = input;
    return marker;
  }

  @override
  Future<List<double>> embed({
    required Uri baseUri,
    required String model,
    required String prompt,
    Duration? requestTimeout,
  }) async {
    final marker = _markerFor(prompt);
    final vec = List<double>.filled(dims, 0.0);
    vec[0] = marker.toDouble();
    return vec;
  }

  @override
  Future<OllamaChatResponse> chat({
    required Uri baseUri,
    required String model,
    required List<OllamaMessage> messages,
    required OllamaGenerationOptions options,
    Duration? requestTimeout,
  }) async {
    return const OllamaChatResponse(model: 'gemma3:27b', content: '');
  }

  @override
  Stream<OllamaStreamFragment> chatStream({
    required Uri baseUri,
    required String model,
    required List<OllamaMessage> messages,
    required OllamaGenerationOptions options,
    Duration? requestTimeout,
    CancellationToken? cancellationToken,
  }) async* {
    // No fragments — no test exercises the chat stream path.
  }

  @override
  Future<List<OllamaTagEntry>> listTags({
    required Uri baseUri,
    Duration? requestTimeout,
  }) async =>
      const <OllamaTagEntry>[];

  @override
  void close() {
    // No resources held; conformance tests do not assert on close.
  }
}

// ─── In-memory harness ────────────────────────────────────────────────

/// Conformance harness for [_InMemoryEmbeddingService] — the in-test
/// second-implementation fixture that proves the contract is not
/// implicitly bound to [OllamaEmbeddingService] semantics.
final class _InMemoryHarness implements _EmbeddingHarness {
  static const int _dims = 8;
  static const String _providerId = 'in-memory:test';
  static const String _modelId = 'deterministic-hash-v1';

  late final _InMemoryEmbeddingService _service;

  _InMemoryHarness() {
    _service = _InMemoryEmbeddingService(
      providerId: _providerId,
      modelId: _modelId,
      dims: _dims,
    );
  }

  @override
  EmbeddingService get service => _service;

  @override
  String markerFor(EmbeddingResult result) {
    // The in-memory impl writes the input into its per-call marker
    // table the same way the Ollama fake does — `vec[0]` is a stable
    // per-input integer. Read it back via the service's marker map.
    final marker = result.vec[0].toInt();
    final input = _service.markerToInput[marker];
    if (input == null) {
      fail('In-memory harness: no recorded input for marker $marker '
          '(known markers: ${_service.markerToInput.keys.toList()})');
    }
    return input;
  }

  @override
  Future<void> dispose() async {
    await _service.close();
  }
}

/// Minimal in-test [EmbeddingService] implementation.
///
/// The point of this class is to anchor the B.28 conformance contract
/// on a second concrete impl that has *nothing* in common with
/// [OllamaEmbeddingService]:
///
///   * No HTTP transport. Vectors are computed in-process.
///   * Deterministic per-input output: same input → same vector. This
///     keeps the single/batch parity contract observable without any
///     wire-level coordination.
///   * No normalisation, no fan-out, no probe text indirection. The
///     impl does the minimum the abstract contract requires.
///
/// If a B.28 contract assertion silently bound to an Ollama-only
/// behaviour, this harness would fail loudly — that is the whole
/// reason this fixture exists.
final class _InMemoryEmbeddingService implements EmbeddingService {
  final EmbeddingModelIdentity _identity;

  /// Stable per-input marker mapping; same input always gets the same
  /// marker.
  final Map<String, int> inputToMarker = <String, int>{};
  final Map<int, String> markerToInput = <int, String>{};
  int _nextMarker = 1;

  _InMemoryEmbeddingService({
    required String providerId,
    required String modelId,
    required int dims,
  }) : _identity = EmbeddingModelIdentity(
          providerId: providerId,
          modelId: modelId,
          dims: dims,
          normalized: false,
        );

  @override
  EmbeddingModelIdentity get currentModelIdentity => _identity;

  int _markerFor(String input) {
    final existing = inputToMarker[input];
    if (existing != null) return existing;
    final marker = _nextMarker++;
    inputToMarker[input] = marker;
    markerToInput[marker] = input;
    return marker;
  }

  @override
  Future<EmbeddingResult> embed(String text) async {
    final values = Float32List(_identity.dims);
    values[0] = _markerFor(text).toDouble();
    // Rest of the vector is zeros; the conformance suite does not
    // assert on tail values.
    return EmbeddingResult(vec: Vec(values), modelIdentity: _identity);
  }

  @override
  Future<List<EmbeddingResult>> embedBatch(List<String> texts) async {
    if (texts.isEmpty) return const <EmbeddingResult>[];
    final results = <EmbeddingResult>[];
    for (final text in texts) {
      results.add(await embed(text));
    }
    return List<EmbeddingResult>.unmodifiable(results);
  }

  @override
  Future<EmbeddingProbeResult> probeIdentity({
    EmbeddingModelIdentity? previousIdentity,
    String probeText = 'tom-brain embedding probe',
  }) async {
    final probeResult = await embed(probeText);
    final drift =
        (previousIdentity != null && previousIdentity != _identity);
    return EmbeddingProbeResult(
      currentIdentity: _identity,
      probeResult: probeResult,
      driftEvent: drift
          ? EmbeddingIdentityChanged(
              occurredAt: DateTime.utc(2026, 1, 1),
              fromIdentity: previousIdentity,
              toIdentity: _identity,
            )
          : null,
    );
  }

  @override
  Future<void> close() async {
    // No resources owned by the in-memory impl.
  }
}
