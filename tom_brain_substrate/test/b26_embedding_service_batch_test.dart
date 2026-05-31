// B.26 — `EmbeddingService.embedBatch(texts)` conformance.
//
// Scope of this test file:
//
//   - Prove the fan-out shape: `embedBatch` returns one
//     `EmbeddingResult` per input, in input order, regardless of
//     completion order. The shared "results[i] is the embedding of
//     texts[i]" contract is the load-bearing claim consumers (memory,
//     the inbound classifier) bind against — a re-order would silently
//     mis-tag every consumer's stored vector with the wrong source
//     text.
//   - Prove the empty-list fast path: `embedBatch(const [])` returns
//     `[]` synchronously without dispatching any backend calls. (Test
//     observes the no-dispatch via the fake's call counter.)
//   - Prove the configurable concurrency cap is honoured: the maximum
//     number of in-flight backend calls observed at any instant is
//     `min(batchConcurrency, texts.length)` and never exceeds the cap.
//     This is the only way to validate the cap without timing — the
//     test gates dispatch on a coordinator the test controls so we
//     can read the peak concurrency deterministically.
//   - Prove the small-batch case: when `texts.length < batchConcurrency`,
//     the effective worker count is `texts.length` (no idle workers
//     spawned, no wasted overhead).
//   - Prove the identity invariant: every result in a batch carries
//     the same identity as `currentModelIdentity` AND is `identical()`
//     across results (the substrate's promise is constructor-bound,
//     not per-call).
//   - Prove every result is L2-normalised when `normalize: true` (the
//     same normalisation pass that `embed()` runs flows through
//     `embedBatch`).
//   - Prove every batch result has the configured dimension (defends
//     against a fan-out implementation that bypassed the dim check).
//   - Prove failure short-circuit: if one input's backend call fails
//     (boundary failure or transport exception), the batch future
//     completes with that error. The first-surface failure semantics
//     and the in-flight-completion behaviour are documented in the
//     interface; the test asserts the future surfaces SOME instance
//     of the failure type and that the failed-input's slot was not
//     silently filled with a default.
//   - Prove single-input batch parity: `embedBatch(['x'])` produces
//     the same result as `embed('x')` (modulo identity which is the
//     same instance either way).
//   - Prove the returned list is unmodifiable: a caller cannot mutate
//     the batch result and accidentally corrupt a downstream consumer.
//   - Prove the constructor validates `batchConcurrency > 0`.
//
// Scope this file is NOT for:
//
//   - No live Ollama daemon. Every test uses the in-test
//     `_BatchAwareFakeOllamaHttpClient`.
//   - No identity-drift event emission (B.27).
//   - No cross-implementation parity testing (B.28).
//   - No assertion on which specific input's failure surfaces from a
//     batch with multiple failing inputs — the interface contract
//     deliberately leaves that implementation-defined.

import 'dart:async';

