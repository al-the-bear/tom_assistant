// B.14 — `OllamaHttpClient`: the narrow wire-shape seam between
// `OllamaLlmProvider` and the underlying HTTP transport.
//
// substrate_specification.md § 4.1 names Ollama's three endpoints
// (`/api/chat`, `/api/embeddings`, `/api/tags`). Plan step B.14 wires
// `OllamaLlmProvider` against `/api/chat` (non-streaming + streaming)
// and lays in the typed helpers for the two endpoints that future
// steps consume (`/api/embeddings` → B.25 embedding service;
// `/api/tags` → B.18 router health / model discovery). Keeping all
// three helpers on this one wire-shape interface — even though only
// `chat*` is invoked at B.14 — means:
//
//   - B.25 and B.18 do not need to add a second HTTP seam later;
//     they bind to the helper that B.14 already shipped and
//     test-doubled.
//   - The dependency-discipline test (`test/dependency_surface_test.dart`)
//     can prove there is a single HTTP entry into Ollama for the
//     whole substrate.
//
// Why a seam at all (vs. calling `package:http` or
// `tom_core_kernel.TomServerCall` directly inside the provider):
//
//   - `OllamaLlmProvider` must be testable without binding a port.
//     Mocktail / hand-written fakes against this small interface are
//     dramatically cheaper than spinning a fake `HttpServer` or a
//     `MockClient` against the raw `package:http` surface.
//   - The provider then has no `dart:io` dependency at all (the
//     `_default` implementation does); B.46's anchor-conformance test
//     can therefore exercise the provider against a deterministic
//     in-memory adapter.
//   - The router layer (B.18+) can stack retry / circuit-breaker
//     policy *around* an `OllamaHttpClient`, not inside the provider.
//     That keeps `OllamaLlmProvider` focused on the protocol shape.
//
// What this file deliberately does NOT own:
//
//   - The retry / backoff / circuit-breaker policy. Lives at the
//     router (B.18+). The seam exposes a transport that *can fail*
//     and the router decides what to do about it.
//   - Bearer-token auth. Ollama's local API does not authenticate;
//     OpenAI passthrough (B.15) has its own wire-shape seam with
//     `Authorization: Bearer …` plumbing through
//     `tom_core_server.TomBearerAuthentication`.
//   - Cancellation token wiring. Per B.11 spec, cancellation arrives
//     through a router-mediated channel that lands at B.18. The
//     B.14 surface accepts an optional `CancellationToken` so the
//     provider has a one-line wire-up at B.18; today it is honoured
//     only on the streaming path (where the consumer can race the
//     stream against `token.whenCancelled`).

import 'dart:convert';

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:tom_core_agentic/tom_core_agentic.dart';

import 'wire_http_transport.dart';

/// Narrow wire-shape interface to a running Ollama daemon
/// (`/api/chat`, `/api/embeddings`, `/api/tags`).
///
/// Implemented by:
///
///   - [DefaultOllamaHttpClient] — production. Wraps a
///     `package:http` `Client` (which `tom_core_kernel`'s
///     `TomHttpClientFactory` produces). B.18+ replaces this with a
///     retry/circuit-breaker-aware variant; the [OllamaLlmProvider]
///     code does not change.
///   - Test fakes (e.g. `_FakeOllamaHttpClient` in
///     `test/b14_ollama_llm_provider_test.dart`). Mandatory: every
///     B.14 test exercises the provider through a fake of this
///     interface so the suite has zero network dependency.
///
/// All four methods MUST surface backend / transport failures as
/// thrown exceptions. The provider catches them and packages a
/// classified [LlmFailure] (router taxonomy lands at B.18 — until
/// then the provider re-throws). Successful returns are non-null
/// per the method's declared return type.
abstract class OllamaHttpClient {
  /// One non-streaming `/api/chat` round-trip.
  ///
  /// [model] is the resolved Ollama model id (e.g. `gemma3:27b`).
  /// [messages] is the OpenAI-format conversation list — for the
  /// post-anchor wire prompt the substrate sends a single
  /// `{role: 'user', content: <WirePrompt.body>}` message.
  /// [options] carries provider-tunable knobs that translate to
  /// Ollama's `options` map (`temperature`, `num_predict`, `stop`).
  /// [requestTimeout] caps the round-trip; `null` ⇒ no cap.
  Future<OllamaChatResponse> chat({
    required Uri baseUri,
    required String model,
    required List<OllamaMessage> messages,
    required OllamaGenerationOptions options,
    Duration? requestTimeout,
  });

