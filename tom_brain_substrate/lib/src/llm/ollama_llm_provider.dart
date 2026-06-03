// B.14 — `OllamaLlmProvider`.
//
// First concrete [LlmProvider] implementation. Talks Ollama's
// `/api/chat` (non-streaming + streaming) through the [OllamaHttpClient]
// seam (see `ollama_http_client.dart` for the wire-shape rationale).
//
// Per `substrate_specification.md` § 4.1, the post-B.25 surface also
// includes `/api/embeddings` and `/api/tags`; both helpers ride on
// the same [OllamaHttpClient]. The `LlmProvider` interface does not
// yet declare `embed` / `embedBatch` / `health` (B.11 deliberately
// defers them until B.18 / B.25 / B.26); this provider exposes them
// as instance helpers (`embedRaw`, `listAvailableModels`) so the
// router and embedding service can bind against them in the same
// change that grows the interface, without churning Ollama-side code.
//
// What this file deliberately does NOT do:
//
//   - Classify failures into the `LlmFailure` taxonomy (spec § 5.4).
//     That lives at the router (B.18) with `LlmFailureClassifier`.
//     This provider lets backend exceptions surface verbatim — the
//     router catches them and decides retry / rotate / surface.
//   - Wrap the prompt body. `LlmProvider` contract (B.11): "Providers
//     MUST NOT prepend, append, or reorder the body of the prompt
//     they receive." The role registry (B.21+) has already prepended
//     the anchor; this provider sends `WirePrompt.body` to Ollama
//     verbatim as a single `{role: 'user', content: body}` message.
//   - Compute / forward cost. Ollama is local-only; cost is `null`.
//     The router-side price table (B.32+) populates cost for paid
//     providers; Ollama's report keeps `cost: null`.
//   - Resolve the model id. The router (B.18+) does the resolution
//     dance described on `LlmOptions.model`; the provider receives
//     the resolved id through `LlmOptions.model` and falls back to
//     its constructor-default if that is null.

import 'dart:async';

import '../api/cancellation.dart';
import '../api/llm_call.dart';
import '../api/llm_stream_event.dart';
import 'http_llm_provider_base.dart';
import 'ollama_http_client.dart';
import 'wire_prompt.dart';

/// `LlmProvider` against a running Ollama daemon (`localhost:11434`
/// by default).
///
/// Constructed once at substrate `open()` (B.40+); the router holds
/// it in its `providers` map keyed by [id].
///
/// **Anchor / provenance discipline.** Per `LlmProvider` contract
/// (B.11):
///
///   - Every emitted [LlmCallReport] has `anchorHash` =
///     `prompt.anchorHash`; `providerId` = this provider's [id];
///     `modelId` = the resolved model id (`options.model` ?? [defaultModel]);
///     `promptHash` = sha256 of `prompt.body`; `templateSha` =
///     `prompt.templateSha`.
///   - Non-streaming `completeStream` shape: exactly one
///     [LlmStreamStarted], then concatenated chunks (one per Ollama
///     NDJSON frame), then exactly one [LlmStreamCompleted]. Failures
///     terminate the stream with [LlmStreamFailed].
///
/// **Cancellation.** Cancellation tokens at B.14 are honoured on the
/// streaming path only (via [OllamaHttpClient.chatStream]). The
/// non-streaming `complete` path runs to completion or throws on
/// transport failure; B.18 wires a router-mediated cancellable client
/// that covers both paths uniformly.
final class OllamaLlmProvider extends HttpLlmProviderBase {
  /// HTTP seam (see [OllamaHttpClient]).
  final OllamaHttpClient httpClient;

  OllamaLlmProvider({
    required super.id,
    required super.baseUri,
    required super.defaultModel,
    OllamaHttpClient? httpClient,
    super.requestTimeout,
  })  : httpClient = httpClient ?? DefaultOllamaHttpClient(),
        super(ownsHttpClient: httpClient == null);

  @override
  String get callIdPrefix => 'ollama';

