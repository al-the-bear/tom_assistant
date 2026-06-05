// Plan-2 item 10 — `AnthropicLlmProvider`.
//
// Third concrete [LlmProvider] implementation (after B.14's
// `OllamaLlmProvider` and B.15's `OpenAiPassthroughProvider`). Talks the
// Anthropic Messages API (`POST /v1/messages`, `x-api-key`,
// `anthropic-version`) against api.anthropic.com (or any compatible
// gateway). The wire transport lives behind the [AnthropicHttpClient]
// seam (see `anthropic_http_client.dart` for the seam rationale).
//
// What this file deliberately does NOT do (matching B.14 / B.15):
//
//   - Classify failures into the `LlmFailure` taxonomy (spec § 5.4).
//     That lives at the router with `LlmFailureClassifier`, which maps
//     the thrown [AnthropicHttpException] (a [WireHttpException]) onto
//     the taxonomy. The provider lets backend exceptions surface
//     verbatim on the non-streaming path, and packages an
//     `classCode: 'unknown'` envelope on the streaming path; the router
//     reclassifies.
//   - Wrap the prompt body. `LlmProvider` contract (B.11): the role
//     registry has already prepended the assistant-dedication anchor;
//     this provider sends `WirePrompt.body` to the vendor verbatim as a
//     single `{role: 'user', content: body}` message.
//   - Compute / forward cost, resolve the model id, or rotate the
//     credential — all router responsibilities (same split as B.15).
//
// Messages-API specifics this provider owns:
//
//   - `max_tokens` is REQUIRED. The provider resolves it as
//     `LlmOptions.maxOutputTokens` ?? [defaultMaxOutputTokens] so the
//     wire call always carries a value.
//   - `response_format` has no Messages-API equivalent; a caller that
//     sets `LlmOptions.responseFormat` gets an
//     `anthropic:response_format_unsupported` note rather than a
//     silently dropped field.
//   - Anthropic stop reasons are `end_turn` / `max_tokens` /
//     `stop_sequence` / `tool_use`. `end_turn` and `tool_use` are the
//     non-anomalous terminals; any other stop reason is surfaced as a
//     note.

import 'dart:async';

import '../api/llm_call.dart';
import '../api/llm_stream_event.dart';
import 'anthropic_http_client.dart';
import 'http_llm_provider_base.dart';
import 'wire_prompt.dart';

/// `LlmProvider` against the Anthropic Messages API
/// (`https://api.anthropic.com/v1/messages`).
///
/// Constructed once at substrate `open()`; the router holds it in its
/// `providers` map keyed by [id]. Credential rotation (B.4) may
/// construct several instances (one per `x-api-key`) and rotate between
/// them — same shape as the OpenAI passthrough.
///
/// **Anchor / provenance discipline.** Per `LlmProvider` contract:
/// every emitted [LlmCallReport] has `anchorHash` = `prompt.anchorHash`,
/// `providerId` = [id], `modelId` = the resolved model id (response echo
/// wins; fallback to `options.model` then [defaultModel]), `promptHash`
/// = sha256 of `prompt.body`, `templateSha` = `prompt.templateSha`.
///
/// **Streaming shape.** Exactly one [LlmStreamStarted], then one
/// [LlmStreamChunk] per non-empty `content_block_delta`, then exactly
/// one [LlmStreamCompleted] when the SSE stream closes (`message_stop`).
/// Failures terminate the stream with [LlmStreamFailed].
final class AnthropicLlmProvider extends HttpLlmProviderBase {
  /// Sent as the `x-api-key` header. `null` / empty ⇒ no auth header
  /// (useful for self-hosted gateways and for observing test fakes).
  final String? apiKey;

  /// Sent as the REQUIRED `anthropic-version` header.
  final String anthropicVersion;

  /// `max_tokens` value used when [LlmOptions.maxOutputTokens] is null.
  /// The Messages API requires `max_tokens`, so the provider always
  /// supplies a resolved value.
  final int defaultMaxOutputTokens;

  /// Extra headers merged onto every request (e.g. `anthropic-beta`
  /// feature flags). Caller manages composition; forwarded as-is.
  final Map<String, String> extraHeaders;

  /// HTTP seam (see [AnthropicHttpClient]).
  final AnthropicHttpClient httpClient;

  AnthropicLlmProvider({
    required super.id,
    required super.baseUri,
    required super.defaultModel,
    this.apiKey,
    this.anthropicVersion = '2023-06-01',
    this.defaultMaxOutputTokens = 4096,
    this.extraHeaders = const <String, String>{},
    AnthropicHttpClient? httpClient,
    super.requestTimeout,
  })  : httpClient = httpClient ?? DefaultAnthropicHttpClient(),
        super(ownsHttpClient: httpClient == null);

  @override
  String get callIdPrefix => 'anthropic';