import 'package:test/test.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('B.26 / EmbeddingService.embedBatch — surface contract', () {
    test('empty input returns empty result without dispatching any call',
        () async {
      final fake = _BatchAwareFakeOllamaHttpClient();
      final service = _newService(fake);

      final result = await service.embedBatch(const <String>[]);

      expect(result, isEmpty);
      expect(fake.totalCallCount, 0,
          reason: 'empty input must not dispatch any backend call');
    });

    test('result length equals input length', () async {
      final fake = _BatchAwareFakeOllamaHttpClient.fillFromInput();
      final service = _newService(fake);

      final inputs = List<String>.generate(7, (i) => 'input-$i');
      final result = await service.embedBatch(inputs);

      expect(result, hasLength(7));
    });

    test('result preserves input order regardless of completion order',
        () async {
      // The fake completes index 0 last (its delay is largest); index
      // 4 completes first. The implementation must still place each
      // result at its input index.
      //
      // `normalize: false` here is deliberate: the fake encodes the
      // input marker into a single component of an otherwise-zero
      // vector. L2 normalisation of `[k, 0, 0, ...]` collapses every
      // non-zero `k` to `1.0`, which would erase the marker. Disabling
      // normalisation for this test keeps the per-input marker
      // observable. The normalisation behaviour itself is covered in
      // the dedicated normalisation group below.
      final fake = _BatchAwareFakeOllamaHttpClient.fillFromInput()
        ..completionDelays = const [
          Duration(milliseconds: 40),
          Duration(milliseconds: 30),
          Duration(milliseconds: 20),
          Duration(milliseconds: 10),
          Duration(milliseconds: 0),
        ];
      final service = _newService(fake, normalize: false);

      final result = await service.embedBatch(
        const ['t0', 't1', 't2', 't3', 't4'],
      );

      // The fake encodes the input text into a marker dimension of the
      // returned vector — we read it back to prove which slot got
      // which input's embedding.
      for (var i = 0; i < 5; i++) {
        final marker = result[i].vec[0];
        expect(marker, equals(i.toDouble()),
            reason: 'results[$i] must hold the embedding of texts[$i] '
                '(completion order is reverse of input order in this test)');
      }
    });

    test('every result carries the same identity as currentModelIdentity',
        () async {
      final fake = _BatchAwareFakeOllamaHttpClient.fillFromInput();
      final service = _newService(fake);

      final result = await service.embedBatch(const ['a', 'b', 'c']);

      for (final r in result) {
        expect(r.modelIdentity, equals(service.currentModelIdentity));
        expect(identical(r.modelIdentity, service.currentModelIdentity), isTrue,
            reason: 'identity is constructor-bound; never re-allocated '
                'across batch results');
      }
    });

    test('every result has the configured dimension', () async {
      final fake = _BatchAwareFakeOllamaHttpClient.fillFromInput();
      final service = _newService(fake, dims: 768);

      final result = await service.embedBatch(const ['x', 'y', 'z']);

      for (final r in result) {
        expect(r.vec.dimension, 768);
      }
    });

    test('single-input batch produces the same result as embed()', () async {
      final fake = _BatchAwareFakeOllamaHttpClient.fillFromInput();
      final service = _newService(fake);

      final single = await service.embed('hello');
      // Reset the fake's call log so the batch path's call count is
      // observable in isolation.
      fake.resetCallLog();
      final batch = await service.embedBatch(const ['hello']);

      expect(batch, hasLength(1));
      // Same identity (substrate's invariant).
      expect(batch.single.modelIdentity, equals(single.modelIdentity));
      // Same dimensionality.
      expect(batch.single.vec.dimension, single.vec.dimension);
      // Same marker (the fake encodes input text deterministically;
      // both calls passed 'hello').
      expect(batch.single.vec[0], equals(single.vec[0]));
    });

    test('returned list is unmodifiable', () async {
      final fake = _BatchAwareFakeOllamaHttpClient.fillFromInput();
      final service = _newService(fake);

      final result = await service.embedBatch(const ['a', 'b']);

      expect(
        () => result.add(result.first),
        throwsUnsupportedError,
        reason: 'batch result is unmodifiable so a caller cannot '
            'mutate the list and accidentally corrupt a downstream '
            'consumer that retained a reference to it',
      );
    });
  });

  group('B.26 / EmbeddingService.embedBatch — concurrency cap', () {
    test(
        'peak in-flight calls never exceed batchConcurrency '
        '(cap=4, inputs=16)', () async {
      // Each call waits on a per-call completer. The fake records
      // (start, end) timestamps; the test computes the peak overlap
      // and asserts it never exceeds the configured cap.
      final fake = _BatchAwareFakeOllamaHttpClient.fillFromInput()
        ..coordinatedRelease = true;
      final service = _newService(fake, batchConcurrency: 4);

      final inputs = List<String>.generate(16, (i) => 'in-$i');

      final batchFuture = service.embedBatch(inputs);

      // Release calls in start order; the worker pool will pick up
      // the next index as soon as a release completes. The fake
      // tracks the running set, so the peak observed at any release
      // boundary is the peak concurrency.
      while (await fake.releaseOldestPending()) {
        // loop until every call has been released.
      }

      await batchFuture;

      expect(fake.peakInFlight, lessThanOrEqualTo(4),
          reason: 'peak in-flight must respect the batchConcurrency cap');
      expect(fake.peakInFlight, greaterThanOrEqualTo(1),
          reason: 'a non-empty batch must dispatch at least one call');
      expect(fake.totalCallCount, 16);
    });

    test('peak in-flight reaches the cap when inputs >> cap', () async {
      // With 16 inputs and cap 4, peak should hit exactly 4 (the
      // worker pool is fully saturated for most of the run).
      final fake = _BatchAwareFakeOllamaHttpClient.fillFromInput()
        ..coordinatedRelease = true;
      final service = _newService(fake, batchConcurrency: 4);

      final inputs = List<String>.generate(16, (i) => 'in-$i');

      final batchFuture = service.embedBatch(inputs);

      // Wait until the pool has saturated, then release one at a
      // time. The fake records the high-water mark.
      await fake.waitForInFlight(4);

      while (await fake.releaseOldestPending()) {}
      await batchFuture;

      expect(fake.peakInFlight, 4);
    });

    test(
        'small batch caps effective worker count to texts.length '
        '(cap=8, inputs=3)', () async {
      // With 3 inputs and cap 8, only 3 workers should be spawned —
      // a wasted worker would attempt a 4th dispatch and the test
      // would see peakInFlight > 3.
      final fake = _BatchAwareFakeOllamaHttpClient.fillFromInput()
        ..coordinatedRelease = true;
      final service = _newService(fake, batchConcurrency: 8);

      final batchFuture = service.embedBatch(const ['a', 'b', 'c']);

      await fake.waitForInFlight(3);
      while (await fake.releaseOldestPending()) {}
      await batchFuture;

      expect(fake.peakInFlight, 3,
          reason: 'effective worker count must be min(cap, inputs)');
    });

    test('serial dispatch when batchConcurrency=1 (cap=1, inputs=5)',
        () async {
      // Cap of 1 ⇒ exactly one in-flight call at any time. The peak
      // observed must be 1, never 2.
      final fake = _BatchAwareFakeOllamaHttpClient.fillFromInput()
        ..coordinatedRelease = true;
      final service = _newService(fake, batchConcurrency: 1);

      final batchFuture =
          service.embedBatch(const ['a', 'b', 'c', 'd', 'e']);

      // Release one at a time, in order — each release should
      // unblock exactly one worker, which dispatches the next input.
      while (await fake.releaseOldestPending()) {}
      await batchFuture;

      expect(fake.peakInFlight, 1,
          reason: 'cap of 1 must serialise all dispatches');
      expect(fake.totalCallCount, 5);
    });
  });

  group('B.26 / EmbeddingService.embedBatch — normalisation', () {
    test('every batch result is L2-normalised when normalize:true', () async {
      // The fake emits a non-unit vector per input ([3, 4]) for which
      // the L2-normalised form is [0.6, 0.8].
      final fake = _BatchAwareFakeOllamaHttpClient.constantVector(
        const <double>[3.0, 4.0],
      );
      final service = _newService(fake, dims: 2, normalize: true);

      final result = await service.embedBatch(const ['a', 'b', 'c']);

      for (final r in result) {
        expect(r.vec[0], closeTo(0.6, 1e-6));
        expect(r.vec[1], closeTo(0.8, 1e-6));
        expect(r.modelIdentity.normalized, isTrue);
      }
    });

    test('every batch result is verbatim when normalize:false', () async {
      final fake = _BatchAwareFakeOllamaHttpClient.constantVector(
        const <double>[3.0, 4.0],
      );
      final service = _newService(fake, dims: 2, normalize: false);

      final result = await service.embedBatch(const ['a', 'b']);

      for (final r in result) {
        expect(r.vec[0], closeTo(3.0, 1e-6));
        expect(r.vec[1], closeTo(4.0, 1e-6));
        expect(r.modelIdentity.normalized, isFalse);
      }
    });
  });

  group('B.26 / EmbeddingService.embedBatch — failure short-circuit', () {
    test('EmbeddingBackendEmpty on one input surfaces on the batch future',
        () async {
      // Index 2 returns an empty vector; the rest return valid
      // vectors. The batch future must complete with
      // EmbeddingBackendEmpty.
      final fake = _BatchAwareFakeOllamaHttpClient.fillFromInput()
        ..emptyResponseAt = {2};
      // Serial dispatch keeps the failure surface deterministic for
      // the test — but the contract holds at any cap.
      final service = _newService(fake, batchConcurrency: 1);

      await expectLater(
        () => service.embedBatch(const ['ok-0', 'ok-1', 'bad', 'ok-3']),
        throwsA(isA<EmbeddingBackendEmpty>()
            .having((e) => e.expectedIdentity.modelId, 'modelId',
                'nomic-embed-text')
            .having((e) => e.inputPreview, 'inputPreview', 'bad')),
      );
    });

    test('EmbeddingDimensionMismatch on one input surfaces on the batch future',
        () async {
      // Configure for 768 dims; the fake returns the wrong dim on
      // index 1 only.
      final fake = _BatchAwareFakeOllamaHttpClient.fillFromInput(dims: 768)
        ..wrongDimensionAt = {1};
      final service = _newService(fake, batchConcurrency: 1);

      await expectLater(
        () => service.embedBatch(const ['x', 'y', 'z']),
        throwsA(isA<EmbeddingDimensionMismatch>()
            .having((e) => e.expectedIdentity.dims, 'expectedDims', 768)),
      );
    });

    test('OllamaHttpException on one input surfaces on the batch future',
        () async {
      // The fake throws an Ollama transport exception on index 0.
      final fake = _BatchAwareFakeOllamaHttpClient.fillFromInput()
        ..exceptionAt = {
          0: OllamaHttpException(
            statusCode: 503,
            body: 'service unavailable',
            endpoint: Uri.parse('http://127.0.0.1:11434/api/embeddings'),
          ),
        };
      final service = _newService(fake, batchConcurrency: 1);

      await expectLater(
        () => service.embedBatch(const ['fail', 'ok']),
        throwsA(isA<OllamaHttpException>()
            .having((e) => e.statusCode, 'statusCode', 503)),
      );
    });

    test(
        'failure short-circuits dispatch (later workers do not pick up '
        'after the first failure surfaces, cap=1)', () async {
      // Cap 1 + failure on index 1 ⇒ index 2 should never be
      // dispatched.
      final fake = _BatchAwareFakeOllamaHttpClient.fillFromInput()
        ..emptyResponseAt = {1};
      final service = _newService(fake, batchConcurrency: 1);

      await expectLater(
        () => service.embedBatch(const ['ok-0', 'bad', 'never-dispatched']),
        throwsA(isA<EmbeddingBackendEmpty>()),
      );

      // Inputs 0 and 1 ran (1 raised); input 2 never reached the
      // backend because Future.wait(eagerError: true) stopped the
      // worker.
      expect(fake.calledInputs, equals({'ok-0', 'bad'}));
      expect(fake.calledInputs.contains('never-dispatched'), isFalse);
    });
  });

  group('B.26 / EmbeddingService.embedBatch — wire-path routing', () {
    test('every batch call sends the embedding model id, not chat default',
        () async {
      final fake = _BatchAwareFakeOllamaHttpClient.fillFromInput();
      final provider = _newProvider(httpClient: fake, defaultModel: 'gemma3:27b');
      final service = OllamaEmbeddingService(
        provider: provider,
        model: 'nomic-embed-text',
        dims: 768,
        normalize: true,
      );

      await service.embedBatch(const ['a', 'b', 'c']);

      expect(fake.calledModels, everyElement(equals('nomic-embed-text')),
          reason: 'no batch call may regress to the chat default model');
      expect(fake.chatCallCount, 0,
          reason: 'batch path must not touch /api/chat');
    });

    test('each input is forwarded verbatim to a separate backend call',
        () async {
      final fake = _BatchAwareFakeOllamaHttpClient.fillFromInput();
      final service = _newService(fake);

      const inputs = ['alpha', 'bravo\nbreaks-line', 'charlie'];
      await service.embedBatch(inputs);

      // The set check is order-agnostic; the order test above already
      // pins the slot-to-input mapping.
      expect(fake.calledInputs, equals(inputs.toSet()));
    });
  });

  group('B.26 / EmbeddingService.embedBatch — constructor validation', () {
    test('batchConcurrency <= 0 throws ArgumentError', () {
      expect(
        () => OllamaEmbeddingService(
          provider: _newProvider(
            httpClient: _BatchAwareFakeOllamaHttpClient(),
          ),
          model: 'nomic-embed-text',
          dims: 768,
          normalize: true,
          batchConcurrency: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => OllamaEmbeddingService(
          provider: _newProvider(
            httpClient: _BatchAwareFakeOllamaHttpClient(),
          ),
          model: 'nomic-embed-text',
          dims: 768,
          normalize: true,
          batchConcurrency: -1,
        ),
        throwsArgumentError,
      );
    });

    test('batchConcurrency defaults to 4', () {
      final service = OllamaEmbeddingService(
        provider: _newProvider(
          httpClient: _BatchAwareFakeOllamaHttpClient(),
        ),
        model: 'nomic-embed-text',
        dims: 768,
        normalize: true,
      );
      expect(service.batchConcurrency, 4,
          reason: 'default cap matches substrate_specification.md § 7.3');
    });
  });
}