  /// Streaming `/api/chat` — the response is NDJSON, one JSON object
  /// per line, with intermediate frames carrying
  /// `{message: {content: '...'}, done: false}` and exactly one
  /// terminal frame carrying `done: true` plus the eval counters.
  ///
  /// The returned stream emits one [OllamaStreamFragment] per parsed
  /// NDJSON line. The provider concatenates the `content` deltas to
  /// rebuild the full response and stamps the terminal frame's
  /// counters onto [LlmCallReport].
  ///
  /// If [cancellationToken] cancels, the stream closes the underlying
  /// HTTP connection and the returned stream terminates with an
  /// error event whose exception class is `CancelledByConsumer` (a
  /// `StateError` until B.18 ships the typed classifier).
  Stream<OllamaStreamFragment> chatStream({
    required Uri baseUri,
    required String model,
    required List<OllamaMessage> messages,
    required OllamaGenerationOptions options,
    Duration? requestTimeout,
    CancellationToken? cancellationToken,
  });

  /// `/api/embeddings`: produce the embedding for [prompt] under
  /// [model]. Returns the raw float vector — dimensionality is
  /// determined by the model (Spec § 7.2; `nomic-embed-text` → 768).
  ///
  /// Surfaces directly through the embedding service at B.25 / B.26;
  /// not invoked from `LlmProvider.complete` / `completeStream`.
  Future<List<double>> embed({
    required Uri baseUri,
    required String model,
    required String prompt,
    Duration? requestTimeout,
  });

  /// `/api/tags`: list the models present on the daemon.
  ///
  /// Consumed by the router (B.18+) to decide which models to expose
  /// on the route chain (a model the daemon does not have is not a
  /// candidate). Today returns the raw decoded list; the router
  /// wraps it in its own `HealthSnapshot`.
  Future<List<OllamaTagEntry>> listTags({
    required Uri baseUri,
    Duration? requestTimeout,
  });

  /// Releases any underlying HTTP client resources.
  ///
  /// [DefaultOllamaHttpClient.close] closes the `package:http` client
  /// it owns. Fakes that hold no resources implement this as a no-op.
  void close();
}

/// One conversation message sent to `/api/chat`.
///
/// Mirrors Ollama's wire shape: `{role: 'user'|'system'|'assistant',
/// content: '...'}`. The substrate currently sends only one message
/// per call (`role: 'user'` with the anchor-prefixed `WirePrompt.body`);
/// the list shape is preserved so multi-turn role registries (B.21+)
/// can compose conversations without churning this interface.
final class OllamaMessage {
  final String role;
  final String content;

  const OllamaMessage({required this.role, required this.content});

  Map<String, Object?> toJson() => <String, Object?>{
        'role': role,
        'content': content,
      };
}

/// Generation knobs for `/api/chat`.
///
/// Maps onto Ollama's `options` JSON: `temperature`, `num_predict`,
/// `stop`. `LlmOptions.responseFormat` (when set) translates into the
/// top-level `format: 'json'` flag on the request body.
///
/// All fields are nullable / empty-default so a "no knobs" call sends
/// the daemon-default generation policy.
final class OllamaGenerationOptions {
  final double? temperature;
  final int? maxOutputTokens;
  final List<String> stopSequences;

  /// When true, sets `format: 'json'` on the request — Ollama then
  /// constrains generation to valid JSON. Substrate maps a non-null
  /// `LlmOptions.responseFormat` to this flag (the full JSON schema
  /// is not yet enforced server-side by Ollama; the daemon checks
  /// only that the output parses).
  final bool jsonFormat;

  const OllamaGenerationOptions({
    this.temperature,
    this.maxOutputTokens,
    this.stopSequences = const <String>[],
    this.jsonFormat = false,
  });

  /// All-defaults instance.
  static const OllamaGenerationOptions empty = OllamaGenerationOptions();

  /// Serialises to the `options` map Ollama expects.
  ///
  /// Empty maps are omitted by the caller (the daemon treats absence
  /// and `{}` differently for some knobs).
  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    if (temperature != null) out['temperature'] = temperature;
    if (maxOutputTokens != null) out['num_predict'] = maxOutputTokens;
    if (stopSequences.isNotEmpty) out['stop'] = stopSequences;
    return out;
  }
}

/// Decoded `/api/chat` non-streaming response.
///
/// Fields mirror Ollama's response keys 1:1 except for naming
/// (`prompt_eval_count` → [promptEvalCount] etc.) so the provider can
/// stamp the report's `tokensIn` / `tokensOut` without a second
/// translation layer.
final class OllamaChatResponse {
  /// The model id the daemon actually ran (echoes the request).
  final String model;

