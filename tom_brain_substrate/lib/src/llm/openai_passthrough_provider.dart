// B.15 — `OpenAiPassthroughProvider`.
//
// Second concrete [LlmProvider] implementation (after B.14's
// `OllamaLlmProvider`). Talks the OpenAI-format Chat Completions /
// Embeddings dialect against any vendor that mirrors it
// (`substrate_specification.md` § 4.1: OpenAI itself plus OpenRouter,
// Groq, Cerebras, SambaNova, Together, Fireworks, …). The wire
// transport lives behind the [OpenAiHttpClient] seam (see
// `openai_http_client.dart` for the seam rationale, identical in
// spirit to B.14's `OllamaHttpClient`).
//
// What this file deliberately does NOT do (matching B.14):
//
//   - Classify failures into the `LlmFailure` taxonomy (spec § 5.4).
//     That lives at the router (B.18) with `LlmFailureClassifier`.
//     This provider lets backend exceptions surface verbatim — the
//     router catches them and decides retry / rotate / surface.
//   - Wrap the prompt body. `LlmProvider` contract (B.11): "Providers
//     MUST NOT prepend, append, or reorder the body of the prompt
//     they receive." The role registry (B.21+) has already prepended
//     the anchor to `WirePrompt.system`; this provider routes each
//     channel to its native OpenAI slot — `WirePrompt.system`
//     (anchor-first) as a `{role: 'system'}` message, `WirePrompt.user`
//     as a `{role: 'user'}` message — verbatim, in that order. The
//     system message is omitted only when `system` is empty.
//   - Compute / forward cost. The router-side price table (B.32+)
//     populates `LlmCallReport.cost` for paid providers; the provider
//     leaves it `null`.
//   - Resolve the model id. The router (B.18+) does the resolution
//     dance described on `LlmOptions.model`; the provider receives
//     the resolved id through `LlmOptions.model` and falls back to
//     its constructor-default if that is null.
//   - Rotate the bearer token. The router holds the rotation
//     policy (B.4 free-tier rotation); the provider holds *one* token
//     per construction. The B.18 cancellable variant will accept a
//     per-call token override.
//
// Why the provider takes the bearer at construction (rather than per
// call):
//
//   - It mirrors B.14's `OllamaLlmProvider` posture: one provider
//     instance per backend; the router wraps it for policy. The
//     B.4 free-tier rotation policy at the router constructs N
//     provider instances (one per credential) and rotates between
//     them — same shape as the Ollama-vs-OpenRouter rotation; not a
//     new mechanism.
//   - Per-call token injection at this layer would invite leaking
//     bearer values into the api/-layer `LlmOptions`, which is a
//     consumer-facing type. The token never reaches consumer-facing
//     surfaces — it stays inside the provider construction.

import 'dart:async';

import 'package:tom_llm/tom_llm.dart';
import 'http_llm_provider_base.dart';
import 'openai_http_client.dart';

/// `LlmProvider` against any OpenAI-format Chat Completions endpoint
/// (`https://api.openai.com/v1/`,
/// `https://openrouter.ai/api/v1/`,
/// `https://api.groq.com/openai/v1/`,
/// `https://api.cerebras.ai/v1/`, …).
///
/// Constructed once at substrate `open()` (B.40+); the router holds
/// it in its `providers` map keyed by [id]. The B.4 rotation
/// policy may construct several instances (one per bearer token /
/// per vendor base URL) and rotate between them.
///
/// **Anchor / provenance discipline.** Per `LlmProvider` contract
/// (B.11):
///
///   - Every emitted [LlmCallReport] has `anchorHash` =
///     `prompt.anchorHash`; `providerId` = this provider's [id];
///     `modelId` = the resolved model id (response echo wins;
///     fallback to `options.model` then [defaultModel]);
///     `promptHash` = sha256 of `prompt.combined`; `templateSha` =
///     `prompt.templateSha`.
///   - Streaming `completeStream` shape: exactly one
///     [LlmRunStarted], then one [LlmTextDelta] per non-empty
///     delta, then exactly one [LlmRunCompleted] when the SSE
///     stream's `[DONE]` sentinel arrives (or a content frame
///     carrying `finish_reason` closes the stream). Failures
///     terminate the stream with [LlmRunFailed].
///
/// **Cancellation.** Same posture as B.14: honoured on the streaming
/// path only (via [OpenAiHttpClient.chatStream]). B.18 wires a
/// router-mediated cancellable client that covers both paths
/// uniformly.
final class OpenAiPassthroughProvider extends HttpLlmProviderBase {
  /// Embedding model id used when [embedRaw] / [embedBatchRaw] do
  /// not receive an explicit model. Defaults to `null`, meaning a
  /// caller who has not configured an embedding model must pass one
  /// per call (or the call throws).
  final String? defaultEmbeddingModel;

  /// Bearer token sent as `Authorization: Bearer <apiKey>`. `null` ⇒
  /// no auth header (useful for self-hosted gateways and for
  /// observing test fakes).
  final String? apiKey;

