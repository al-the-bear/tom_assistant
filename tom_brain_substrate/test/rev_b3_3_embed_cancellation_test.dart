// Review fix B.3.3 — `embedRaw` honours a cancellation token, and
// `embedBatch` stops the remaining work cleanly on the first failure.
//
// `prototype_review_result.md` § B.3.3 flagged that
// `OllamaEmbeddingService.embedBatch` used `Future.wait(eagerError:
// true)` to surface the first per-input failure, but the surviving
// workers kept running every remaining backend call to completion and
// then silently discarded the results — there was no `embedRaw`-side
// cancellation. The fix threads a `CancellationToken` into `embedRaw`
// (the provider races the in-flight call against the token) and gives
// `embedBatch` a shared `CancellationTokenSource` it cancels on the
// first failure.
//
// These tests pin:
//   1. `embedRaw` returns normally when the token never fires.
//   2. `embedRaw` completes with `OperationCancelled` when the token
//      fires before the round-trip returns (the blocking backend call
//      is abandoned, not awaited).
//   3. `embedBatch` surfaces the *original* per-input failure (not a
//      sibling's cancellation) and still completes order-correctly on
//      the happy path.

import 'dart:async';

import 'package:test/test.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('B.3.3 / embedRaw honours the cancellation token', () {
    test('returns the vector when the token never cancels', () async {
      final http = _BlockingEmbedHttpClient()
        ..nextResponse = List<double>.filled(8, 0.5);
      final provider = OllamaLlmProvider(
        id: 'ollama',
        baseUri: Uri.parse('http://localhost:11434/'),
        defaultModel: 'gemma3:27b',
        httpClient: http,
      );

      final vec = await provider.embedRaw(prompt: 'hi', model: 'embed');
      expect(vec, hasLength(8));
    });

    test('completes with OperationCancelled when the token fires first',
        () async {
      final http = _BlockingEmbedHttpClient()..block = true;
      final provider = OllamaLlmProvider(
        id: 'ollama',
        baseUri: Uri.parse('http://localhost:11434/'),
        defaultModel: 'gemma3:27b',
        httpClient: http,
      );
      final cts = CancellationTokenSource();

      final future = provider.embedRaw(
        prompt: 'hi',
        model: 'embed',
        cancellationToken: cts.token,
      );
      // Let the call register, then cancel before the backend returns.
      await Future<void>.delayed(Duration.zero);
      cts.cancel();

      await expectLater(future, throwsA(isA<OperationCancelled>()));
      // The backend call was never released — the caller stopped
      // waiting on its own.
      expect(http.releaseCount, 0);
    });
  });

  group('B.3.3 / embedBatch stops cleanly on the first failure', () {
    test('surfaces the original transport failure, not a cancellation',
        () async {
      final failure = OllamaHttpException(
        statusCode: 500,
        body: 'boom',
        endpoint: Uri.parse('http://localhost:11434/api/embeddings'),
      );
      // First input fails fast; the rest would succeed. Concurrency > 1
      // so a sibling is in flight when the failure cancels the source.
      final http = _ScriptedEmbedHttpClient(
        failOnInput: 'in-0',
        failure: failure,
        okVector: List<double>.filled(4, 0.0),
        blockOnInputs: <String>{'in-1'},
      );
      final provider = OllamaLlmProvider(
        id: 'ollama',
        baseUri: Uri.parse('http://localhost:11434/'),
        defaultModel: 'gemma3:27b',
        httpClient: http,
      );
      final service = OllamaEmbeddingService(
        provider: provider,
        model: 'nomic-embed-text',
        dims: 4,
        normalize: false,
        batchConcurrency: 2,
      );

      await expectLater(
        service.embedBatch(<String>['in-0', 'in-1']),
        throwsA(isA<OllamaHttpException>()),
      );
    });

    test('happy path still returns one result per input in order', () async {
      // Encode the input index in vec[0] so we can check order.
      final http = _ScriptedEmbedHttpClient.indexEncoding(dims: 4);
      final provider = OllamaLlmProvider(
        id: 'ollama',
        baseUri: Uri.parse('http://localhost:11434/'),
        defaultModel: 'gemma3:27b',
        httpClient: http,
      );
      final service = OllamaEmbeddingService(
        provider: provider,
        model: 'nomic-embed-text',
        dims: 4,
        normalize: false,
        batchConcurrency: 3,
      );

      final results = await service.embedBatch(
        <String>['in-0', 'in-1', 'in-2', 'in-3'],
      );
      expect(results, hasLength(4));
      for (var i = 0; i < results.length; i++) {
        expect(results[i].vec.values.first, i.toDouble());
      }
    });
  });
}