// ─── helpers ────────────────────────────────────────────────────────

OllamaEmbeddingService _newService(
  _BatchAwareFakeOllamaHttpClient fake, {
  int dims = 768,
  bool normalize = true,
  int batchConcurrency = 4,
}) {
  final provider = _newProvider(httpClient: fake);
  return OllamaEmbeddingService(
    provider: provider,
    model: 'nomic-embed-text',
    dims: dims,
    normalize: normalize,
    batchConcurrency: batchConcurrency,
  );
}

OllamaLlmProvider _newProvider({
  String id = 'ollama:local',
  Uri? baseUri,
  String defaultModel = 'gemma3:27b',
  OllamaHttpClient? httpClient,
}) {
  return OllamaLlmProvider(
    id: id,
    baseUri: baseUri ?? Uri.parse('http://127.0.0.1:11434/'),
    defaultModel: defaultModel,
    httpClient: httpClient ?? _BatchAwareFakeOllamaHttpClient(),
  );
}

// ─── test double (Ollama HTTP client) ───────────────────────────────

/// Batch-aware in-test [OllamaHttpClient] for the B.26 suite.
///
/// Capabilities beyond the B.25 fake:
///
///   * Tracks `peakInFlight` — the high-water mark of concurrent
///     `embed` calls observed, so the test can assert the cap is
///     honoured deterministically (no timing dependency).
///   * Per-input response policy: a constant vector (`constantVector`
///     factory) or a per-input marker vector that encodes the call
///     index at `vec[0]` (`fillFromInput` factory). The marker form
///     is what lets the order-preservation tests check that
///     `results[i]` is the embedding of `texts[i]`.
///   * Coordinated release: when `coordinatedRelease` is `true`, each
///     `embed` call blocks on a per-call `Completer` until the test
///     releases it via [releaseOldestPending] or [waitForInFlight] +
///     a release. This lets the concurrency-cap tests observe the
///     pool's peak occupancy at a known moment.
///   * Per-index failure injection: `emptyResponseAt`,
///     `wrongDimensionAt`, `exceptionAt` — mapped onto the input
///     index in the order the calls *arrive*, not necessarily the
///     order workers picked them up; the failure-surface tests use
///     `batchConcurrency: 1` to make arrival order = dispatch order.
final class _BatchAwareFakeOllamaHttpClient implements OllamaHttpClient {
  /// Per-call wait-and-release queue. `coordinatedRelease=true`
  /// makes every `embed` call await a fresh completer pushed here;
  /// the test calls [releaseOldestPending] to complete the front of
  /// the queue.
  final List<Completer<void>> _pending = <Completer<void>>[];

