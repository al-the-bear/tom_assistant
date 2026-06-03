// B.15 — `OpenAiHttpClient`: the narrow wire-shape seam between
// `OpenAiPassthroughProvider` and the underlying HTTP transport.
//
// substrate_specification.md § 4.1 lists OpenAI-format passthrough as
// the cloud-fallback provider family covering OpenAI itself plus every
// vendor that speaks the same Chat Completions / Embeddings dialect
// (OpenRouter, Groq, Cerebras, SambaNova, Together, Fireworks, …). All
// of them share three wire endpoints:
//
//   * `POST {baseUri}/v1/chat/completions` — non-streaming + SSE
//     streaming. Streaming is selected by `stream: true` in the
//     request body; the response is a Server-Sent-Events stream of
//     `data: { …delta JSON… }\n\n` lines terminated by the sentinel
//     `data: [DONE]\n\n`.
//   * `POST {baseUri}/v1/embeddings` — single-shot embedding (or
//     batch when `input` is a list). Returns
//     `{data: [{embedding: [...], index: 0}], usage: {prompt_tokens, total_tokens}}`.
//   * `GET {baseUri}/v1/models` — model discovery. Optional at B.15;
//     used by the router (B.18+) for health / route construction.
//
// Why a seam at all (mirroring `OllamaHttpClient` at B.14):
//
//   * `OpenAiPassthroughProvider` must be testable without a live
//     vendor account. Hand-written fakes against this small interface
//     are dramatically cheaper than `MockClient` against the raw
//     `package:http` surface.
//   * The router layer (B.18+) can stack retry / circuit-breaker /
//     bearer-rotation policy *around* an `OpenAiHttpClient`, not
//     inside the provider. The B.4 free-tier-rotation policy
//     specifically depends on this — the rotator swaps the seam's
//     bearer token between requests; the provider does not know.
//   * The B.46 anchor-conformance test exercises the provider against
//     a deterministic in-memory adapter (no network, no SSE parsing,
//     no `dart:io`).
//
// What this file deliberately does NOT own:
//
//   * Retry / backoff / circuit-breaker policy. Lives at the router
//     (B.18+).
//   * Bearer-token rotation. The seam carries *one* token per
//     request; the rotator at the router decides which token. The
//     production impl accepts the token at construction; the router's
//     B.18 cancellable variant will accept it per request.
//   * Failure classification. The provider re-throws / wraps with
//     `classCode: 'unknown'`; the router maps onto spec § 5.4.
//   * Cancellation-token wiring on the non-streaming path. Same
//     pattern as B.14: streaming-only at B.15; B.18 wires both paths.

import 'dart:convert';

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:tom_core_agentic/tom_core_agentic.dart';

import 'wire_http_transport.dart';

/// Narrow wire-shape interface to an OpenAI-format Chat Completions /
/// Embeddings endpoint (`/v1/chat/completions`, `/v1/embeddings`,
/// `/v1/models`).
///
/// Implemented by:
///
///   * [DefaultOpenAiHttpClient] — production. Wraps a
///     `package:http` `Client` (the same client
///     `tom_core_kernel.TomHttpClientFactory.getClient()` produces).
///     B.18+ replaces this with a retry-/rotation-aware variant; the
///     [OpenAiPassthroughProvider] code does not change.
///   * Test fakes (e.g. `_FakeOpenAiHttpClient` in
///     `test/b15_openai_passthrough_provider_test.dart`). Every B.15
///     test exercises the provider through a fake of this interface
///     so the suite has zero network dependency.
///
/// All four methods MUST surface backend / transport failures as
/// thrown exceptions. The provider catches them and packages a typed
/// envelope (router-layer classification lands at B.18 — until then
/// the provider re-throws / wraps with `classCode: 'unknown'`).
abstract class OpenAiHttpClient {
  /// One non-streaming `/v1/chat/completions` round-trip.
  ///
  /// [model] is the resolved OpenAI-format model id (e.g.
  /// `gpt-4o-mini`, `mistralai/mistral-7b-instruct`).
  /// [messages] is the OpenAI-format conversation list — for the
  /// post-anchor wire prompt the substrate sends a single
  /// `{role: 'user', content: <WirePrompt.body>}` message.
  /// [apiKey] is the bearer token for `Authorization: Bearer …`;
  /// `null` ⇒ no auth header (useful for self-hosted gateways).
  /// [options] carries provider-tunable knobs that translate to
  /// OpenAI's request fields (`temperature`, `max_tokens`, `stop`,
  /// `response_format`).
  /// [extraHeaders] is merged onto the request headers (e.g. for
  /// OpenRouter's `HTTP-Referer` / `X-Title` discoverability).
  /// [requestTimeout] caps the round-trip; `null` ⇒ no cap.
  Future<OpenAiChatResponse> chat({
    required Uri baseUri,
    required String model,
    required List<OpenAiMessage> messages,
    required OpenAiGenerationOptions options,
    String? apiKey,
    Map<String, String> extraHeaders = const <String, String>{},
    Duration? requestTimeout,
  });