// ─── Test helpers ────────────────────────────────────────────────

/// Fake whose `embed` either returns [nextResponse] immediately or, when
/// [block] is set, blocks on a completer the test never releases (so the
/// only way the call resolves is the caller abandoning it).
final class _BlockingEmbedHttpClient implements OllamaHttpClient {
  List<double> nextResponse = const <double>[];
  bool block = false;
  int releaseCount = 0;

  @override
  Future<List<double>> embed({
    required Uri baseUri,
    required String model,
    required String prompt,
    Duration? requestTimeout,
  }) async {
    if (block) {
      // Never completes; the embedRaw race must abandon it.
      await Completer<void>().future;
    }
    releaseCount++;
    return nextResponse;
  }

  @override
  Future<OllamaChatResponse> chat({
    required Uri baseUri,
    required String model,
    required List<OllamaMessage> messages,
    required OllamaGenerationOptions options,
    Duration? requestTimeout,
  }) =>
      throw UnimplementedError();

  @override
  Stream<OllamaStreamFragment> chatStream({
    required Uri baseUri,
    required String model,
    required List<OllamaMessage> messages,
    required OllamaGenerationOptions options,
    Duration? requestTimeout,
    CancellationToken? cancellationToken,
  }) =>
      throw UnimplementedError();

  @override
  Future<List<OllamaTagEntry>> listTags({
    required Uri baseUri,
    Duration? requestTimeout,
  }) =>
      throw UnimplementedError();

  @override
  void close() {}
}

/// Fake that fails on one input, optionally blocks on others, and
/// otherwise returns a constant vector. The `indexEncoding` factory
/// instead returns a vector whose `vec[0]` is the trailing integer of
/// the input id (so order can be asserted).
final class _ScriptedEmbedHttpClient implements OllamaHttpClient {
  final String? failOnInput;
  final Object? failure;
  final List<double> okVector;
  final Set<String> blockOnInputs;
  final bool encodeIndex;
  final int dims;

  _ScriptedEmbedHttpClient({
    this.failOnInput,
    this.failure,
    this.okVector = const <double>[],
    this.blockOnInputs = const <String>{},
  })  : encodeIndex = false,
        dims = okVector.length;

  _ScriptedEmbedHttpClient.indexEncoding({required this.dims})
      : failOnInput = null,
        failure = null,
        okVector = const <double>[],
        blockOnInputs = const <String>{},
        encodeIndex = true;

  @override
  Future<List<double>> embed({
    required Uri baseUri,
    required String model,
    required String prompt,
    Duration? requestTimeout,
  }) async {
    if (prompt == failOnInput) {
      // Fail after a microtask so a sibling is already in flight.
      await Future<void>.delayed(Duration.zero);
      throw failure!;
    }
    if (blockOnInputs.contains(prompt)) {
      await Completer<void>().future; // never completes
    }
    if (encodeIndex) {
      final match = RegExp(r'(\d+)$').firstMatch(prompt);
      final marker = match != null ? double.parse(match.group(1)!) : 0.0;
      final vec = List<double>.filled(dims, 0.0);
      vec[0] = marker;
      return vec;
    }
    return okVector;
  }

  @override
  Future<OllamaChatResponse> chat({
    required Uri baseUri,
    required String model,
    required List<OllamaMessage> messages,
    required OllamaGenerationOptions options,
    Duration? requestTimeout,
  }) =>
      throw UnimplementedError();

  @override
  Stream<OllamaStreamFragment> chatStream({
    required Uri baseUri,
    required String model,
    required List<OllamaMessage> messages,
    required OllamaGenerationOptions options,
    Duration? requestTimeout,
    CancellationToken? cancellationToken,
  }) =>
      throw UnimplementedError();

  @override
  Future<List<OllamaTagEntry>> listTags({
    required Uri baseUri,
    Duration? requestTimeout,
  }) =>
      throw UnimplementedError();

  @override
  void close() {}
}
