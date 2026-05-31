// B.25 — `EmbeddingService.embed(text)` + `currentModelIdentity`
// conformance.
//
// Scope of this test file:
//
//   - Prove the abstract `EmbeddingService` contract: `embed(text)`
//     returns an `EmbeddingResult` whose `vec` has the configured
//     dimension and whose `modelIdentity` matches
//     `currentModelIdentity`.
//   - Prove the embedding service routes through the Ollama
//     provider's `/api/embeddings` helper (`embedRaw`) using the
//     **embedding** model id (`nomic-embed-text` by default), not
//     the provider's chat `defaultModel`. That separation is the
//     load-bearing claim of the `EmbeddingService` boundary: the
//     two model identities are independent.
//   - Prove the stamped `EmbeddingModelIdentity` is stable across
//     repeated calls (substrate's commitment that two
//     `EmbeddingResult`s with `==` identities are cosine-comparable).
//   - Prove the L2-normalisation switch: with `normalize: true` the
//     returned vector has unit norm (within float32 tolerance);
//     with `normalize: false` the backend's raw vector flows
//     through unchanged.
//   - Prove the zero-vector edge case: a zero vector is left alone
//     rather than producing NaNs (the substrate's strongest
//     promise for the edge case).
//   - Prove the typed boundary failures: `EmbeddingBackendEmpty`
//     for `{embedding: []}`, `EmbeddingDimensionMismatch` when the
//     backend's vector length does not equal the configured dims.
//   - Prove backend transport failures (e.g. `OllamaHttpException`)
//     propagate verbatim — the prototype does not wrap them.
//   - Prove `embedBatch` throws `UnimplementedError` at B.25 (the
//     contract failure is loud, not a silent serial loop).
//   - Prove constructor validation: `dims <= 0` and empty `model`
//     throw `ArgumentError` at construction.
//   - Prove `close()` is a no-op on the embedding service (the
//     provider's HTTP client is owned by the substrate facade, not
//     by this service).
//   - Prove the surface is reachable from the top-level package
//     barrel (`package:tom_brain_substrate/tom_brain_substrate.dart`).
//
// Scope this file is NOT for:
//
//   - No live Ollama daemon. Every test uses `_FakeOllamaHttpClient`.
//   - No batching behaviour (B.26).
//   - No identity-drift event emission (B.27).
//   - No cross-implementation parity testing (B.28).