  /// Streaming `/v1/chat/completions` — SSE response. The provider
  /// concatenates the `choices[0].delta.content` deltas to rebuild
  /// the full response and stamps the final frame's usage onto the
  /// `LlmCallReport`.
  ///
  /// The returned stream emits one [OpenAiStreamFragment] per parsed
  /// SSE data frame, in order. The terminal sentinel `data: [DONE]`
  /// closes the stream cleanly; an SSE frame whose `finish_reason`
  /// is non-null also marks the last content-bearing frame and
  /// (when `stream_options: {include_usage: true}` was sent) carries
  /// the usage counters.
  ///
  /// If [cancellationToken] cancels, the stream closes the underlying
  /// HTTP connection and the returned stream terminates with an
  /// error event whose exception class is `_OpenAiCancelled` (a
  /// `StateError`-equivalent until B.18 ships the typed classifier).
  Stream<OpenAiStreamFragment> chatStream({
    required Uri baseUri,
    required String model,
    required List<OpenAiMessage> messages,
    required OpenAiGenerationOptions options,
    String? apiKey,
    Map<String, String> extraHeaders = const <String, String>{},
    Duration? requestTimeout,
    CancellationToken? cancellationToken,
  });

  /// `/v1/embeddings`: produce the embedding for [input] under
  /// [model]. Returns one [OpenAiEmbeddingResponse] per [input]
  /// element. Dimensionality is determined by the model
  /// (`text-embedding-3-small` → 1536; `text-embedding-3-large` →
  /// 3072; OpenRouter-mirrored vendors typically expose their own).
  ///
  /// Both single-string and list-of-strings inputs go through this
  /// one method; the provider's `embedRaw` calls with a single-element
  /// list and unwraps, `embedBatchRaw` calls with the full list and
  /// returns all entries.
  Future<OpenAiEmbeddingResponse> embed({
    required Uri baseUri,
    required String model,
    required List<String> input,
    String? apiKey,
    Map<String, String> extraHeaders = const <String, String>{},
    Duration? requestTimeout,
  });

  /// `/v1/models`: list the models the endpoint exposes.
  ///
  /// Consumed by the router (B.18+) to decide which models to expose
  /// on the route chain. Today returns the raw decoded list; the
  /// router wraps it in its own `HealthSnapshot`. Optional at B.15;
  /// many self-hosted gateways stub this out.
  Future<List<OpenAiModelEntry>> listModels({
    required Uri baseUri,
    String? apiKey,
    Map<String, String> extraHeaders = const <String, String>{},
    Duration? requestTimeout,
  });

  /// Releases any underlying HTTP client resources.
  ///
  /// [DefaultOpenAiHttpClient.close] closes the `package:http` client
  /// it owns. Fakes that hold no resources implement this as a no-op.
  void close();
}

/// One conversation message sent to `/v1/chat/completions`.
///
/// Mirrors OpenAI's wire shape: `{role: 'user'|'system'|'assistant'|'tool',
/// content: '...'}`. The substrate currently sends only one message
/// per call (`role: 'user'` with the anchor-prefixed `WirePrompt.body`);
/// the list shape is preserved so multi-turn role registries (B.21+)
/// can compose conversations without churning this interface.
final class OpenAiMessage {
  final String role;
  final String content;

  const OpenAiMessage({required this.role, required this.content});

  Map<String, Object?> toJson() => <String, Object?>{
        'role': role,
        'content': content,
      };
}