  @override
  Future<LlmCallReport> complete(
    WirePrompt prompt,
    LlmOptions options,
  ) async {
    final stopwatch = Stopwatch()..start();
    final modelId = options.model ?? defaultModel;
    final ollamaOptions = _toOllamaOptions(options);

    final response = await httpClient.chat(
      baseUri: baseUri,
      model: modelId,
      messages: <OllamaMessage>[
        OllamaMessage(role: 'user', content: prompt.body),
      ],
      options: ollamaOptions,
      requestTimeout: requestTimeout,
    );

    stopwatch.stop();

    return buildReport(
      prompt: prompt,
      modelId: response.model.isEmpty ? modelId : response.model,
      tokensIn: response.promptEvalCount ?? 0,
      tokensOut: response.evalCount ?? 0,
      wallClockMs: stopwatch.elapsedMilliseconds,
      notes: _collectNotes(options, response),
    );
  }

  @override
  Stream<LlmStreamEvent> completeStream(
    WirePrompt prompt,
    LlmOptions options,
  ) async* {
    final stopwatch = Stopwatch()..start();
    final modelId = options.model ?? defaultModel;
    final ollamaOptions = _toOllamaOptions(options);
    final callId = newCallId(prompt);

    yield LlmStreamStarted(
      callId: callId,
      providerId: id,
      modelId: modelId,
    );

    int? promptEval;
    int? eval;
    String? echoedModel;

    try {
      await for (final frag in httpClient.chatStream(
        baseUri: baseUri,
        model: modelId,
        messages: <OllamaMessage>[
          OllamaMessage(role: 'user', content: prompt.body),
        ],
        options: ollamaOptions,
        requestTimeout: requestTimeout,
      )) {
        if (frag.contentDelta.isNotEmpty) {
          yield LlmStreamChunk(callId: callId, text: frag.contentDelta);
        }
        if (frag.promptEvalCount != null) promptEval = frag.promptEvalCount;
        if (frag.evalCount != null) eval = frag.evalCount;
        if (frag.model.isNotEmpty) echoedModel = frag.model;
        if (frag.done) {
          stopwatch.stop();
          yield LlmStreamCompleted(
            callId: callId,
            report: buildReport(
              prompt: prompt,
              modelId: echoedModel ?? modelId,
              tokensIn: promptEval ?? 0,
              tokensOut: eval ?? 0,
              wallClockMs: stopwatch.elapsedMilliseconds,
              notes: _collectStreamNotes(options),
            ),
          );
          return;
        }
      }

      // Stream ended without a `done: true` frame — that is a
      // protocol-shape failure. Surface it.
      stopwatch.stop();
      yield LlmStreamFailed(
        callId: callId,
        failure: const LlmFailure(
          classCode: 'format',
          message:
              'Ollama stream ended without a terminal done=true frame.',
        ),
        report: buildReport(
          prompt: prompt,
          modelId: echoedModel ?? modelId,
          tokensIn: promptEval ?? 0,
          tokensOut: eval ?? 0,
          wallClockMs: stopwatch.elapsedMilliseconds,
        ),
      );
    } catch (e) {
      stopwatch.stop();
      yield LlmStreamFailed(
        callId: callId,
        failure: LlmFailure(
          // Unclassified at B.14; B.18 maps onto the spec § 5.4 taxonomy.
          classCode: 'unknown',
          message: e.toString(),
          cause: e,
        ),
        report: buildReport(
          prompt: prompt,
          modelId: echoedModel ?? modelId,
          tokensIn: promptEval ?? 0,
          tokensOut: eval ?? 0,
          wallClockMs: stopwatch.elapsedMilliseconds,
        ),
      );
    }
  }

  // ─── Off-interface helpers (consumed at B.18 / B.25) ──────────

