// B.27 — `EmbeddingService.probeIdentity()` + `EmbeddingProbeResult`
// conformance.
//
// Scope of this test file:
//
//   - Prove the probe-result shape: `probeIdentity()` returns an
//     `EmbeddingProbeResult` whose `currentIdentity` equals
//     `service.currentModelIdentity` and whose `probeResult` carries
//     a vector of the configured dimension stamped with the same
//     identity. The probe IS an embed call — its result inherits
//     every property an `embed()` result has.
//   - Prove the wire-path reuse: `probeIdentity()` dispatches one
//     backend call to the embedding model (`nomic-embed-text`), not
//     the chat default model. The probe text defaults to the
//     interface-declared constant; the caller can override.
//   - Prove the drift-detection invariants:
//       * `previousIdentity == null` ⇒ `driftEvent == null` (first
//         boot, nothing to compare against).
//       * `previousIdentity == currentIdentity` ⇒ `driftEvent ==
//         null` (no drift on a clean restart).
//       * `previousIdentity != currentIdentity` ⇒ `driftEvent`
//         carries `(from: previous, to: current)`.
//       * Drift comparison is structural over all four identity
//         fields — a difference in any of `(providerId, modelId,
//         dims, normalized)` fires the event.
//   - Prove the event stamp: `driftEvent.occurredAt` is the value
//     produced by the constructor's injected `now` clock. The clock
//     is read exactly once per drift event, at the moment the probe
//     decides to emit.
//   - Prove the probe surfaces backend defects loudly: empty backend
//     vector ⇒ `EmbeddingBackendEmpty`, dim mismatch ⇒
//     `EmbeddingDimensionMismatch`, transport exception ⇒
//     propagated verbatim. None of these failure modes silently
//     swallow into a "no drift" probe result.
//   - Prove the surface is reachable from the top-level barrel —
//     `EmbeddingProbeResult` ships through
//     `package:tom_brain_substrate/tom_brain_substrate.dart`.
//   - Prove the identity surface produced by the probe is
//     unchanged across repeated probe calls (the substrate's
//     identity-is-constructor-bound promise survives the probe
//     surface — drift is detected *against the caller's reference*,
//     never *changes the service's identity*).
//
// Scope this file is NOT for:
//
//   - No live Ollama daemon. Every test uses `_FakeOllamaHttpClient`.
//   - No cross-implementation parity testing (B.28).
//   - No assertion that the probe vector cosine-equals a previously-
//     stored probe vector (the Q-B.3.5 silent-weight-swap detector
//     is deferred — present-day drift is `(providerId, modelId)`
//     identity comparison only).