/// Generation knobs for `/v1/chat/completions`.
///
/// Maps onto OpenAI's request fields: `temperature`, `max_tokens`,
/// `stop`, `response_format`. `LlmOptions.responseFormat` (when set)
/// translates into the top-level `response_format` JSON object.
///
/// All fields are nullable / empty-default so a "no knobs" call sends
/// the vendor-default generation policy.
final class OpenAiGenerationOptions {
  final double? temperature;
  final int? maxOutputTokens;
  final List<String> stopSequences;

  /// When non-null, sets `response_format` on the request — most OpenAI-
  /// format endpoints accept `{type: 'json_object'}` (lenient JSON
  /// mode) and a subset accept `{type: 'json_schema', json_schema: …}`
  /// (schema-enforced). Substrate maps `LlmOptions.responseFormat` to
  /// this field verbatim; if the vendor does not support a given
  /// shape, the router (B.18+) downgrades.
  final Map<String, Object?>? responseFormat;

  /// When true, sets `stream_options: {include_usage: true}` so the
  /// terminal SSE frame carries the usage counters. Always set on the
  /// streaming path; ignored on the non-streaming path.
  final bool includeUsageOnStream;

  const OpenAiGenerationOptions({
    this.temperature,
    this.maxOutputTokens,
    this.stopSequences = const <String>[],
    this.responseFormat,
    this.includeUsageOnStream = true,
  });

  /// All-defaults instance.
  static const OpenAiGenerationOptions empty = OpenAiGenerationOptions();

  /// Serialises into the OpenAI request body slot.
  ///
  /// Returns the fields that the caller merges into the request body
  /// alongside `model`, `messages`, and `stream`. Empty / null fields
  /// are omitted so the vendor-default applies.
  Map<String, Object?> toJsonFragment() {
    final out = <String, Object?>{};
    if (temperature != null) out['temperature'] = temperature;
    if (maxOutputTokens != null) out['max_tokens'] = maxOutputTokens;
    if (stopSequences.isNotEmpty) out['stop'] = stopSequences;
    if (responseFormat != null) out['response_format'] = responseFormat;
    return out;
  }
}

/// Decoded `/v1/chat/completions` non-streaming response.
///
/// Fields mirror OpenAI's response keys. `usage` may be absent on
/// some self-hosted gateways; the provider falls back to `0` and
/// notes the absence (mirroring B.14's Ollama handling).
final class OpenAiChatResponse {
  /// The model id the endpoint actually ran (echoes the request).
  final String model;

  /// The full assistant content for this turn (concatenation of
  /// `choices[0].message.content`).
  final String content;

  /// Tokens consumed from the prompt. `null` when the vendor did
  /// not report usage.
  final int? promptTokens;

  /// Tokens emitted in the response.
  final int? completionTokens;

  /// `choices[0].finish_reason` (`stop` / `length` / `tool_calls` /
  /// `content_filter` / `function_call`). Carried as a note on the
  /// report so the router can decide whether to retry on `length`.
  final String? finishReason;

  const OpenAiChatResponse({
    required this.model,
    required this.content,
    this.promptTokens,
    this.completionTokens,
    this.finishReason,
  });
}

/// One frame decoded from an SSE `/v1/chat/completions` streaming
/// response.
///
/// Intermediate frames carry [contentDelta] (string) and a `null`
/// [finishReason]. The terminal content frame carries `finishReason`
/// non-null. When `stream_options: {include_usage: true}` was sent,
/// an additional usage-only frame may follow (with empty
/// [contentDelta] and the [promptTokens] / [completionTokens] fields
/// populated). The sentinel `data: [DONE]` line is consumed by the
/// transport and is NOT emitted as a fragment.
final class OpenAiStreamFragment {
  final String model;
  final String contentDelta;
  final String? finishReason;
  final int? promptTokens;
  final int? completionTokens;

  const OpenAiStreamFragment({
    required this.model,
    required this.contentDelta,
    this.finishReason,
    this.promptTokens,
    this.completionTokens,
  });
}

/// Decoded `/v1/embeddings` response. Carries one vector per input
/// plus the usage counter.
final class OpenAiEmbeddingResponse {
  final String model;

  /// One vector per input. Order matches the request `input` array.
  final List<List<double>> embeddings;

  /// Tokens consumed across all inputs. `null` when the vendor did
  /// not report usage.
  final int? promptTokens;

  const OpenAiEmbeddingResponse({
    required this.model,
    required this.embeddings,
    this.promptTokens,
  });
}

