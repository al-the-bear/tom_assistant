// Plan-2 item 10 — `AnthropicHttpClient`: the narrow wire-shape seam
// between `AnthropicLlmProvider` and the underlying HTTP transport.
//
// `substrate_specification.md` § 4.1 lists the Anthropic Messages API as
// a cloud provider family alongside Ollama and the OpenAI-format
// passthrough. The Messages API differs from the OpenAI dialect in three
// ways this seam captures:
//
//   * Endpoint: `POST {baseUri}/v1/messages` for both non-streaming and
//     SSE streaming (streaming selected by `stream: true`).
//   * Auth: `x-api-key: <key>` + `anthropic-version: <date>` headers
//     (NOT `Authorization: Bearer …`). `anthropic-version` is REQUIRED.
//   * `max_tokens` is a REQUIRED request field; the provider supplies a
//     resolved value (`LlmOptions.maxOutputTokens` ?? provider default).
//
// The SSE event shape is a typed event stream rather than OpenAI's
// `choices[].delta` frames:
//
//   message_start         → carries `message.model` + `usage.input_tokens`
//   content_block_start    → opens a content block (text starts empty)
//   content_block_delta    → `delta.text` increments (the token stream)
//   content_block_stop     → closes a content block
//   message_delta          → carries `delta.stop_reason` + `usage.output_tokens`
//   message_stop           → terminal sentinel (closes the stream)
//
// Each SSE `data:` payload carries its own `type` discriminator, so this
// client dispatches on the JSON `type` field and ignores the
// (redundant) `event:` lines.
//
// Why a seam at all (mirroring `OpenAiHttpClient` at B.15):
//
//   * `AnthropicLlmProvider` must be testable without a live Anthropic
//     account. Hand-written fakes against this small interface are far
//     cheaper than `MockClient` against the raw `package:http` surface.
//   * The router layer can stack retry / circuit-breaker / credential
//     rotation policy *around* an `AnthropicHttpClient`, not inside the
//     provider.
//
// What this file deliberately does NOT own (same boundary as B.14/B.15):
//
//   * Retry / backoff / circuit-breaker policy — the router.
//   * Failure classification — the router maps the thrown
//     [AnthropicHttpException] (a [WireHttpException]) onto the spec
//     § 5.4 taxonomy via `LlmFailureClassifier`.
//   * Embeddings — the Messages API has none; embeddings come from the
//     Ollama embedding service (`runtime_preconditions.md` § 2).

import 'dart:convert';

import 'package:tom_brain_shared/tom_brain_shared.dart';
// Hide the top-level `decodeJsonObject`: this client relies on the richer
// inherited `DefaultWireHttpClientBase.decodeJsonObject` (status + endpoint
// + shape taxonomy). In Dart an imported top-level name shadows an
// inherited member, so it must be hidden for the instance method to bind.
import 'package:tom_core_agentic/tom_core_agentic.dart' hide decodeJsonObject;

import 'wire_http_transport.dart';

/// Narrow wire-shape interface to the Anthropic Messages API
/// (`/v1/messages`, non-streaming + SSE streaming).
///
/// Implemented by:
///
///   * [DefaultAnthropicHttpClient] — production. Wraps a
///     `package:http` `Client` (the same client
///     `tom_core_kernel.TomHttpClientFactory.getClient()` produces).
///   * Test fakes (e.g. `_FakeAnthropicHttpClient` in
///     `test/p2_10_anthropic_llm_provider_test.dart`).
///
/// Both methods MUST surface backend / transport failures as thrown
/// exceptions. The provider catches them and packages a typed envelope
/// (`classCode: 'unknown'`); the router reclassifies.
abstract class AnthropicHttpClient {
  /// One non-streaming `/v1/messages` round-trip.
  ///
  /// [model] is the resolved Anthropic model id (e.g.
  /// `claude-sonnet-4-20250514`). [system] is the standing framing
  /// (`WirePrompt.system`, anchor-first); it is sent as the Messages API
  /// top-level `system` field and is omitted from the request body when
  /// empty. [messages] is the conversation list — for the post-anchor wire
  /// prompt the substrate sends a single
  /// `{role: 'user', content: <WirePrompt.user>}` message. [apiKey] is
  /// sent as `x-api-key`; `null` ⇒ no auth header. [anthropicVersion] is
  /// sent as the REQUIRED `anthropic-version` header. [options] carries
  /// the (REQUIRED) `max_tokens` plus the optional knobs.
  Future<AnthropicChatResponse> message({
    required Uri baseUri,
    required String model,
    required List<AnthropicMessage> messages,
    required AnthropicGenerationOptions options,
    String system = '',
    String? apiKey,
    String anthropicVersion = '2023-06-01',
    Map<String, String> extraHeaders = const <String, String>{},
    Duration? requestTimeout,
  });