  /// Raw `/api/embeddings` call. Returns the model-native vector.
  ///
  /// Not part of [LlmProvider] yet (spec § 4.1; B.25 / B.26 add the
  /// interface members). Exposed here so the embedding service can
  /// bind against it in the same change that grows the interface.
  ///
  /// When [cancellationToken] signals before the round-trip completes,
  /// the returned future completes with [OperationCancelled] and the
  /// in-flight HTTP result is abandoned. (`package:http`'s standard
  /// `Client` has no per-request abort handle — the socket is left to
  /// the daemon to finish — but the caller stops waiting, which is what
  /// lets `OllamaEmbeddingService.embedBatch` halt the remaining
  /// workers on the first per-input failure instead of running every
  /// call to completion and discarding the results.)
  Future<List<double>> embedRaw({
    required String prompt,
    String? model,
    CancellationToken cancellationToken = CancellationToken.none,
  }) {
    final call = httpClient.embed(
      baseUri: baseUri,
      model: model ?? defaultModel,
      prompt: prompt,
      requestTimeout: requestTimeout,
    );
    if (identical(cancellationToken, CancellationToken.none)) {
      return call;
    }
    return _raceCancellation(call, cancellationToken);
  }

  /// Resolves with [work]'s result, or with [OperationCancelled] if
  /// [token] signals first. The loser of the race is abandoned; its
  /// eventual completion is observed (so it never surfaces as an
  /// unhandled async error) but ignored.
  static Future<T> _raceCancellation<T>(
    Future<T> work,
    CancellationToken token,
  ) {
    final completer = Completer<T>();
    work.then(
      (value) {
        if (!completer.isCompleted) completer.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (!completer.isCompleted) completer.completeError(error, stack);
      },
    );
    token.whenCancelled.then((_) {
      if (!completer.isCompleted) {
        completer.completeError(const OperationCancelled('embedRaw'));
      }
    });
    return completer.future;
  }

  /// Raw `/api/tags` call. Returns the daemon's installed models.
  ///
  /// Not part of [LlmProvider] yet. Consumed by the router (B.18+)
  /// for health / model discovery; consumed by the substrate boot
  /// path to validate that `defaults.model` is actually installed.
  Future<List<OllamaTagEntry>> listAvailableModels() {
    return httpClient.listTags(
      baseUri: baseUri,
      requestTimeout: requestTimeout,
    );
  }

  @override
  void disposeHttpClient() => httpClient.close();

  // ─── Internals ────────────────────────────────────────────────

  OllamaGenerationOptions _toOllamaOptions(LlmOptions options) {
    return OllamaGenerationOptions(
      temperature: options.temperature,
      maxOutputTokens: options.maxOutputTokens,
      stopSequences: options.stopSequences,
      jsonFormat: options.responseFormat != null,
    );
  }

  /// Notes attached to a non-streaming [LlmCallReport].
  ///
  /// Surfaces only knobs that have a meaningful Ollama mapping; the
  /// router (B.18+) adds its own notes (retry decisions, downgrade
  /// reasons) on top.
  List<String> _collectNotes(
    LlmOptions options,
    OllamaChatResponse response,
  ) {
    final notes = <String>[];
    if (options.toolCatalogue.isNotEmpty) {
      // B.14 does not yet emit tool-call events on the non-streaming
      // path; B.18 + B.27 wire tool dispatch end-to-end.
      notes.add('tool_catalogue_present:not_yet_dispatched');
    }
    if (response.promptEvalCount == null) {
      notes.add('ollama:prompt_eval_count_missing');
    }
    if (response.evalCount == null) {
      notes.add('ollama:eval_count_missing');
    }
    return notes;
  }

  /// Notes attached to a streaming-path terminal [LlmCallReport].
  ///
  /// Streaming responses always include the eval counters in the
  /// terminal frame, so the "missing" notes do not apply.
  List<String> _collectStreamNotes(LlmOptions options) {
    final notes = <String>[];
    if (options.toolCatalogue.isNotEmpty) {
      notes.add('tool_catalogue_present:not_yet_dispatched');
    }
    return notes;
  }
}