  /// The full assistant content for this turn.
  final String content;

  /// Tokens evaluated from the prompt. `null` when the daemon did
  /// not report it (older Ollama builds).
  final int? promptEvalCount;

  /// Tokens emitted in the response.
  final int? evalCount;

  /// Total wall-clock the daemon spent, in nanoseconds. The provider
  /// records its own `wallClockMs` from the client side; this field
  /// is carried for trail correlation only.
  final int? totalDurationNs;

  const OllamaChatResponse({
    required this.model,
    required this.content,
    this.promptEvalCount,
    this.evalCount,
    this.totalDurationNs,
  });
}

/// One frame decoded from an `/api/chat` streaming response.
///
/// Intermediate frames carry [contentDelta] and `done = false`. The
/// terminal frame carries empty [contentDelta], `done = true`, and the
/// eval counters.
final class OllamaStreamFragment {
  final String model;
  final String contentDelta;
  final bool done;
  final int? promptEvalCount;
  final int? evalCount;
  final int? totalDurationNs;

  const OllamaStreamFragment({
    required this.model,
    required this.contentDelta,
    required this.done,
    this.promptEvalCount,
    this.evalCount,
    this.totalDurationNs,
  });
}

/// One entry from `/api/tags`.
///
/// `name` is the model id (`gemma3:27b`, `llama3:latest`, ...);
/// `digest` is the manifest digest the daemon stores. The router
/// pattern-matches on `name` for now; B.18 may grow to compare
/// digests for cache invalidation.
final class OllamaTagEntry {
  final String name;
  final String? digest;
  final int? sizeBytes;

  const OllamaTagEntry({required this.name, this.digest, this.sizeBytes});
}

/// Thrown by [DefaultOllamaHttpClient] when the daemon answers with a
/// non-2xx status (or a malformed 2xx body — B.3.1).
///
/// The backend-family subtype of [WireHttpException]: it carries no
/// fields beyond the shared base, existing only to keep the
/// "Ollama wire layer threw" signal that the trail and the B.3.1
/// conformance tests read. The router's `LlmFailureClassifier` matches
/// the [WireHttpException] supertype, so both families classify
/// identically.
class OllamaHttpException extends WireHttpException {
  OllamaHttpException({
    required super.statusCode,
    required super.body,
    required super.endpoint,
  });

  @override
  String get label => 'OllamaHttpException';
}