/// One entry from `/v1/models`.
///
/// `id` is the model name; `ownedBy` is the vendor / namespace
/// (`openai`, `mistralai`, `anthropic`, …). The router pattern-matches
/// on `id` for now.
final class OpenAiModelEntry {
  final String id;
  final String? ownedBy;
  final int? createdEpochSeconds;

  const OpenAiModelEntry({
    required this.id,
    this.ownedBy,
    this.createdEpochSeconds,
  });
}

/// Thrown by [DefaultOpenAiHttpClient] when the endpoint answers with
/// a non-2xx status (or a malformed 2xx body / SSE frame — B.3.1).
///
/// The backend-family subtype of [WireHttpException]: it carries no
/// fields beyond the shared base, existing only to keep the
/// "OpenAI-format wire layer threw" signal that the trail and the B.3.1
/// conformance tests read. The router's `LlmFailureClassifier` matches
/// the [WireHttpException] supertype, so both families classify
/// identically.
class OpenAiHttpException extends WireHttpException {
  OpenAiHttpException({
    required super.statusCode,
    required super.body,
    required super.endpoint,
  });

  @override
  String get label => 'OpenAiHttpException';
}

/// Production [OpenAiHttpClient] backed by a `package:http` `Client`.
///
/// The client is acquired through `tom_core_kernel`'s
/// `TomHttpClientFactory.initialize` / `.getClient` — but for B.15 we
/// allow the caller to inject the `Client` directly so the
/// dependency-discipline test does not bind the substrate to the
/// kernel's static initialiser. The router-layer construction (B.18+
/// / B.40+) is what calls `TomHttpClientFactory.initialize` once at
/// substrate `open()`.
final class DefaultOpenAiHttpClient extends DefaultWireHttpClientBase
    implements OpenAiHttpClient {
  DefaultOpenAiHttpClient({super.client});

  @override
  WireHttpException wireException({
    required int statusCode,
    required String body,
    required Uri endpoint,
  }) =>
      OpenAiHttpException(
        statusCode: statusCode,
        body: body,
        endpoint: endpoint,
      );

  @override
  Future<OpenAiChatResponse> chat({
    required Uri baseUri,
    required String model,
    required List<OpenAiMessage> messages,
    required OpenAiGenerationOptions options,
    String? apiKey,
    Map<String, String> extraHeaders = const <String, String>{},
    Duration? requestTimeout,
  }) async {
    final url = baseUri.resolve('v1/chat/completions');
    final response = await postJson(
      url: url,
      headers: _buildHeaders(apiKey: apiKey, extra: extraHeaders),
      jsonBody: _chatBody(
        model: model,
        messages: messages,
        options: options,
        stream: false,
      ),
      requestTimeout: requestTimeout,
    );

    final decoded = decodeJsonObject(
      response.body,
      statusCode: response.statusCode,
      endpoint: url,
      shape: 'JSON object',
    );
    return _decodeChatResponse(decoded);
  }

  @override
  Stream<OpenAiStreamFragment> chatStream({
    required Uri baseUri,
    required String model,
    required List<OpenAiMessage> messages,
    required OpenAiGenerationOptions options,
    String? apiKey,
    Map<String, String> extraHeaders = const <String, String>{},
    Duration? requestTimeout,
    CancellationToken? cancellationToken,
  }) async* {
    final url = baseUri.resolve('v1/chat/completions');
    final lines = sendForLines(
      url: url,
      headers: <String, String>{
        ..._buildHeaders(apiKey: apiKey, extra: extraHeaders),
        'Accept': 'text/event-stream',
      },
      body: jsonEncode(_chatBody(
        model: model,
        messages: messages,
        options: options,
        stream: true,
      )),
      requestTimeout: requestTimeout,
    );

    await for (final line in lines) {
      if (cancellationToken?.isCancelled ?? false) {
        // Best-effort cancellation: B.18 wires a transport-level
        // cancellable variant. Same posture as B.14.
        throw const WireStreamCancelled('OpenAI');
      }
      if (line.isEmpty) continue;
      if (!line.startsWith('data:')) {
        // SSE spec allows comment lines (`:` prefix) and `event:` /
        // `id:` / `retry:` lines. None are used by the OpenAI Chat
        // Completions stream; skip them silently.
        continue;
      }
      final payload = line.substring(5).trimLeft();
      if (payload.isEmpty) continue;
      if (payload == '[DONE]') {
        // Terminal sentinel — consume and close the stream cleanly.
        return;
      }
      final Object? decoded;
      try {
        decoded = jsonDecode(payload);
      } on FormatException catch (e) {
        // B.3.1 — a malformed SSE data payload is a wire corruption.
        // Surface it as the typed wire exception (endpoint + payload
        // excerpt) so the router classifies it instead of letting a bare
        // `FormatException` escape the route-walk. The status is 2xx by
        // construction ([sendForLines] already threw otherwise).
        throw wireException(
          statusCode: 200,
          body: 'Malformed SSE data payload: ${e.message}. '
              'Payload: ${textPreview(payload)}',
          endpoint: url,
        );
      }
      if (decoded is! Map<String, Object?>) continue;
      final fragment = _decodeStreamFragment(decoded);
      if (fragment != null) yield fragment;
    }
  }

  @override
  Future<OpenAiEmbeddingResponse> embed({
    required Uri baseUri,
    required String model,
    required List<String> input,
    String? apiKey,
    Map<String, String> extraHeaders = const <String, String>{},
    Duration? requestTimeout,
  }) async {
    final url = baseUri.resolve('v1/embeddings');
    final response = await postJson(
      url: url,
      headers: _buildHeaders(apiKey: apiKey, extra: extraHeaders),
      // OpenAI accepts either a single string or a list of strings;
      // we always send the list shape — vendors uniformly support it
      // and it lets the embedding service (B.25/26) use one call for
      // both single and batch.
      jsonBody: <String, Object?>{'model': model, 'input': input},
      requestTimeout: requestTimeout,
    );

    final decoded = decodeJsonObject(
      response.body,
      statusCode: response.statusCode,
      endpoint: url,
      shape: '{data: [...]}',
    );
    if (decoded['data'] is! List) {
      throw wireException(
        statusCode: response.statusCode,
        body: 'Expected {data: [...]}, got: ${textPreview(response.body)}',
        endpoint: url,
      );
    }
    return _decodeEmbeddingResponse(decoded, fallbackModel: model);
  }

  @override
  Future<List<OpenAiModelEntry>> listModels({
    required Uri baseUri,
    String? apiKey,
    Map<String, String> extraHeaders = const <String, String>{},
    Duration? requestTimeout,
  }) async {
    final url = baseUri.resolve('v1/models');
    final response = await getUrl(
      url: url,
      headers: _buildHeaders(apiKey: apiKey, extra: extraHeaders),
      requestTimeout: requestTimeout,
    );

    final decoded = decodeJsonObject(
      response.body,
      statusCode: response.statusCode,
      endpoint: url,
      shape: '{data: [...]}',
    );
    if (decoded['data'] is! List) {
      throw wireException(
        statusCode: response.statusCode,
        body: 'Expected {data: [...]}, got: ${textPreview(response.body)}',
        endpoint: url,
      );
    }

    return JsonShape.readMapList(decoded, 'data')
        .map((m) => OpenAiModelEntry(
              id: JsonShape.readString(m, 'id'),
              ownedBy: JsonShape.readStringN(m, 'owned_by'),
              createdEpochSeconds: JsonShape.readIntN(m, 'created'),
            ))
        .toList(growable: false);
  }

  /// OpenAI `/v1/chat/completions` request body. [stream] selects the
  /// SSE streaming response (and, when [OpenAiGenerationOptions.includeUsageOnStream]
  /// is set, the `stream_options: {include_usage: true}` flag so the
  /// terminal frame carries the usage counters). The generation knobs
  /// are shared between the streaming and non-streaming paths.
  Map<String, Object?> _chatBody({
    required String model,
    required List<OpenAiMessage> messages,
    required OpenAiGenerationOptions options,
    required bool stream,
  }) {
    return <String, Object?>{
      'model': model,
      'messages': messages.map((m) => m.toJson()).toList(growable: false),
      'stream': stream,
      if (stream && options.includeUsageOnStream)
        'stream_options': <String, Object?>{'include_usage': true},
      ...options.toJsonFragment(),
    };
  }

  /// Composes `Content-Type` + optional `Authorization` + caller-supplied
  /// extras. Extras take precedence over the defaults so a caller can
  /// override `Content-Type` if a vendor needs a different MIME type.
  Map<String, String> _buildHeaders({
    required String? apiKey,
    required Map<String, String> extra,
  }) {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (apiKey != null && apiKey.isNotEmpty)
        'Authorization': 'Bearer $apiKey',
    };
    headers.addAll(extra);
    return headers;
  }
}

