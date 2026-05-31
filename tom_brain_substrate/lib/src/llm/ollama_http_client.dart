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

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../api/cancellation.dart';

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
/// non-2xx status.
///
/// The B.14 provider re-throws this (until B.18 wires the classifier).
/// It is *not* a typed `LlmFailure` — that translation belongs to the
/// router, not the wire layer.
class OllamaHttpException implements Exception {
  final int statusCode;
  final String body;
  final Uri endpoint;

  OllamaHttpException({
    required this.statusCode,
    required this.body,
    required this.endpoint,
  });

  @override
  String toString() =>
      'OllamaHttpException($statusCode at $endpoint): $body';
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
class DefaultOllamaHttpClient implements OllamaHttpClient {
  final http.Client _inner;

  /// Whether [close] should also close the underlying [http.Client].
  /// `false` when the caller injected a client whose lifetime they
  /// manage themselves.
  final bool _ownsInner;

  DefaultOllamaHttpClient({http.Client? client})
      : _inner = client ?? http.Client(),
        _ownsInner = client == null;

  @override
  Future<OllamaChatResponse> chat({
    required Uri baseUri,
    required String model,
    required List<OllamaMessage> messages,
    required OllamaGenerationOptions options,
    Duration? requestTimeout,
  }) async {
    final url = baseUri.resolve('/api/chat');
    final body = <String, Object?>{
      'model': model,
      'messages': messages.map((m) => m.toJson()).toList(growable: false),
      'stream': false,
      if (options.toJson().isNotEmpty) 'options': options.toJson(),
      if (options.jsonFormat) 'format': 'json',
    };

    final future = _inner.post(
      url,
      headers: const <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    final response = await (requestTimeout == null
        ? future
        : future.timeout(requestTimeout));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw OllamaHttpException(
        statusCode: response.statusCode,
        body: response.body,
        endpoint: url,
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, Object?>) {
      throw OllamaHttpException(
        statusCode: response.statusCode,
        body: 'Expected JSON object, got: ${response.body}',
        endpoint: url,
      );
    }

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
    final body = <String, Object?>{
      'model': model,
      'messages': messages.map((m) => m.toJson()).toList(growable: false),
      'stream': true,
      if (options.toJson().isNotEmpty) 'options': options.toJson(),
      if (options.jsonFormat) 'format': 'json',
    };

    final request = http.Request('POST', url)
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode(body);

    final sendFuture = _inner.send(request);
    final response = await (requestTimeout == null
        ? sendFuture
        : sendFuture.timeout(requestTimeout));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final errBody = await response.stream.bytesToString();
      throw OllamaHttpException(
        statusCode: response.statusCode,
        body: errBody,
        endpoint: url,
      );
    }

    final lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lines) {
      if (cancellationToken?.isCancelled ?? false) {
        // Best-effort: ask the response stream to stop. http.Client
        // does not surface a per-request abort handle on the
        // standard Client — closing the whole client is too coarse.
        // B.18 wires a cancellable client.
        throw _OllamaCancelled();
      }
      if (line.isEmpty) continue;
      final decoded = jsonDecode(line);
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
    final body = <String, Object?>{
      'model': model,
      'prompt': prompt,
    };

    final future = _inner.post(
      url,
      headers: const <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    final response = await (requestTimeout == null
        ? future
        : future.timeout(requestTimeout));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw OllamaHttpException(
        statusCode: response.statusCode,
        body: response.body,
        endpoint: url,
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, Object?> ||
        decoded['embedding'] is! List) {
      throw OllamaHttpException(
        statusCode: response.statusCode,
        body: 'Expected {embedding: [...]}, got: ${response.body}',
        endpoint: url,
      );
    }
    final raw = (decoded['embedding'] as List).cast<num>();
    return raw.map((n) => n.toDouble()).toList(growable: false);
  }

  @override
  Future<List<OllamaTagEntry>> listTags({
    required Uri baseUri,
    Duration? requestTimeout,
  }) async {
    final url = baseUri.resolve('/api/tags');
    final future = _inner.get(url);
    final response = await (requestTimeout == null
        ? future
        : future.timeout(requestTimeout));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw OllamaHttpException(
        statusCode: response.statusCode,
        body: response.body,
        endpoint: url,
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, Object?> || decoded['models'] is! List) {
      throw OllamaHttpException(
        statusCode: response.statusCode,
        body: 'Expected {models: [...]}, got: ${response.body}',
        endpoint: url,
      );
    }

    return (decoded['models'] as List)
        .whereType<Map<String, Object?>>()
        .map((m) => OllamaTagEntry(
              name: (m['name'] as String?) ?? '',
              digest: m['digest'] as String?,
              sizeBytes: (m['size'] as num?)?.toInt(),
            ))
        .toList(growable: false);
  }

  @override
  void close() {
    if (_ownsInner) _inner.close();
  }
}

/// Sentinel exception raised by the streaming path when the
/// cancellation token signals. Translated to `LlmFailure(cancelled_by_consumer)`
/// at the router (B.18). Internal — not exported.
class _OllamaCancelled implements Exception {
  const _OllamaCancelled();
  @override
  String toString() => 'Ollama stream cancelled by consumer';
}

OllamaChatResponse _decodeChatResponse(Map<String, Object?> json) {
  final message = json['message'];
  final content = message is Map<String, Object?>
      ? ((message['content'] as String?) ?? '')
      : '';
  return OllamaChatResponse(
    model: (json['model'] as String?) ?? '',
    content: content,
    promptEvalCount: (json['prompt_eval_count'] as num?)?.toInt(),
    evalCount: (json['eval_count'] as num?)?.toInt(),
    totalDurationNs: (json['total_duration'] as num?)?.toInt(),
  );
}

OllamaStreamFragment _decodeStreamFragment(Map<String, Object?> json) {
  final message = json['message'];
  final delta = message is Map<String, Object?>
      ? ((message['content'] as String?) ?? '')
      : '';
  return OllamaStreamFragment(
    model: (json['model'] as String?) ?? '',
    contentDelta: delta,
    done: (json['done'] as bool?) ?? false,
    promptEvalCount: (json['prompt_eval_count'] as num?)?.toInt(),
    evalCount: (json['eval_count'] as num?)?.toInt(),
    totalDurationNs: (json['total_duration'] as num?)?.toInt(),
  );
}