  /// Extra headers merged onto every request (e.g. OpenRouter's
  /// `HTTP-Referer` / `X-Title`). Caller manages composition; this
  /// provider forwards them as-is.
  final Map<String, String> extraHeaders;

  /// HTTP seam (see [OpenAiHttpClient]).
  final OpenAiHttpClient httpClient;

  OpenAiPassthroughProvider({
    required super.id,
    required super.baseUri,
    required super.defaultModel,
    this.defaultEmbeddingModel,
    this.apiKey,
    this.extraHeaders = const <String, String>{},
    OpenAiHttpClient? httpClient,
    super.requestTimeout,
  }) : httpClient = httpClient ?? DefaultOpenAiHttpClient(),
       super(ownsHttpClient: httpClient == null);

  @override
  String get callIdPrefix => 'openai';

  @override
  Future<LlmCallReport> complete(LlmRequest request) async {
    final prompt = request.prompt;
    final options = request.options;
    final stopwatch = Stopwatch()..start();
    final modelId = options.model ?? defaultModel;
    final openAiOptions = _toOpenAiOptions(options);

    final response = await httpClient.chat(
      baseUri: baseUri,
      model: modelId,
      messages: _buildMessages(prompt),
      options: openAiOptions,
      apiKey: apiKey,
      extraHeaders: extraHeaders,
      requestTimeout: requestTimeout,
    );

    stopwatch.stop();

    return buildReport(
      prompt: prompt,
      modelId: response.model.isEmpty ? modelId : response.model,
      tokensIn: response.promptTokens ?? 0,
      tokensOut: response.completionTokens ?? 0,
      wallClockMs: stopwatch.elapsedMilliseconds,
      notes: _collectNotes(options, response),
    );
  }

  @override
  Stream<LlmEvent> run(LlmRequest request) async* {
    final prompt = request.prompt;
    final options = request.options;
    final stopwatch = Stopwatch()..start();
    final modelId = options.model ?? defaultModel;
    final openAiOptions = _toOpenAiOptions(options);
    final callId = newCallId(prompt);

    yield LlmRunStarted(
      purpose: request.purpose,
      callId: callId,
      providerId: id,
      modelId: modelId,
    );

    int? promptTokens;
    int? completionTokens;
    String? echoedModel;
    String? finishReason;

    try {
      await for (final frag in httpClient.chatStream(
        baseUri: baseUri,
        model: modelId,
        messages: _buildMessages(prompt),
        options: openAiOptions,
        apiKey: apiKey,
        extraHeaders: extraHeaders,
        requestTimeout: requestTimeout,
      )) {
        if (frag.contentDelta.isNotEmpty) {
          yield LlmTextDelta(frag.contentDelta);
        }
        if (frag.promptTokens != null) promptTokens = frag.promptTokens;
        if (frag.completionTokens != null) {
          completionTokens = frag.completionTokens;
        }
        if (frag.model.isNotEmpty) echoedModel = frag.model;
        if (frag.finishReason != null) finishReason = frag.finishReason;
      }

      // SSE closed (either via `[DONE]` sentinel or the underlying
      // stream end). Emit the terminal Completed event with what we
      // accumulated.
      stopwatch.stop();
      yield LlmRunCompleted(
        callId: callId,
        report: buildReport(
          prompt: prompt,
          modelId: echoedModel ?? modelId,
          tokensIn: promptTokens ?? 0,
          tokensOut: completionTokens ?? 0,
          wallClockMs: stopwatch.elapsedMilliseconds,
          notes: _collectStreamNotes(
            options: options,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            finishReason: finishReason,
          ),
        ),
      );
    } catch (e) {
      stopwatch.stop();
      yield LlmRunFailed(
        callId: callId,
        failure: LlmFailure(
          // Unclassified at B.15; B.18 maps onto the spec § 5.4 taxonomy.
          classCode: 'unknown',
          message: e.toString(),
          cause: e,
        ),
        report: buildReport(
          prompt: prompt,
          modelId: echoedModel ?? modelId,
          tokensIn: promptTokens ?? 0,
          tokensOut: completionTokens ?? 0,
          wallClockMs: stopwatch.elapsedMilliseconds,
        ),
      );
    }
  }

  // ─── Off-interface helpers (consumed at B.18 / B.25 / B.26) ──────

  /// Single-input `/v1/embeddings` call. Returns the model-native
  /// vector for [input].
  ///
  /// Not part of [LlmProvider] yet (spec § 4.1; B.25 / B.26 add the
  /// interface members). Exposed here so the embedding service can
  /// bind against it in the same change that grows the interface.
  Future<List<double>> embedRaw({required String input, String? model}) async {
    final resolved = model ?? defaultEmbeddingModel;
    if (resolved == null) {
      throw StateError(
        'OpenAiPassthroughProvider($id).embedRaw called without a model '
        'and no defaultEmbeddingModel was configured.',
      );
    }
    final response = await httpClient.embed(
      baseUri: baseUri,
      model: resolved,
      input: <String>[input],
      apiKey: apiKey,
      extraHeaders: extraHeaders,
      requestTimeout: requestTimeout,
    );
    if (response.embeddings.isEmpty) {
      throw StateError(
        'OpenAiPassthroughProvider($id): /v1/embeddings returned no data '
        'for a single-input request.',
      );
    }
    return response.embeddings.first;
  }