OpenAiChatResponse _decodeChatResponse(Map<String, Object?> json) {
  // The "choices" array is required by the OpenAI spec; missing /
  // empty / wrong-shape is a vendor-side bug — surface it as empty
  // content rather than throwing (the provider's `notes` will mark
  // the absence so the router can decide what to do).
  String content = '';
  String? finishReason;
  final choices = JsonShape.readListN(json, 'choices');
  if (choices != null && choices.isNotEmpty) {
    final first = choices.first;
    if (first is Map<String, Object?>) {
      final message = JsonShape.readMapN(first, 'message');
      if (message != null) {
        content = JsonShape.readString(message, 'content');
      }
      finishReason = JsonShape.readStringN(first, 'finish_reason');
    }
  }

  final usage = JsonShape.readMapN(json, 'usage');
  final promptTokens =
      usage == null ? null : JsonShape.readIntN(usage, 'prompt_tokens');
  final completionTokens =
      usage == null ? null : JsonShape.readIntN(usage, 'completion_tokens');

  return OpenAiChatResponse(
    model: JsonShape.readString(json, 'model'),
    content: content,
    promptTokens: promptTokens,
    completionTokens: completionTokens,
    finishReason: finishReason,
  );
}

/// Decodes one SSE data frame. Returns `null` when the frame carries
/// neither a content delta nor a finish_reason nor usage — i.e. when
/// it is structurally a frame but semantically empty (some vendors
/// emit role-only deltas on the first frame).
OpenAiStreamFragment? _decodeStreamFragment(Map<String, Object?> json) {
  String contentDelta = '';
  String? finishReason;
  final choices = JsonShape.readListN(json, 'choices');
  if (choices != null && choices.isNotEmpty) {
    final first = choices.first;
    if (first is Map<String, Object?>) {
      final delta = JsonShape.readMapN(first, 'delta');
      if (delta != null) {
        contentDelta = JsonShape.readString(delta, 'content');
      }
      finishReason = JsonShape.readStringN(first, 'finish_reason');
    }
  }

  final usage = JsonShape.readMapN(json, 'usage');
  final promptTokens =
      usage == null ? null : JsonShape.readIntN(usage, 'prompt_tokens');
  final completionTokens =
      usage == null ? null : JsonShape.readIntN(usage, 'completion_tokens');

  // Skip frames that carry nothing useful (role-only first frames).
  final hasContent = contentDelta.isNotEmpty;
  final hasFinish = finishReason != null;
  final hasUsage = promptTokens != null || completionTokens != null;
  if (!hasContent && !hasFinish && !hasUsage) return null;

  return OpenAiStreamFragment(
    model: JsonShape.readString(json, 'model'),
    contentDelta: contentDelta,
    finishReason: finishReason,
    promptTokens: promptTokens,
    completionTokens: completionTokens,
  );
}

OpenAiEmbeddingResponse _decodeEmbeddingResponse(
  Map<String, Object?> json, {
  required String fallbackModel,
}) {
  // Sort by `index` so the response order matches the request order
  // even if the vendor returns frames out of order (some do).
  final sorted = JsonShape.readMapList(json, 'data').toList(growable: false)
    ..sort((a, b) {
      final ai = JsonShape.readInt(a, 'index');
      final bi = JsonShape.readInt(b, 'index');
      return ai.compareTo(bi);
    });

  final embeddings = <List<double>>[];
  for (final entry in sorted) {
    final vec = JsonShape.readDoubleListN(entry, 'embedding');
    if (vec == null) {
      throw FormatException(
        'OpenAI embedding entry missing "embedding" array: $entry',
      );
    }
    embeddings.add(vec);
  }

  final usage = JsonShape.readMapN(json, 'usage');
  final promptTokens =
      usage == null ? null : JsonShape.readIntN(usage, 'prompt_tokens');

  return OpenAiEmbeddingResponse(
    model: JsonShape.readStringN(json, 'model') ?? fallbackModel,
    embeddings: embeddings,
    promptTokens: promptTokens,
  );
}