/// Production [OllamaHttpClient] backed by a `package:http` `Client`.
///
/// The client is acquired through `tom_core_kernel`'s
/// `TomHttpClientFactory.initialize` / `.getClient` — but for B.14 we
/// allow the caller to inject the `Client` directly so the
/// dependency-discipline test does not bind the substrate to the
/// kernel's static initialiser. The router-layer construction (B.18+
/// / B.40+) is what calls `TomHttpClientFactory.initialize` once at
/// substrate `open()`.
final class DefaultOllamaHttpClient extends DefaultWireHttpClientBase
    implements OllamaHttpClient {
  DefaultOllamaHttpClient({super.client});

  static const Map<String, String> _jsonHeaders = <String, String>{
    'Content-Type': 'application/json',
  };

  @override
  WireHttpException wireException({
    required int statusCode,
    required String body,
    required Uri endpoint,
  }) =>
      OllamaHttpException(
        statusCode: statusCode,
        body: body,
        endpoint: endpoint,
      );

  @override
  Future<OllamaChatResponse> chat({
    required Uri baseUri,
    required String model,
    required List<OllamaMessage> messages,
    required OllamaGenerationOptions options,
    Duration? requestTimeout,
  }) async {
    final url = baseUri.resolve('/api/chat');
    final response = await postJson(
      url: url,
      headers: _jsonHeaders,
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
  Stream<OllamaStreamFragment> chatStream({
    required Uri baseUri,
    required String model,
    required List<OllamaMessage> messages,
    required OllamaGenerationOptions options,
    Duration? requestTimeout,
    CancellationToken? cancellationToken,
  }) async* {
    final url = baseUri.resolve('/api/chat');
    final lines = sendForLines(
      url: url,
      headers: _jsonHeaders,
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
        // Best-effort: ask the response stream to stop. http.Client
        // does not surface a per-request abort handle on the
        // standard Client — closing the whole client is too coarse.
        // B.18 wires a cancellable client.
        throw const WireStreamCancelled('Ollama');
      }
      if (line.isEmpty) continue;
      final Object? decoded;
      try {
        decoded = jsonDecode(line);
      } on FormatException catch (e) {
        // B.3.1 — a malformed NDJSON frame mid-stream is a wire
        // corruption, not a parsed value. Surface it as the typed wire
        // exception (carrying the endpoint + line excerpt) so the router
        // classifies it instead of letting a bare `FormatException`
        // escape the route-walk. The status is 2xx by construction
        // ([sendForLines] already threw otherwise). Valid-but-non-object
        // frames keep their prior skip semantics below.
        throw wireException(
          statusCode: 200,
          body: 'Malformed NDJSON line: ${e.message}. '
              'Line: ${textPreview(line)}',
          endpoint: url,
        );
      }
      if (decoded is! Map<String, Object?>) continue;
      yield _decodeStreamFragment(decoded);
    }
  }

  @override
  Future<List<double>> embed({
    required Uri baseUri,
    required String model,
    required String prompt,
    Duration? requestTimeout,
  }) async {
    final url = baseUri.resolve('/api/embeddings');
    final response = await postJson(
      url: url,
      headers: _jsonHeaders,
      jsonBody: <String, Object?>{'model': model, 'prompt': prompt},
      requestTimeout: requestTimeout,
    );

    final decoded = decodeJsonObject(
      response.body,
      statusCode: response.statusCode,
      endpoint: url,
      shape: '{embedding: [...]}',
    );
    final vec = JsonShape.readDoubleListN(decoded, 'embedding');
    if (vec == null) {
      throw wireException(
        statusCode: response.statusCode,
        body: 'Expected {embedding: [...]}, got: ${textPreview(response.body)}',
        endpoint: url,
      );
    }
    return vec;
  }

  @override
  Future<List<OllamaTagEntry>> listTags({
    required Uri baseUri,
    Duration? requestTimeout,
  }) async {
    final url = baseUri.resolve('/api/tags');
    final response = await getUrl(url: url, requestTimeout: requestTimeout);

    final decoded = decodeJsonObject(
      response.body,
      statusCode: response.statusCode,
      endpoint: url,
      shape: '{models: [...]}',
    );
    if (decoded['models'] is! List) {
      throw wireException(
        statusCode: response.statusCode,
        body: 'Expected {models: [...]}, got: ${textPreview(response.body)}',
        endpoint: url,
      );
    }
    // The top-level shape guard above keeps the "models key missing /
    // not a list" path on the wire-error code path with an exact
    // error envelope. `JsonShape.readMapList` then filters out
    // any non-map entries inside the list — surfacing them as
    // empty / partial output rather than a hard wire error,
    // matching the existing semantics.

    return JsonShape.readMapList(decoded, 'models')
        .map((m) => OllamaTagEntry(
              name: JsonShape.readString(m, 'name'),
              digest: JsonShape.readStringN(m, 'digest'),
              sizeBytes: JsonShape.readIntN(m, 'size'),
            ))
        .toList(growable: false);
  }

  /// Ollama `/api/chat` request body. [stream] selects the NDJSON
  /// streaming response; the generation knobs + JSON-format flag are
  /// shared between the streaming and non-streaming paths.
  Map<String, Object?> _chatBody({
    required String model,
    required List<OllamaMessage> messages,
    required OllamaGenerationOptions options,
    required bool stream,
  }) {
    return <String, Object?>{
      'model': model,
      'messages': messages.map((m) => m.toJson()).toList(growable: false),
      'stream': stream,
      if (options.toJson().isNotEmpty) 'options': options.toJson(),
      if (options.jsonFormat) 'format': 'json',
    };
  }
}

OllamaChatResponse _decodeChatResponse(Map<String, Object?> json) {
  final message = JsonShape.readMapN(json, 'message');
  final content = message == null ? '' : JsonShape.readString(message, 'content');
  return OllamaChatResponse(
    model: JsonShape.readString(json, 'model'),
    content: content,
    promptEvalCount: JsonShape.readIntN(json, 'prompt_eval_count'),
    evalCount: JsonShape.readIntN(json, 'eval_count'),
    totalDurationNs: JsonShape.readIntN(json, 'total_duration'),
  );
}

OllamaStreamFragment _decodeStreamFragment(Map<String, Object?> json) {
  final message = JsonShape.readMapN(json, 'message');
  final delta = message == null ? '' : JsonShape.readString(message, 'content');
  return OllamaStreamFragment(
    model: JsonShape.readString(json, 'model'),
    contentDelta: delta,
    done: JsonShape.readBool(json, 'done'),
    promptEvalCount: JsonShape.readIntN(json, 'prompt_eval_count'),
    evalCount: JsonShape.readIntN(json, 'eval_count'),
    totalDurationNs: JsonShape.readIntN(json, 'total_duration'),
  );
}