  /// Streaming `/v1/messages` — Anthropic SSE event stream. Emits one
  /// [AnthropicStreamFragment] per *meaningful* SSE data event
  /// (`message_start`, `content_block_delta`, `message_delta`); the
  /// structural events (`content_block_start` / `_stop`, `ping`,
  /// `message_stop`) are consumed and not emitted. The terminal
  /// `message_stop` event closes the stream cleanly.
  ///
  /// [system] is sent as the top-level `system` field (anchor-first,
  /// omitted when empty); [messages] carries the single
  /// `{role: 'user', content: <WirePrompt.user>}` message.
  Stream<AnthropicStreamFragment> messageStream({
    required Uri baseUri,
    required String model,
    required List<AnthropicMessage> messages,
    required AnthropicGenerationOptions options,
    String system = '',
    String? apiKey,
    String anthropicVersion = '2023-06-01',
    Map<String, String> extraHeaders = const <String, String>{},
    Duration? requestTimeout,
    CancellationToken? cancellationToken,
  });

  /// Releases any underlying HTTP client resources.
  void close();
}

/// One conversation message sent to `/v1/messages`.
///
/// Mirrors Anthropic's wire shape: `{role: 'user'|'assistant', content:
/// '...'}`. The substrate currently sends only one `user` message per
/// call (`WirePrompt.user`, the call-specific content); the list shape is
/// preserved for future multi-turn registries. The standing framing
/// (`WirePrompt.system`, anchor-first) is delivered through the Messages
/// API's separate top-level `system` field — see [AnthropicHttpClient.message]'s
/// `system` argument — and is therefore not modelled here.
final class AnthropicMessage {
  final String role;
  final String content;

  const AnthropicMessage({required this.role, required this.content});

  Map<String, Object?> toJson() => <String, Object?>{
        'role': role,
        'content': content,
      };
}

/// Generation knobs for `/v1/messages`.
///
/// [maxOutputTokens] maps to the REQUIRED `max_tokens` field — the
/// provider always supplies a value (`LlmOptions.maxOutputTokens` ?? the
/// provider's configured default). [temperature] and [stopSequences] map
/// to the optional `temperature` / `stop_sequences` fields.
///
/// The Messages API has no `response_format` field; the provider records
/// a note when a caller sets `LlmOptions.responseFormat`.
final class AnthropicGenerationOptions {
  /// Maps to the REQUIRED `max_tokens` field.
  final int maxOutputTokens;
  final double? temperature;
  final List<String> stopSequences;

  const AnthropicGenerationOptions({
    required this.maxOutputTokens,
    this.temperature,
    this.stopSequences = const <String>[],
  });

  /// Serialises the optional knobs into the request body slot.
  /// `max_tokens` is added by the body builder (it is required and
  /// non-nullable). Empty / null fields are omitted so the vendor
  /// default applies.
  Map<String, Object?> toJsonFragment() {
    final out = <String, Object?>{};
    if (temperature != null) out['temperature'] = temperature;
    if (stopSequences.isNotEmpty) out['stop_sequences'] = stopSequences;
    return out;
  }
}

/// Decoded `/v1/messages` non-streaming response.
///
/// [content] is the concatenation of every `text` block in the response
/// `content` array. [inputTokens] / [outputTokens] come from `usage`;
/// [stopReason] is the top-level `stop_reason` (`end_turn` / `max_tokens`
/// / `stop_sequence` / `tool_use`).
final class AnthropicChatResponse {
  final String model;
  final String content;
  final int? inputTokens;
  final int? outputTokens;
  final String? stopReason;

  const AnthropicChatResponse({
    required this.model,
    required this.content,
    this.inputTokens,
    this.outputTokens,
    this.stopReason,
  });
}

/// One frame decoded from an Anthropic SSE `/v1/messages` stream.
///
/// The fields are populated piecemeal across the event sequence:
///
///   * `message_start` → [model] + [inputTokens].
///   * `content_block_delta` → [textDelta].
///   * `message_delta` → [outputTokens] + [stopReason].
///
/// The provider accumulates these across the stream into the terminal
/// [AnthropicChatResponse]-equivalent report.
final class AnthropicStreamFragment {
  final String model;
  final String textDelta;
  final int? inputTokens;
  final int? outputTokens;
  final String? stopReason;