import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('B.25 / EmbeddingService — surface contract', () {
    test('embed returns a vector with the configured dimension', () async {
      final fake = _FakeOllamaHttpClient()
        ..embedResponse = _ramp(768);
      final service = _newService(fake);

      final result = await service.embed('hello world');

      expect(result.vec.dimension, 768);
    });

    test('embed stamps the configured identity on every result', () async {
      final fake = _FakeOllamaHttpClient()..embedResponse = _ramp(768);
      final service = _newService(fake);

      final result = await service.embed('hello');

      expect(result.modelIdentity.providerId, 'ollama:local');
      expect(result.modelIdentity.modelId, 'nomic-embed-text');
      expect(result.modelIdentity.dims, 768);
      expect(result.modelIdentity.normalized, isTrue);
    });

    test('currentModelIdentity matches the stamp on returned results',
        () async {
      final fake = _FakeOllamaHttpClient()..embedResponse = _ramp(768);
      final service = _newService(fake);

      final pre = service.currentModelIdentity;
      final result = await service.embed('hello');
      final post = service.currentModelIdentity;

      expect(result.modelIdentity, equals(pre));
      expect(result.modelIdentity, equals(post));
      expect(pre, equals(post));
      expect(identical(pre, post), isTrue,
          reason: 'identity is constructor-bound; never re-allocated');
    });

    test('identity is stable across repeated calls (== and identical)',
        () async {
      final fake = _FakeOllamaHttpClient()..embedResponse = _ramp(768);
      final service = _newService(fake);

      final first = (await service.embed('a')).modelIdentity;
      final second = (await service.embed('b')).modelIdentity;
      final third = (await service.embed('c')).modelIdentity;

      expect(first, equals(second));
      expect(second, equals(third));
      expect(identical(first, second), isTrue);
      expect(identical(second, third), isTrue);
    });
  });

  group('B.25 / EmbeddingService — wire-path routing', () {
    test('embed sends the embedding model id, not the chat default model',
        () async {
      final fake = _FakeOllamaHttpClient()..embedResponse = _ramp(768);
      final provider = _newProvider(
        httpClient: fake,
        // Chat default is gemma3:27b — should NOT appear on the embed
        // wire call.
        defaultModel: 'gemma3:27b',
      );
      final service = OllamaEmbeddingService(
        provider: provider,
        model: 'nomic-embed-text',
        dims: 768,
        normalize: true,
      );

      await service.embed('hello');

      expect(fake.embedCalls, hasLength(1));
      expect(fake.embedCalls.single.model, 'nomic-embed-text');
      expect(fake.chatCalls, isEmpty,
          reason: 'embed must not touch /api/chat');
    });

    test('embed forwards the prompt verbatim', () async {
      final fake = _FakeOllamaHttpClient()..embedResponse = _ramp(768);
      final service = _newService(fake);

      await service.embed('the quick brown fox\njumps over the lazy dog');

      expect(
        fake.embedCalls.single.prompt,
        'the quick brown fox\njumps over the lazy dog',
      );
    });

    test('embed uses the provider baseUri verbatim', () async {
      final fake = _FakeOllamaHttpClient()..embedResponse = _ramp(768);
      final provider = _newProvider(
        httpClient: fake,
        baseUri: Uri.parse('http://gpu-host:11434/'),
      );
      final service = OllamaEmbeddingService(
        provider: provider,
        model: 'nomic-embed-text',
        dims: 768,
        normalize: true,
      );

      await service.embed('hello');

      expect(
        fake.embedCalls.single.baseUri.toString(),
        'http://gpu-host:11434/',
      );
    });
  });

  group('B.25 / EmbeddingService — normalisation', () {
    test('normalize:true produces a unit vector (L2 norm == 1)', () async {
      // Backend returns a non-unit vector — service must normalise.
      final fake = _FakeOllamaHttpClient()
        ..embedResponse = const <double>[3.0, 4.0]; // norm = 5
      final service = _newService(fake, dims: 2, normalize: true);

      final result = await service.embed('hello');

      expect(result.modelIdentity.normalized, isTrue);
      final n = _l2NormOf(result.vec);
      expect(n, closeTo(1.0, 1e-6));
      // 3/5 = 0.6, 4/5 = 0.8 — within float32 precision.
      expect(result.vec[0], closeTo(0.6, 1e-6));
      expect(result.vec[1], closeTo(0.8, 1e-6));
    });

    test('normalize:false preserves the raw vector verbatim', () async {
      final fake = _FakeOllamaHttpClient()
        ..embedResponse = const <double>[3.0, 4.0];
      final service = _newService(fake, dims: 2, normalize: false);

      final result = await service.embed('hello');

      expect(result.modelIdentity.normalized, isFalse);
      // Raw values flow through — no normalisation pass.
      expect(result.vec[0], closeTo(3.0, 1e-6));
      expect(result.vec[1], closeTo(4.0, 1e-6));
      expect(_l2NormOf(result.vec), closeTo(5.0, 1e-6));
    });

    test('normalize:true on a zero vector leaves it alone (no NaNs)',
        () async {
      // Backend returns all zeros (semantically "no signal"). The
      // service must not produce NaNs — leaves the zero vector
      // alone rather than dividing by zero.
      final fake = _FakeOllamaHttpClient()
        ..embedResponse = const <double>[0.0, 0.0, 0.0, 0.0];
      final service = _newService(fake, dims: 4, normalize: true);

      final result = await service.embed('hello');

      for (var i = 0; i < 4; i++) {
        expect(result.vec[i], 0.0);
        expect(result.vec[i].isNaN, isFalse);
      }
    });

    test('normalize:true preserves direction (cosine to the raw vector == 1)',
        () async {
      // The normalisation is scale-only; direction is preserved.
      final fake = _FakeOllamaHttpClient()
        ..embedResponse = const <double>[1.0, 2.0, 3.0, 4.0, 5.0];
      final service = _newService(fake, dims: 5, normalize: true);

      final result = await service.embed('hello');

      // Compute cosine to the raw vector by hand. With normalisation,
      // every component is (raw_i / norm), so the unit vector points
      // in the same direction as the raw vector.
      const raw = <double>[1.0, 2.0, 3.0, 4.0, 5.0];
      var rawNormSq = 0.0;
      for (final v in raw) {
        rawNormSq += v * v;
      }
      final rawNorm = math.sqrt(rawNormSq);
      for (var i = 0; i < 5; i++) {
        expect(result.vec[i], closeTo(raw[i] / rawNorm, 1e-6));
      }
    });
  });

  group('B.25 / EmbeddingService — boundary failures', () {
    test('empty backend vector surfaces EmbeddingBackendEmpty', () async {
      final fake = _FakeOllamaHttpClient()..embedResponse = const <double>[];
      final service = _newService(fake);

      await expectLater(
        () => service.embed('hello'),
        throwsA(isA<EmbeddingBackendEmpty>()
            .having((e) => e.expectedIdentity.modelId, 'modelId',
                'nomic-embed-text')
            .having((e) => e.inputPreview, 'inputPreview', 'hello')),
      );
    });

    test('dimension mismatch surfaces EmbeddingDimensionMismatch', () async {
      // Service is configured for 768; backend returns 384 dims.
      final fake = _FakeOllamaHttpClient()..embedResponse = _ramp(384);
      final service = _newService(fake); // expects 768

      await expectLater(
        () => service.embed('hello'),
        throwsA(isA<EmbeddingDimensionMismatch>()
            .having((e) => e.expectedIdentity.dims, 'expectedDims', 768)
            .having((e) => e.actualDims, 'actualDims', 384)),
      );
    });

    test('long input is truncated in exception inputPreview', () async {
      final fake = _FakeOllamaHttpClient()..embedResponse = const <double>[];
      final service = _newService(fake);

      final long = 'x' * 200;
      try {
        await service.embed(long);
        fail('expected EmbeddingBackendEmpty');
      } on EmbeddingBackendEmpty catch (e) {
        // Preview is bounded; the full 200-char input is not echoed.
        expect(e.inputPreview.length, lessThan(long.length));
        expect(e.inputPreview, endsWith('…'));
      }
    });

    test('backend transport failure (OllamaHttpException) propagates verbatim',
        () async {
      final fake = _FakeOllamaHttpClient()
        ..embedException = OllamaHttpException(
          statusCode: 500,
          body: 'ollama daemon unhappy',
          endpoint: Uri.parse('http://127.0.0.1:11434/api/embeddings'),
        );
      final service = _newService(fake);

      await expectLater(
        () => service.embed('hello'),
        throwsA(isA<OllamaHttpException>()
            .having((e) => e.statusCode, 'statusCode', 500)),
      );
    });
  });

  group('B.25 / EmbeddingService — deferred surfaces', () {
    test('embedBatch throws UnimplementedError at B.25 (loud contract gap)',
        () async {
      final fake = _FakeOllamaHttpClient()..embedResponse = _ramp(768);
      final service = _newService(fake);

      await expectLater(
        () => service.embedBatch(const ['a', 'b']),
        throwsA(isA<UnimplementedError>().having(
          (e) => e.message ?? '',
          'message',
          contains('B.26'),
        )),
      );
    });

    test('close() is a no-op on the embedding service (does not touch provider)',
        () async {
      final fake = _FakeOllamaHttpClient()..embedResponse = _ramp(768);
      final service = _newService(fake);

      await service.close();

      // Provider's underlying HTTP client must NOT be closed by the
      // embedding service.
      expect(fake.closeCalled, isFalse);
    });
  });

  group('B.25 / EmbeddingService — constructor validation', () {
    test('dims <= 0 throws ArgumentError', () {
      expect(
        () => OllamaEmbeddingService(
          provider: _newProvider(httpClient: _FakeOllamaHttpClient()),
          model: 'nomic-embed-text',
          dims: 0,
          normalize: true,
        ),
        throwsArgumentError,
      );
      expect(
        () => OllamaEmbeddingService(
          provider: _newProvider(httpClient: _FakeOllamaHttpClient()),
          model: 'nomic-embed-text',
          dims: -1,
          normalize: true,
        ),
        throwsArgumentError,
      );
    });

    test('empty model throws ArgumentError', () {
      expect(
        () => OllamaEmbeddingService(
          provider: _newProvider(httpClient: _FakeOllamaHttpClient()),
          model: '',
          dims: 768,
          normalize: true,
        ),
        throwsArgumentError,
      );
    });

    test('identity providerId echoes the provider id', () {
      final provider = _newProvider(
        httpClient: _FakeOllamaHttpClient(),
        id: 'ollama:bomber',
      );
      final service = OllamaEmbeddingService(
        provider: provider,
        model: 'nomic-embed-text',
        dims: 768,
        normalize: true,
      );

      expect(service.currentModelIdentity.providerId, 'ollama:bomber');
    });
  });

  group('B.25 / EmbeddingService — type surface', () {
    test('the prototype implementation is an EmbeddingService', () {
      final service = _newService(_FakeOllamaHttpClient());
      expect(service, isA<EmbeddingService>());
    });

    test('the service surface is reachable from the top-level barrel', () {
      // These references compile-only iff the symbols are exported
      // from `package:tom_brain_substrate/tom_brain_substrate.dart`.
      expect(EmbeddingService, isNotNull);
      expect(OllamaEmbeddingService, isNotNull);
      expect(EmbeddingDimensionMismatch, isNotNull);
      expect(EmbeddingBackendEmpty, isNotNull);
      // Value types reach the same barrel via the api/ surface.
      expect(EmbeddingResult, isNotNull);
      expect(EmbeddingModelIdentity, isNotNull);
    });

    test('EmbeddingDimensionMismatch.toString surfaces both dim values', () {
      final identity = const EmbeddingModelIdentity(
        providerId: 'ollama:local',
        modelId: 'nomic-embed-text',
        dims: 768,
        normalized: true,
      );
      final ex = EmbeddingDimensionMismatch(
        expectedIdentity: identity,
        actualDims: 384,
        inputPreview: 'x',
      );
      expect(ex.toString(), contains('768'));
      expect(ex.toString(), contains('384'));
      expect(ex.toString(), contains('nomic-embed-text'));
    });

    test('EmbeddingBackendEmpty.toString surfaces provider + model', () {
      final identity = const EmbeddingModelIdentity(
        providerId: 'ollama:local',
        modelId: 'nomic-embed-text',
        dims: 768,
        normalized: true,
      );
      final ex = EmbeddingBackendEmpty(
        expectedIdentity: identity,
        inputPreview: 'x',
      );
      expect(ex.toString(), contains('ollama:local'));
      expect(ex.toString(), contains('nomic-embed-text'));
    });
  });
}

