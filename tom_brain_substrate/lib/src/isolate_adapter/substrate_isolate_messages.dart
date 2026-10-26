// Typed request/response envelopes exchanged between the in-process
// `TomBrainSubstrateIsolateHost` and the in-isolate executor
// (Tom Brain completion-plan item #12).
//
// The substrate boundary mirrors the memory boundary's shape
// (`tom_brain_memory/lib/src/isolate_adapter/isolate_messages.dart`)
// but carries the substrate's own surface: the unary LLM / embedding
// / web methods plus the two stream-returning methods (`completeStream`
// and `events`).
//
// Two substrate-specific design points distinguish this catalogue from
// the memory one:
//
//   * `TomBrainSubstrateClient.stats()` is *synchronous* — it returns
//     `SubstrateStats`, not `Future<SubstrateStats>`. A proxy cannot
//     `await` a round trip to satisfy a sync getter, so every unary
//     response piggybacks a fresh `SubstrateStats` snapshot. The proxy
//     caches the last snapshot and returns it synchronously. Streaming
//     completions do not refresh the cache (no unary reply rides back),
//     so the proxy's stats are eventually-consistent with respect to
//     streamed calls — documented on the adapter.
//
//   * There is no separate "open then use" lifecycle gate. The worker
//     builds the client eagerly, so `OpenSubstrateRequest` is optional;
//     the unary methods work against a never-opened client.
//
// Sendability contract:
//
//   Every envelope crosses an isolate boundary. Fields must be sendable
//   (primitives, `Map`/`List` of sendable values, `Uri`, package value
//   types whose fields recursively honour this rule). The proxy strips
//   `LlmCall.cancellationToken` before sending (a live token may capture
//   a `Completer`); the rebuilt call carries `TomCancellationToken.none`
//   (a const, field-free, sendable singleton).

import '../api/embedding_result.dart';
import '../api/llm_call.dart';
import '../api/substrate_stats.dart';
import '../api/web_results.dart';
import '../config/substrate_config.dart';

/// Marker base for every request sent from the host to the isolate.
abstract class IsolateRequest {
  const IsolateRequest();
}

/// Marker base for every response sent from the isolate back to the
/// host. The host's `send<R>(...)` casts to the expected concrete
/// response type; an [IsolateErrorResponse] returned in place of the
/// expected type is the boundary's failure signal.
abstract class IsolateResponse {
  const IsolateResponse();
}

// ─── Lifecycle ───────────────────────────────────────────────────

/// Sanity-ping the isolate. Replies with a [PongResponse] echoing the
/// host timestamp so a latency probe can land without a protocol change.
final class PingRequest extends IsolateRequest {
  /// The host's wall-clock millisecond reading at send time.
  final int hostWallClockMs;

  const PingRequest({required this.hostWallClockMs});
}

/// Reply to a [PingRequest].
final class PongResponse extends IsolateResponse {
  final int echoedHostWallClockMs;
  final int isolateWallClockMs;

  const PongResponse({
    required this.echoedHostWallClockMs,
    required this.isolateWallClockMs,
  });
}

/// Drive `substrate.open(config)` inside the isolate. Optional — the
/// worker builds the client eagerly and the unary methods work without
/// it. Sending it seeds provider credentials / cooldown state.
final class OpenSubstrateRequest extends IsolateRequest {
  final SubstrateConfig config;
  const OpenSubstrateRequest(this.config);
}

/// Reply to a successful [OpenSubstrateRequest], carrying a fresh stats
/// snapshot so the proxy's cache stays warm.
final class OpenSubstrateResponse extends IsolateResponse {
  final SubstrateStats stats;
  const OpenSubstrateResponse({required this.stats});
}

/// Drive `substrate.close()` inside the isolate.
final class CloseSubstrateRequest extends IsolateRequest {
  const CloseSubstrateRequest();
}

/// Reply to a [CloseSubstrateRequest].
final class CloseSubstrateResponse extends IsolateResponse {
  final SubstrateStats stats;
  const CloseSubstrateResponse({required this.stats});
}

// ─── Unary surface (each reply piggybacks a stats snapshot) ──────

/// Drive `substrate.complete(call)`.
final class CompleteRequest extends IsolateRequest {
  final LlmCall call;
  const CompleteRequest(this.call);
}

/// Reply to [CompleteRequest]. The report's anchor is re-checked at the
/// proxy before the report is surfaced (defense in depth).
final class CompleteResponse extends IsolateResponse {
  final LlmCallReport report;
  final SubstrateStats stats;
  const CompleteResponse({required this.report, required this.stats});
}

/// Drive `substrate.embed(text)`.
final class EmbedRequest extends IsolateRequest {
  final String text;
  const EmbedRequest(this.text);
}

/// Reply to [EmbedRequest].
final class EmbedResponse extends IsolateResponse {
  final EmbeddingResult result;
  final SubstrateStats stats;
  const EmbedResponse({required this.result, required this.stats});
}

/// Drive `substrate.embedBatch(texts)`.
final class EmbedBatchRequest extends IsolateRequest {
  final List<String> texts;
  const EmbedBatchRequest(this.texts);
}

/// Reply to [EmbedBatchRequest].
final class EmbedBatchResponse extends IsolateResponse {
  final List<EmbeddingResult> results;
  final SubstrateStats stats;
  const EmbedBatchResponse({required this.results, required this.stats});
}

/// Drive `substrate.webSearch(query, options:)`.
final class WebSearchRequest extends IsolateRequest {
  final String query;
  final WebSearchOptions options;
  const WebSearchRequest({required this.query, required this.options});
}

/// Reply to [WebSearchRequest].
final class WebSearchResponse extends IsolateResponse {
  final WebSearchResult result;
  final SubstrateStats stats;
  const WebSearchResponse({required this.result, required this.stats});
}

/// Drive `substrate.webFetch(url, options:)`.
final class WebFetchRequest extends IsolateRequest {
  final Uri url;
  final WebFetchOptions options;
  const WebFetchRequest({required this.url, required this.options});
}

/// Reply to [WebFetchRequest].
final class WebFetchResponse extends IsolateResponse {
  final WebFetchResult result;
  final SubstrateStats stats;
  const WebFetchResponse({required this.result, required this.stats});
}

// ─── Failure ─────────────────────────────────────────────────────

/// Boundary-side failure marker. Returned by the in-isolate executor
/// when a handler threw; the host reconstructs the typed exception via
/// the `IsolateExceptionRegistry` (`SubstrateIsolateExceptions`) and
/// re-raises that type, falling back to [IsolateBoundaryException] for
/// anything outside the closed taxonomy.
final class IsolateErrorResponse extends IsolateResponse {
  final String message;
  final String exceptionType;
  final Map<String, Object?> details;

  const IsolateErrorResponse({
    required this.message,
    required this.exceptionType,
    this.details = const <String, Object?>{},
  });
}

/// Thrown by [TomBrainSubstrateIsolateHost.send] when the executor
/// returned an [IsolateErrorResponse] whose type is outside the closed
/// substrate taxonomy.
final class IsolateBoundaryException implements Exception {
  final String message;
  final String exceptionType;

  IsolateBoundaryException(this.message, this.exceptionType);

  @override
  String toString() => 'IsolateBoundaryException($exceptionType: $message)';
}