  const AnthropicStreamFragment({
    this.model = '',
    this.textDelta = '',
    this.inputTokens,
    this.outputTokens,
    this.stopReason,
  });
}

/// Thrown by [DefaultAnthropicHttpClient] when the endpoint answers with
/// a non-2xx status (or a malformed 2xx body / SSE frame — B.3.1).
///
/// The backend-family subtype of [WireHttpException]: it carries no
/// fields beyond the shared base, existing only to keep the "Anthropic
/// wire layer threw" signal that the trail reads. The router's
/// `LlmFailureClassifier` matches the [WireHttpException] supertype, so
/// the Anthropic family classifies identically to Ollama / OpenAI — that
/// is how the provider "registers in the failover taxonomy".
class AnthropicHttpException extends WireHttpException {
  AnthropicHttpException({
    required super.statusCode,
    required super.body,
    required super.endpoint,
  });

  @override
  String get label => 'AnthropicHttpException';
}

/// Production [AnthropicHttpClient] backed by a `package:http` `Client`.
///
/// When no `client` is injected the underlying `package:http.Client` is
/// acquired from `tom_core_kernel.TomHttpClientFactory` — the same
/// workspace-shared factory the OpenAI / Ollama clients use — so the
/// substrate keeps no parallel HTTP stack (spec § 11). Tests inject a
/// `MockClient` via `client:`, which takes precedence and is left for the
/// caller to close.
final class DefaultAnthropicHttpClient extends DefaultWireHttpClientBase
    implements AnthropicHttpClient {
  DefaultAnthropicHttpClient({super.client, super.factory});

  @override
  WireHttpException wireException({
    required int statusCode,
    required String body,
    required Uri endpoint,
  }) =>
      AnthropicHttpException(
        statusCode: statusCode,
        body: body,
        endpoint: endpoint,
      );

  @override
  Future<AnthropicChatResponse> message({
    required Uri baseUri,
    required String model,
    required List<AnthropicMessage> messages,
    required AnthropicGenerationOptions options,
    String system = '',
    String? apiKey,
    String anthropicVersion = '2023-06-01',
    Map<String, String> extraHeaders = const <String, String>{},
    Duration? requestTimeout,
  }) async {
    final url = baseUri.resolve('v1/messages');
    final response = await postJson(
      url: url,
      headers: _buildHeaders(
        apiKey: apiKey,
        anthropicVersion: anthropicVersion,
        extra: extraHeaders,
      ),
      jsonBody: _messageBody(
        model: model,
        system: system,
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
    return _decodeMessageResponse(decoded, fallbackModel: model);
  }

  @override
  Stream<AnthropicStreamFragment> messageStream({
    required Uri baseUri,
    required String model,
    required List<AnthropicMessage> messages,
    required AnthropicGenerationOptions options,
    String system = '',
    String? apiKey,
    String anthropicVersion = '2023-06-01',
    Map<String, String> extraHeaders = const <String, String>{},
    Duration? requestTimeout,
    CancellationToken? cancellationToken,
  }) async* {
    final url = baseUri.resolve('v1/messages');
    final lines = sendForLines(
      url: url,
      headers: <String, String>{
        ..._buildHeaders(
          apiKey: apiKey,
          anthropicVersion: anthropicVersion,
          extra: extraHeaders,
        ),
        'Accept': 'text/event-stream',
      },
      body: jsonEncode(_messageBody(
        model: model,
        system: system,
        messages: messages,
        options: options,
        stream: true,
      )),
      requestTimeout: requestTimeout,
    );

    await for (final line in lines) {
      if (cancellationToken?.isCancelled ?? false) {
        // Best-effort cancellation between frames; same posture as
        // B.14 / B.15. A transport-level cancellable client lands later.
        throw const WireStreamCancelled('Anthropic');
      }
      if (line.isEmpty) continue;
      if (!line.startsWith('data:')) {
        // Anthropic SSE interleaves `event:` lines with the `data:`
        // payloads; each data payload carries its own `type`
        // discriminator, so the `event:` lines are redundant. Skip
        // every non-`data:` line (comments, `event:`, `id:`, `retry:`).
        continue;
      }
      final payload = line.substring(5).trimLeft();
      if (payload.isEmpty) continue;
      final Object? decoded;
      try {
        decoded = jsonDecode(payload);
      } on FormatException catch (e) {
        // B.3.1 — a malformed SSE data payload is a wire corruption.
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

  /// Anthropic `/v1/messages` request body. `max_tokens` is required and
  /// always present. [system] is the top-level system prompt — included
  /// only when non-empty so a system-less call sends no `system` key.
  /// [stream] selects the SSE streaming response. The generation knobs are
  /// shared between both paths.
  Map<String, Object?> _messageBody({
    required String model,
    required String system,
    required List<AnthropicMessage> messages,
    required AnthropicGenerationOptions options,
    required bool stream,
  }) {
    return <String, Object?>{
      'model': model,
      'max_tokens': options.maxOutputTokens,
      if (system.isNotEmpty) 'system': system,
      'messages': messages.map((m) => m.toJson()).toList(growable: false),
      'stream': stream,
      ...options.toJsonFragment(),
    };
  }

  /// Composes `Content-Type` + `x-api-key` + `anthropic-version` + the
  /// caller-supplied extras. Extras take precedence so a caller can add
  /// `anthropic-beta` feature flags without this method enumerating them.
  Map<String, String> _buildHeaders({
    required String? apiKey,
    required String anthropicVersion,
    required Map<String, String> extra,
  }) {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'anthropic-version': anthropicVersion,
      if (apiKey != null && apiKey.isNotEmpty) 'x-api-key': apiKey,
    };
    headers.addAll(extra);
    return headers;
  }
}

AnthropicChatResponse _decodeMessageResponse(
  Map<String, Object?> json, {
  required String fallbackModel,
}) {
  final usage = JsonShape.readMapN(json, 'usage');
  return AnthropicChatResponse(
    model: JsonShape.readStringN(json, 'model') ?? fallbackModel,
    content: _concatTextBlocks(JsonShape.readListN(json, 'content')),
    inputTokens:
        usage == null ? null : JsonShape.readIntN(usage, 'input_tokens'),
    outputTokens:
        usage == null ? null : JsonShape.readIntN(usage, 'output_tokens'),
    stopReason: JsonShape.readStringN(json, 'stop_reason'),
  );
}

/// Concatenates the `text` field of every `{type: 'text', text: …}`
/// block in the Messages API `content` array. Non-text blocks (e.g.
/// `tool_use`) carry no prose and are skipped — tool dispatch is a later
/// step.
String _concatTextBlocks(List<Object?>? content) {
  if (content == null) return '';
  final buffer = StringBuffer();
  for (final block in content) {
    if (block is Map<String, Object?>) {
      if (JsonShape.readStringN(block, 'type') == 'text') {
        buffer.write(JsonShape.readString(block, 'text'));
      }
    }
  }
  return buffer.toString();
}

/// Decodes one SSE data frame into an [AnthropicStreamFragment]. Returns
/// `null` for structural-only events (`content_block_start` / `_stop`,
/// `ping`, `message_stop`) that carry no model / delta / usage signal.
AnthropicStreamFragment? _decodeStreamFragment(Map<String, Object?> json) {
  final type = JsonShape.readStringN(json, 'type');
  switch (type) {
    case 'message_start':
      final message = JsonShape.readMapN(json, 'message');
      if (message == null) return null;
      final usage = JsonShape.readMapN(message, 'usage');
      return AnthropicStreamFragment(
        model: JsonShape.readStringN(message, 'model') ?? '',
        inputTokens:
            usage == null ? null : JsonShape.readIntN(usage, 'input_tokens'),
        outputTokens:
            usage == null ? null : JsonShape.readIntN(usage, 'output_tokens'),
      );
    case 'content_block_delta':
      final delta = JsonShape.readMapN(json, 'delta');
      if (delta == null) return null;
      final text = JsonShape.readString(delta, 'text');
      if (text.isEmpty) return null;
      return AnthropicStreamFragment(textDelta: text);
    case 'message_delta':
      final delta = JsonShape.readMapN(json, 'delta');
      final usage = JsonShape.readMapN(json, 'usage');
      final stopReason =
          delta == null ? null : JsonShape.readStringN(delta, 'stop_reason');
      final outputTokens =
          usage == null ? null : JsonShape.readIntN(usage, 'output_tokens');
      if (stopReason == null && outputTokens == null) return null;
      return AnthropicStreamFragment(
        outputTokens: outputTokens,
        stopReason: stopReason,
      );
    default:
      // content_block_start / content_block_stop / ping / message_stop /
      // error — no fragment-worthy signal for the provider.
      return null;
  }
}