  /// Tracks how many `embed` calls are currently in flight (between
  /// "method entered" and "method returned").
  int _inFlight = 0;

  /// Read-only high-water mark observed since construction.
  int peakInFlight = 0;

  /// Total number of `embed` calls observed since construction (or
  /// since the last [resetCallLog]).
  int totalCallCount = 0;

  /// The inputs passed to `embed`, in arrival order (de-duplicated
  /// because the failure tests use `Set` equality).
  final Set<String> calledInputs = <String>{};

  /// The models passed to `embed`, in arrival order. Lets the
  /// wire-path tests assert "every call used the embedding model id".
  final List<String> calledModels = <String>[];

  /// Number of `chat` (non-embedding) calls observed. Should stay at
  /// zero in every B.26 test.
  int chatCallCount = 0;

  /// Whether `embed` calls should block on a per-call completer until
  /// released. When `false` (default), calls return immediately with
  /// the policy-selected response.
  bool coordinatedRelease = false;

  /// Optional per-call delay applied in arrival order. Used by the
  /// order-preservation test to force completion order to differ
  /// from arrival order.
  List<Duration> completionDelays = const <Duration>[];

  /// Maps "arrival index" → "wrong dimension": the call returns a
  /// vector of `dims - 1` size so the dim check fails. The arrival
  /// index is the position in `calledInputs` insertion order, so
  /// the failure tests cap concurrency at 1 to make arrival order
  /// equal dispatch order.
  Set<int> wrongDimensionAt = const <int>{};