// ─── helpers ────────────────────────────────────────────────────────

OllamaEmbeddingService _newService(
  _FakeOllamaHttpClient fake, {
  int dims = 768,
  bool normalize = true,
}) {
  final provider = _newProvider(httpClient: fake);
  return OllamaEmbeddingService(
    provider: provider,
    model: 'nomic-embed-text',
    dims: dims,
    normalize: normalize,
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
    httpClient: httpClient ?? _FakeOllamaHttpClient(),
  );
}

/// Builds a length-[n] ramp vector `[0.0, 1.0, 2.0, ...]`. Used in
/// dimension-passing tests where the actual values do not matter,
/// only the length.
List<double> _ramp(int n) =>
    List<double>.generate(n, (i) => i.toDouble(), growable: false);

/// L2 norm of a [Vec] — computed locally so the test does not depend
/// on `Vec.norm()` (which would couple the assertion to a separate
/// implementation; we want to assert the substrate's promise
/// directly).
double _l2NormOf(Vec v) {
  var sumSq = 0.0;
  for (var i = 0; i < v.dimension; i++) {
    final x = v[i];
    sumSq += x * x;
  }
  return math.sqrt(sumSq);
}

// ─── test double (Ollama HTTP client) ───────────────────────────────

/// Deterministic in-test [OllamaHttpClient] for the B.25 suite.
///
/// Lifted from the B.14 suite's `_FakeOllamaHttpClient` with the
/// surface trimmed to what B.25 exercises (chat / stream paths still
/// implemented so the type contract is whole, but unused). Adds the
/// `embedException` slot so backend-failure tests can inject a typed
/// exception on `/api/embeddings`.
final class _FakeOllamaHttpClient implements OllamaHttpClient {
  final List<_ChatInvocation> chatCalls = <_ChatInvocation>[];
  final List<_EmbedInvocation> embedCalls = <_EmbedInvocation>[];