  /// Batch `/v1/embeddings` call. Returns one vector per element of
  /// [inputs], in the same order.
  Future<List<List<double>>> embedBatchRaw({
    required List<String> inputs,
    String? model,
  }) async {
    if (inputs.isEmpty) return const <List<double>>[];
    final resolved = model ?? defaultEmbeddingModel;
    if (resolved == null) {
      throw StateError(
        'OpenAiPassthroughProvider($id).embedBatchRaw called without a '
        'model and no defaultEmbeddingModel was configured.',
      );
    }
    final response = await httpClient.embed(
      baseUri: baseUri,
      model: resolved,
      input: inputs,
      apiKey: apiKey,
      extraHeaders: extraHeaders,
      requestTimeout: requestTimeout,
    );
    if (response.embeddings.length != inputs.length) {
      throw StateError(
        'OpenAiPassthroughProvider($id): /v1/embeddings returned '
        '${response.embeddings.length} vectors for ${inputs.length} inputs.',
      );
    }
    return response.embeddings;
  }

  /// Raw `/v1/models` call. Returns the vendor's exposed models.
  ///
  /// Not part of [LlmProvider] yet. Consumed by the router (B.18+)
  /// for health / model discovery.
  Future<List<OpenAiModelEntry>> listAvailableModels() {
    return httpClient.listModels(
      baseUri: baseUri,
      apiKey: apiKey,
      extraHeaders: extraHeaders,
      requestTimeout: requestTimeout,
    );
  }

  @override
  void disposeHttpClient() => httpClient.close();

  // ─── Internals ────────────────────────────────────────────────

  /// Maps the two-channel [WirePrompt] onto the OpenAI message list:
  /// the anchor-first `system` channel as a `{role: 'system'}` message
  /// (omitted when empty) followed by the call-specific `user` channel
  /// as a `{role: 'user'}` message — in that order, verbatim.
  List<OpenAiMessage> _buildMessages(WirePrompt prompt) {
    return <OpenAiMessage>[
      if (prompt.system.isNotEmpty)
        OpenAiMessage(role: 'system', content: prompt.system),
      OpenAiMessage(role: 'user', content: prompt.user),
    ];
  }

  OpenAiGenerationOptions _toOpenAiOptions(LlmOptions options) {
    return OpenAiGenerationOptions(
      temperature: options.temperature,
      maxOutputTokens: options.maxOutputTokens,
      stopSequences: options.stopSequences,
      responseFormat: options.responseFormat,
    );
  }

  /// Notes attached to a non-streaming [LlmCallReport].
  ///
  /// Surfaces only knobs that have a meaningful OpenAI mapping; the
  /// router (B.18+) adds its own notes (retry decisions, downgrade
  /// reasons) on top.
  List<String> _collectNotes(LlmOptions options, OpenAiChatResponse response) {
    final notes = <String>[];
    if (options.toolCatalogue.isNotEmpty) {
      // B.15 does not yet emit tool-call events; B.18 + B.27 wire
      // tool dispatch end-to-end.
      notes.add('tool_catalogue_present:not_yet_dispatched');
    }
    if (response.promptTokens == null) {
      notes.add('openai:prompt_tokens_missing');
    }
    if (response.completionTokens == null) {
      notes.add('openai:completion_tokens_missing');
    }
    if (response.finishReason != null &&
        response.finishReason != 'stop' &&
        response.finishReason != 'tool_calls') {
      notes.add('openai:finish_reason=${response.finishReason}');
    }
    return notes;
  }

  /// Notes attached to a streaming-path terminal [LlmCallReport].
  ///
  /// Streaming responses include usage only when
  /// `stream_options: {include_usage: true}` was honoured by the
  /// vendor; some self-hosted gateways drop the option and the
  /// counters stay null.
  List<String> _collectStreamNotes({
    required LlmOptions options,
    required int? promptTokens,
    required int? completionTokens,
    required String? finishReason,
  }) {
    final notes = <String>[];
    if (options.toolCatalogue.isNotEmpty) {
      notes.add('tool_catalogue_present:not_yet_dispatched');
    }
    if (promptTokens == null) {
      notes.add('openai:prompt_tokens_missing');
    }
    if (completionTokens == null) {
      notes.add('openai:completion_tokens_missing');
    }
    if (finishReason != null &&
        finishReason != 'stop' &&
        finishReason != 'tool_calls') {
      notes.add('openai:finish_reason=$finishReason');
    }
    return notes;
  }
}