  /// Same as [wrongDimensionAt], but the call returns an empty
  /// vector (surfaces `EmbeddingBackendEmpty`).
  Set<int> emptyResponseAt = const <int>{};

  /// Per-arrival-index throw: when the arrival count hits a key, the
  /// call throws the mapped exception instead of returning.
  Map<int, Object> exceptionAt = const <int, Object>{};

  /// Builder for the per-call vector. The arrival index of the call
  /// is passed in; the function returns the raw `List<double>` the
  /// fake will hand back.
  late List<double> Function(int arrivalIndex, String input) _vectorFor;

  /// The dimension every returned vector should have (unless
  /// [wrongDimensionAt] forces an off-by-one for the failure tests).
  final int _defaultDims;

  _BatchAwareFakeOllamaHttpClient({int dims = 768})
      : _defaultDims = dims,
        _vectorFor = ((_, _) => List<double>.filled(dims, 0.0));

  /// Returns a fake whose `embed` response is a constant [vector]
  /// regardless of input. Used by the normalisation tests where the
  /// per-input encoding does not matter.
  factory _BatchAwareFakeOllamaHttpClient.constantVector(
    List<double> vector,
  ) {
    final fake = _BatchAwareFakeOllamaHttpClient(dims: vector.length);
    fake._vectorFor = (_, _) => vector;
    return fake;
  }