  OllamaChatResponse chatResponse =
      const OllamaChatResponse(model: 'gemma3:27b', content: '');
  Object? chatException;

  List<OllamaStreamFragment> streamFragments = const <OllamaStreamFragment>[];
  Object? streamException;

  List<double> embedResponse = const <double>[];

  /// If set, the next `embed` call throws this instead of returning.
  Object? embedException;

  List<OllamaTagEntry> tagsResponse = const <OllamaTagEntry>[];

  bool closeCalled = false;

  @override
  Future<OllamaChatResponse> chat({
    required Uri baseUri,
    required String model,
    required List<OllamaMessage> messages,
    required OllamaGenerationOptions options,
    Duration? requestTimeout,
  }) async {
    chatCalls.add(_ChatInvocation(model: model));
    if (chatException != null) throw chatException!;
    return chatResponse;
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
    chatCalls.add(_ChatInvocation(model: model));
    if (streamException != null) throw streamException!;
    for (final frag in streamFragments) {
      yield frag;
    }
  }

  @override
  Future<List<double>> embed({
    required Uri baseUri,
    required String model,
    required String prompt,
    Duration? requestTimeout,
  }) async {
    embedCalls.add(_EmbedInvocation(
      baseUri: baseUri,
      model: model,
      prompt: prompt,
    ));
    if (embedException != null) throw embedException!;
    return embedResponse;
  }

  @override
  Future<List<OllamaTagEntry>> listTags({
    required Uri baseUri,
    Duration? requestTimeout,
  }) async {
    return tagsResponse;
  }

  @override
  void close() {
    closeCalled = true;
  }
}

final class _ChatInvocation {
  final String model;
  const _ChatInvocation({required this.model});
}

final class _EmbedInvocation {
  final Uri baseUri;
  final String model;
  final String prompt;

  const _EmbedInvocation({
    required this.baseUri,
    required this.model,
    required this.prompt,
  });
}