  @override
  Future<LlmCallReport> complete(
    WirePrompt prompt,
    LlmOptions options,
  ) async {
    final stopwatch = Stopwatch()..start();
    final modelId = options.model ?? defaultModel;
    final anthropicOptions = _toAnthropicOptions(options);

    final response = await httpClient.message(
      baseUri: baseUri,
      model: modelId,
      messages: <AnthropicMessage>[
        AnthropicMessage(role: 'user', content: prompt.body),
      ],
      options: anthropicOptions,
      apiKey: apiKey,
      anthropicVersion: anthropicVersion,
      extraHeaders: extraHeaders,
      requestTimeout: requestTimeout,
    );

    stopwatch.stop();

    return buildReport(
      prompt: prompt,
      modelId: response.model.isEmpty ? modelId : response.model,
      tokensIn: response.inputTokens ?? 0,
      tokensOut: response.outputTokens ?? 0,
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
    final anthropicOptions = _toAnthropicOptions(options);
    final callId = newCallId(prompt);

    yield LlmStreamStarted(
      callId: callId,
      providerId: id,
      modelId: modelId,
    );

    int? inputTokens;
    int? outputTokens;
    String? echoedModel;
    String? stopReason;

    try {
      await for (final frag in httpClient.messageStream(
        baseUri: baseUri,
        model: modelId,
        messages: <AnthropicMessage>[
          AnthropicMessage(role: 'user', content: prompt.body),
        ],
        options: anthropicOptions,
        apiKey: apiKey,
        anthropicVersion: anthropicVersion,
        extraHeaders: extraHeaders,
        requestTimeout: requestTimeout,
      )) {
        if (frag.textDelta.isNotEmpty) {
          yield LlmStreamChunk(callId: callId, text: frag.textDelta);
        }
        if (frag.inputTokens != null) inputTokens = frag.inputTokens;
        if (frag.outputTokens != null) outputTokens = frag.outputTokens;
        if (frag.model.isNotEmpty) echoedModel = frag.model;
        if (frag.stopReason != null) stopReason = frag.stopReason;
      }

      stopwatch.stop();
      yield LlmStreamCompleted(
        callId: callId,
        report: buildReport(
          prompt: prompt,
          modelId: echoedModel ?? modelId,
          tokensIn: inputTokens ?? 0,
          tokensOut: outputTokens ?? 0,
          wallClockMs: stopwatch.elapsedMilliseconds,
          notes: _collectStreamNotes(
            options: options,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            stopReason: stopReason,
          ),
        ),
      );
    } catch (e) {
      stopwatch.stop();
      yield LlmStreamFailed(
        callId: callId,
        failure: LlmFailure(
          // Unclassified here; the router maps onto the spec § 5.4 taxonomy.
          classCode: 'unknown',
          message: e.toString(),
          cause: e,
        ),
        report: buildReport(
          prompt: prompt,
          modelId: echoedModel ?? modelId,
          tokensIn: inputTokens ?? 0,
          tokensOut: outputTokens ?? 0,
          wallClockMs: stopwatch.elapsedMilliseconds,
        ),
      );
    }
  }

  @override
  void disposeHttpClient() => httpClient.close();

  // ─── Internals ────────────────────────────────────────────────

  AnthropicGenerationOptions _toAnthropicOptions(LlmOptions options) {
    return AnthropicGenerationOptions(
      maxOutputTokens: options.maxOutputTokens ?? defaultMaxOutputTokens,
      temperature: options.temperature,
      stopSequences: options.stopSequences,
    );
  }

  /// Notes attached to a non-streaming [LlmCallReport].
  List<String> _collectNotes(
    LlmOptions options,
    AnthropicChatResponse response,
  ) {
    final notes = <String>[];
    if (options.toolCatalogue.isNotEmpty) {
      notes.add('tool_catalogue_present:not_yet_dispatched');
    }
    if (options.responseFormat != null) {
      notes.add('anthropic:response_format_unsupported');
    }
    if (response.inputTokens == null) {
      notes.add('anthropic:input_tokens_missing');
    }
    if (response.outputTokens == null) {
      notes.add('anthropic:output_tokens_missing');
    }
    _addStopReasonNote(notes, response.stopReason);
    return notes;
  }

  /// Notes attached to a streaming-path terminal [LlmCallReport].
  List<String> _collectStreamNotes({
    required LlmOptions options,
    required int? inputTokens,
    required int? outputTokens,
    required String? stopReason,
  }) {
    final notes = <String>[];
    if (options.toolCatalogue.isNotEmpty) {
      notes.add('tool_catalogue_present:not_yet_dispatched');
    }
    if (options.responseFormat != null) {
      notes.add('anthropic:response_format_unsupported');
    }
    if (inputTokens == null) {
      notes.add('anthropic:input_tokens_missing');
    }
    if (outputTokens == null) {
      notes.add('anthropic:output_tokens_missing');
    }
    _addStopReasonNote(notes, stopReason);
    return notes;
  }

  /// Records a `anthropic:stop_reason=<x>` note for any stop reason that
  /// is not a non-anomalous terminal (`end_turn`, `tool_use`). `null`
  /// (stream closed without a usage frame carrying the reason) is not
  /// noteworthy.
  void _addStopReasonNote(List<String> notes, String? stopReason) {
    if (stopReason != null &&
        stopReason != 'end_turn' &&
        stopReason != 'tool_use') {
      notes.add('anthropic:stop_reason=$stopReason');
    }
  }
}