  /// Returns a fake whose `embed` response encodes the *input index*
  /// at `vec[0]` and zero-fills the rest. The input index is
  /// computed by parsing the trailing integer off the input string
  /// (`'in-7'` ⇒ 7, `'t3'` ⇒ 3, otherwise the arrival index). This
  /// lets the order-preservation test assert which slot holds which
  /// input's embedding.
  factory _BatchAwareFakeOllamaHttpClient.fillFromInput({int dims = 768}) {
    final fake = _BatchAwareFakeOllamaHttpClient(dims: dims);
    fake._vectorFor = (arrivalIndex, input) {
      // Look for a trailing integer to decode the input's logical
      // index; fall back to the arrival index when the input does
      // not encode one.
      final match = RegExp(r'(\d+)$').firstMatch(input);
      final marker = match != null
          ? double.parse(match.group(1)!)
          : arrivalIndex.toDouble();
      final vec = List<double>.filled(dims, 0.0);
      vec[0] = marker;
      return vec;
    };
    return fake;
  }

  /// Releases the oldest pending `embed` call (if any). Returns
  /// `true` if a completer was found and completed; `false` when
  /// the queue is empty.
  ///
  /// Coordinated-release tests poll this in a loop until it returns
  /// `false` (every dispatched call has been released and the batch
  /// future has completed).
  Future<bool> releaseOldestPending() async {
    // Yield to the event loop so any worker that just dispatched a
    // call gets a chance to register its completer.
    await Future<void>.delayed(Duration.zero);
    if (_pending.isEmpty) return false;
    final completer = _pending.removeAt(0);
    completer.complete();
    // Yield again so the released call can run its tail and decrement
    // _inFlight before the next loop iteration reads it.
    await Future<void>.delayed(Duration.zero);
    return true;
  }