import 'package:test/test.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('B.27 / probeIdentity — result shape', () {
    test('returns an EmbeddingProbeResult with the current identity', () async {
      final fake = _FakeOllamaHttpClient()..embedResponse = _ramp(768);
      final service = _newService(fake);

      final probe = await service.probeIdentity();

      expect(probe, isA<EmbeddingProbeResult>());
      expect(probe.currentIdentity, equals(service.currentModelIdentity));
      expect(identical(probe.currentIdentity, service.currentModelIdentity),
          isTrue,
          reason: 'probe surfaces the same constructor-bound identity '
              'instance, not a copy');
    });

    test('the probe result vector has the configured dimension', () async {
      final fake = _FakeOllamaHttpClient()..embedResponse = _ramp(768);
      final service = _newService(fake);

      final probe = await service.probeIdentity();

      expect(probe.probeResult.vec.dimension, 768);
      expect(probe.probeResult.modelIdentity,
          equals(service.currentModelIdentity));
    });

    test('driftEvent is null when previousIdentity is null', () async {
      final fake = _FakeOllamaHttpClient()..embedResponse = _ramp(768);
      final service = _newService(fake);

      final probe = await service.probeIdentity();

      expect(probe.driftEvent, isNull);
      expect(probe.driftDetected, isFalse);
    });

    test('driftEvent is null when previousIdentity equals currentIdentity',
        () async {
      final fake = _FakeOllamaHttpClient()..embedResponse = _ramp(768);
      final service = _newService(fake);

      // Construct a structurally-equal identity (different instance,
      // same fields) to confirm equality is structural, not identity.
      final structurallyEqual = const EmbeddingModelIdentity(
        providerId: 'ollama:local',
        modelId: 'nomic-embed-text',
        dims: 768,
        normalized: true,
      );
      expect(structurallyEqual, equals(service.currentModelIdentity));
      expect(identical(structurallyEqual, service.currentModelIdentity),
          isFalse);

      final probe = await service.probeIdentity(
        previousIdentity: structurallyEqual,
      );

      expect(probe.driftEvent, isNull);
      expect(probe.driftDetected, isFalse);
    });
  });

  group('B.27 / probeIdentity — drift detection', () {
    test('drift event fires when previous providerId differs', () async {
      final fake = _FakeOllamaHttpClient()..embedResponse = _ramp(768);
      final fixedNow = DateTime.utc(2026, 5, 31, 12, 0, 0);
      final service = _newService(fake, now: () => fixedNow);

      final previous = const EmbeddingModelIdentity(
        providerId: 'ollama:bomber', // differs
        modelId: 'nomic-embed-text',
        dims: 768,
        normalized: true,
      );

      final probe =
          await service.probeIdentity(previousIdentity: previous);

      expect(probe.driftEvent, isNotNull);
      expect(probe.driftEvent!.fromIdentity, equals(previous));
      expect(probe.driftEvent!.toIdentity,
          equals(service.currentModelIdentity));
      expect(probe.driftEvent!.occurredAt, equals(fixedNow));
      expect(probe.driftDetected, isTrue);
    });

    test('drift event fires when previous modelId differs', () async {
      final fake = _FakeOllamaHttpClient()..embedResponse = _ramp(768);
      final service = _newService(fake);

      final previous = const EmbeddingModelIdentity(
        providerId: 'ollama:local',
        modelId: 'bge-large', // differs
        dims: 768,
        normalized: true,
      );

      final probe =
          await service.probeIdentity(previousIdentity: previous);

      expect(probe.driftEvent, isNotNull);
      expect(probe.driftEvent!.fromIdentity.modelId, 'bge-large');
      expect(probe.driftEvent!.toIdentity.modelId, 'nomic-embed-text');
    });

    test('drift event fires when previous dims differs', () async {
      final fake = _FakeOllamaHttpClient()..embedResponse = _ramp(768);
      final service = _newService(fake);

      final previous = const EmbeddingModelIdentity(
        providerId: 'ollama:local',
        modelId: 'nomic-embed-text',
        dims: 384, // differs
        normalized: true,
      );

      final probe =
          await service.probeIdentity(previousIdentity: previous);

      expect(probe.driftEvent, isNotNull);
      expect(probe.driftEvent!.fromIdentity.dims, 384);
      expect(probe.driftEvent!.toIdentity.dims, 768);
    });

    test('drift event fires when previous normalized differs', () async {
      final fake = _FakeOllamaHttpClient()..embedResponse = _ramp(768);
      final service = _newService(fake);

      final previous = const EmbeddingModelIdentity(
        providerId: 'ollama:local',
        modelId: 'nomic-embed-text',
        dims: 768,
        normalized: false, // differs
      );

      final probe =
          await service.probeIdentity(previousIdentity: previous);

      expect(probe.driftEvent, isNotNull);
      expect(probe.driftEvent!.fromIdentity.normalized, isFalse);
      expect(probe.driftEvent!.toIdentity.normalized, isTrue);
    });

    test('drift event occurredAt comes from the injected clock', () async {
      final fake = _FakeOllamaHttpClient()..embedResponse = _ramp(768);
      // Clock that returns a distinct instant on each call so we can
      // pin which read populated the event.
      final timestamps = <DateTime>[
        DateTime.utc(2026, 1, 1, 0, 0, 0),
        DateTime.utc(2026, 2, 1, 0, 0, 0),
        DateTime.utc(2026, 3, 1, 0, 0, 0),
      ];
      var i = 0;
      final service = _newService(fake, now: () => timestamps[i++]);

      final previous = const EmbeddingModelIdentity(
        providerId: 'ollama:other',
        modelId: 'nomic-embed-text',
        dims: 768,
        normalized: true,
      );

      final probe =
          await service.probeIdentity(previousIdentity: previous);

      expect(probe.driftEvent, isNotNull);
      expect(probe.driftEvent!.occurredAt, equals(timestamps[0]));
      // Probe consumed exactly one tick — no drift means no clock read,
      // so a no-drift probe must not advance the counter.
      expect(i, 1,
          reason: 'clock is read exactly once per drift event');
    });

    test('no-drift probe does not read the clock', () async {
      final fake = _FakeOllamaHttpClient()..embedResponse = _ramp(768);
      var clockReads = 0;
      final service = _newService(fake, now: () {
        clockReads++;
        return DateTime.utc(2026, 5, 31);
      });

      // null previous ⇒ no drift ⇒ no clock read.
      await service.probeIdentity();
      expect(clockReads, 0);

      // structurally-equal previous ⇒ no drift ⇒ no clock read.
      await service.probeIdentity(
        previousIdentity: service.currentModelIdentity,
      );
      expect(clockReads, 0);
    });

    test('drift detection is purely structural — separate Identity '
        'instances with equal fields do not drift', () async {
      final fake = _FakeOllamaHttpClient()..embedResponse = _ramp(768);
      final service = _newService(fake);

      // The exact same fields as the constructor, freshly allocated.
      final twin = const EmbeddingModelIdentity(
        providerId: 'ollama:local',
        modelId: 'nomic-embed-text',
        dims: 768,
        normalized: true,
      );

      final probe = await service.probeIdentity(previousIdentity: twin);

      expect(probe.driftDetected, isFalse,
          reason: 'value-based equality on all four fields wins; '
              'instance identity is irrelevant for drift detection');
    });
  });

  group('B.27 / probeIdentity — wire path reuse', () {
    test('probe dispatches exactly one backend call', () async {
      final fake = _FakeOllamaHttpClient()..embedResponse = _ramp(768);
      final service = _newService(fake);

      await service.probeIdentity();

      expect(fake.embedCalls, hasLength(1));
    });

    test('probe sends the embedding model id, not the chat default',
        () async {
      final fake = _FakeOllamaHttpClient()..embedResponse = _ramp(768);
      final provider = _newProvider(
        httpClient: fake,
        defaultModel: 'gemma3:27b', // chat default — must not appear
      );
      final service = OllamaEmbeddingService(
        provider: provider,
        model: 'nomic-embed-text',
        dims: 768,
        normalize: true,
      );

      await service.probeIdentity();

      expect(fake.embedCalls.single.model, 'nomic-embed-text');
      expect(fake.chatCalls, isEmpty,
          reason: 'probe must not touch /api/chat');
    });

    test('probe uses the default probe text when none supplied', () async {
      final fake = _FakeOllamaHttpClient()..embedResponse = _ramp(768);
      final service = _newService(fake);

      await service.probeIdentity();

      // The default text from the interface is short, non-empty,
      // and deployment-independent. The exact wording is part of the
      // contract because it influences what gets logged at boot —
      // changing it is a contract change that requires bumping this
      // test.
      expect(fake.embedCalls.single.prompt, 'tom-brain embedding probe');
    });

    test('probe forwards a caller-supplied probe text verbatim', () async {
      final fake = _FakeOllamaHttpClient()..embedResponse = _ramp(768);
      final service = _newService(fake);

      await service.probeIdentity(probeText: 'custom probe seed');

      expect(fake.embedCalls.single.prompt, 'custom probe seed');
    });
  });

  group('B.27 / probeIdentity — backend defects surface verbatim', () {
    test('empty backend vector surfaces EmbeddingBackendEmpty', () async {
      final fake = _FakeOllamaHttpClient()..embedResponse = const <double>[];
      final service = _newService(fake);

      await expectLater(
        () => service.probeIdentity(),
        throwsA(isA<EmbeddingBackendEmpty>()
            .having((e) => e.expectedIdentity.modelId, 'modelId',
                'nomic-embed-text')),
      );
    });

    test('dimension mismatch surfaces EmbeddingDimensionMismatch '
        '(probe shares the dim check)', () async {
      final fake = _FakeOllamaHttpClient()..embedResponse = _ramp(384);
      final service = _newService(fake); // expects 768

      await expectLater(
        () => service.probeIdentity(),
        throwsA(isA<EmbeddingDimensionMismatch>()
            .having((e) => e.expectedIdentity.dims, 'expectedDims', 768)
            .having((e) => e.actualDims, 'actualDims', 384)),
      );
    });

    test('transport failure propagates verbatim', () async {
      final fake = _FakeOllamaHttpClient()
        ..embedException = OllamaHttpException(
          statusCode: 500,
          body: 'daemon down',
          endpoint: Uri.parse('http://127.0.0.1:11434/api/embeddings'),
        );
      final service = _newService(fake);

      await expectLater(
        () => service.probeIdentity(),
        throwsA(isA<OllamaHttpException>()
            .having((e) => e.statusCode, 'statusCode', 500)),
      );
    });

    test('backend defect surfaces even when previousIdentity is supplied '
        '(no silent swallowing into "no drift")', () async {
      // A backend-defect probe must NOT silently report "no drift" just
      // because the caller supplied a non-null previousIdentity. The
      // validation-vs-drift split in the contract: validation failures
      // throw; drift detection runs only on a successful round-trip.
      final fake = _FakeOllamaHttpClient()..embedResponse = const <double>[];
      final service = _newService(fake);

      final previous = const EmbeddingModelIdentity(
        providerId: 'ollama:other',
        modelId: 'bge-large',
        dims: 384,
        normalized: false,
      );

      await expectLater(
        () => service.probeIdentity(previousIdentity: previous),
        throwsA(isA<EmbeddingBackendEmpty>()),
      );
    });
  });

  group('B.27 / probeIdentity — identity stability across probes', () {
    test('repeated probe calls return the same identity instance', () async {
      final fake = _FakeOllamaHttpClient()..embedResponse = _ramp(768);
      final service = _newService(fake);

      final a = await service.probeIdentity();
      final b = await service.probeIdentity();
      final c = await service.probeIdentity();

      expect(identical(a.currentIdentity, b.currentIdentity), isTrue);
      expect(identical(b.currentIdentity, c.currentIdentity), isTrue);
      expect(a.currentIdentity, equals(service.currentModelIdentity));
    });

    test('detecting drift does NOT alter the service identity', () async {
      final fake = _FakeOllamaHttpClient()..embedResponse = _ramp(768);
      final service = _newService(fake);

      final pre = service.currentModelIdentity;

      // Trigger a drift event.
      await service.probeIdentity(
        previousIdentity: const EmbeddingModelIdentity(
          providerId: 'ollama:other',
          modelId: 'nomic-embed-text',
          dims: 768,
          normalized: true,
        ),
      );

      final post = service.currentModelIdentity;
      expect(identical(pre, post), isTrue,
          reason: 'drift is detected against the caller reference; '
              'the service identity is constructor-bound and never '
              'changes mid-process');
    });
  });

  group('B.27 / EmbeddingProbeResult — value-type contract', () {
    test('driftDetected mirrors driftEvent != null', () async {
      final fake = _FakeOllamaHttpClient()..embedResponse = _ramp(768);
      final service = _newService(fake);

      final noDrift = await service.probeIdentity();
      expect(noDrift.driftEvent, isNull);
      expect(noDrift.driftDetected, isFalse);

      final drift = await service.probeIdentity(
        previousIdentity: const EmbeddingModelIdentity(
          providerId: 'ollama:other',
          modelId: 'nomic-embed-text',
          dims: 768,
          normalized: true,
        ),
      );
      expect(drift.driftEvent, isNotNull);
      expect(drift.driftDetected, isTrue);
    });

    test('toString surfaces driftDetected for diagnostics', () async {
      final fake = _FakeOllamaHttpClient()..embedResponse = _ramp(768);
      final service = _newService(fake);

      final probe = await service.probeIdentity();
      expect(probe.toString(), contains('driftDetected=false'));
      expect(probe.toString(), contains('ollama:local'));
    });

    test('equality is structural across all fields '
        '(modulo drift-event timestamp)', () async {
      // Two no-drift probe results from the same service with the
      // same fake response compare equal even though the underlying
      // probe vectors and result wrappers are freshly allocated.
      final fake = _FakeOllamaHttpClient()..embedResponse = _ramp(8);
      final service = _newService(fake, dims: 8);

      final a = await service.probeIdentity();
      final b = await service.probeIdentity();

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });
  });

  group('B.27 / surface reachability', () {
    test('EmbeddingProbeResult ships through the top-level barrel', () {
      // Compile-only assertion — the symbol is reachable from the
      // package's public barrel without `package:foo/src/...`.
      expect(EmbeddingProbeResult, isNotNull);
    });

    test('the probe surface is part of the abstract EmbeddingService '
        'contract (binding consumers see it)', () async {
      final fake = _FakeOllamaHttpClient()..embedResponse = _ramp(768);
      // Bind through the abstract type — the surface the consumer
      // (memory) actually depends on.
      final EmbeddingService service = _newService(fake);

      final probe = await service.probeIdentity();
      expect(probe, isA<EmbeddingProbeResult>());
    });
  });
}

// ─── helpers ────────────────────────────────────────────────────────

OllamaEmbeddingService _newService(
  _FakeOllamaHttpClient fake, {
  int dims = 768,
  bool normalize = true,
  DateTime Function()? now,
}) {
  final provider = _newProvider(httpClient: fake);
  return OllamaEmbeddingService(
    provider: provider,
    model: 'nomic-embed-text',
    dims: dims,
    normalize: normalize,
    now: now,
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

/// Builds a length-[n] ramp vector. Used in dimension-passing tests
/// where the actual values do not matter, only the length.
List<double> _ramp(int n) =>
    List<double>.generate(n, (i) => i.toDouble(), growable: false);

// ─── test double (Ollama HTTP client) ───────────────────────────────

/// Minimal in-test [OllamaHttpClient] for the B.27 probe suite. Same
/// shape as the B.25 fake, with the bits this file needs.
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