  /// Blocks until the in-flight count reaches [target]. Used by the
  /// concurrency-cap tests to observe the pool at full saturation
  /// before starting to release.
  Future<void> waitForInFlight(int target) async {
    // Bounded spin via event-loop yields; the worker pool reaches
    // saturation in O(target) microtasks.
    while (_inFlight < target) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Resets the call log so the test can observe a subsequent
  /// `embed` / `embedBatch` call in isolation. Does NOT reset
  /// peak-in-flight (which is a high-water mark across the whole
  /// test).
  void resetCallLog() {
    totalCallCount = 0;
    calledInputs.clear();
    calledModels.clear();
  }

  // ─── OllamaHttpClient surface ────────────────────────────────────

  @override
  Future<List<double>> embed({
    required Uri baseUri,
    required String model,
    required String prompt,
    Duration? requestTimeout,
  }) async {
    final arrivalIndex = totalCallCount;
    totalCallCount++;
    calledInputs.add(prompt);
    calledModels.add(model);

    _inFlight++;
    if (_inFlight > peakInFlight) peakInFlight = _inFlight;

    try {
      // Coordinated-release path: block until the test releases this
      // call.
      if (coordinatedRelease) {
        final completer = Completer<void>();
        _pending.add(completer);
        await completer.future;
      }

      // Per-call delay (used by the order-preservation test).
      if (arrivalIndex < completionDelays.length) {
        await Future<void>.delayed(completionDelays[arrivalIndex]);
      }

      // Per-call failure injection.
      final exception = exceptionAt[arrivalIndex];
      if (exception != null) throw exception;
      if (emptyResponseAt.contains(arrivalIndex)) {
        return const <double>[];
      }
      if (wrongDimensionAt.contains(arrivalIndex)) {
        return List<double>.filled(_defaultDims - 1, 0.0);
      }

      return _vectorFor(arrivalIndex, prompt);
    } finally {
      _inFlight--;
    }
  }

  @override
  Future<OllamaChatResponse> chat({
    required Uri baseUri,
    required String model,
    required List<OllamaMessage> messages,
    required OllamaGenerationOptions options,
    Duration? requestTimeout,
  }) async {
    chatCallCount++;
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
    chatCallCount++;
  }

  @override
  Future<List<OllamaTagEntry>> listTags({
    required Uri baseUri,
    Duration? requestTimeout,
  }) async =>
      const <OllamaTagEntry>[];

  @override
  void close() {}
}
