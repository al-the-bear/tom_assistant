// B.9 — `LlmStreamEvent` sealed sum.
//
// substrate_specification.md § 3.1 lists the variants:
//   `Started`, `Chunk(text)`, `ToolCallProposed(...)`, `Completed(report)`,
//   `Failed(error, report)`.
//
// Why a sealed class:
//
//   - The five variants are the closed set of things that can come
//     out of `completeStream`. A new variant is a contract change
//     (substrate version bump), not a silent extension.
//   - Consumers (the dispatcher's SSE forwarder, the procedure
//     dispatcher's trail-ingest path, tests) pattern-match on the
//     variants with `switch` and the analyzer enforces exhaustiveness.
//
// What this file deliberately is NOT:
//
//   - Not the place where errors are classified. `LlmStreamEvent.failed`
//     carries an `LlmFailure` value class; the failure taxonomy
//     (spec § 5.4) lives under `lib/src/llm/failure_taxonomy.dart`
//     (B.18). For B.9 the failure is a typed envelope — a class name
//     + a message — so the api/ surface can compile without yet
//     pulling in the router-layer taxonomy.

import 'llm_call.dart';

/// Events emitted on a `Stream<LlmStreamEvent>` from
/// `TomBrainSubstrateClient.completeStream`.
///
/// Lifecycle:
///   - Exactly one [LlmStreamStarted] is emitted first.
///   - Zero or more [LlmStreamChunk] events follow, in order.
///   - Zero or more [LlmStreamToolCallProposed] events may be
///     interleaved with chunks; the provider pauses the stream
///     after a tool-call until the dispatcher resolves it
///     (resolution mechanics land at the dispatcher in Phase D).
///   - The stream terminates with **exactly one** of
///     [LlmStreamCompleted] or [LlmStreamFailed].
///
/// Consumers that need a non-streaming view should use
/// `TomBrainSubstrateClient.complete`, which buffers the stream and
/// returns the final report directly.
sealed class LlmStreamEvent {
  const LlmStreamEvent();
}

/// First event on every stream. Carries the call id assigned by the
/// substrate so consumers can correlate subsequent chunks with the
/// originating call in their own logs / trails.
final class LlmStreamStarted extends LlmStreamEvent {
  /// Opaque, substrate-assigned identifier for this call. Matches
  /// the `callId` field of [LlmStreamCompleted] / [LlmStreamFailed]
  /// and of every substrate observability event for this call
  /// (`LlmCallStarted`, `LlmCallChunk`, `LlmCallCompleted`,
  /// `LlmCallFailed` — see `substrate_event.dart`).
  final String callId;

  /// Provider that was selected by the router for this call.
  final String providerId;

  /// Model id within the provider.
  final String modelId;

  const LlmStreamStarted({
    required this.callId,
    required this.providerId,
    required this.modelId,
  });
}

/// One chunk of streamed text. Chunks may arrive in any granularity
/// the provider chooses (per-token, per-word, per-newline …);
/// consumers concatenate the [text] fields to reconstruct the full
/// response.
final class LlmStreamChunk extends LlmStreamEvent {
  final String callId;
  final String text;

  const LlmStreamChunk({required this.callId, required this.text});
}

/// The provider proposed a tool call. The stream is paused while
/// the dispatcher resolves the call; resumption happens when the
/// dispatcher posts the tool result back through the (Phase D)
/// tool-result channel.
///
/// `arguments` is the JSON-shaped argument object the provider
/// emitted, validated against the tool's `parametersSchema` by
/// `ToolDescriptor`. Validation failures surface as a
/// [LlmStreamFailed] event with a `ToolCallInvalid` failure class.
final class LlmStreamToolCallProposed extends LlmStreamEvent {
  final String callId;

  /// Provider-side tool-call id. Used by the dispatcher to post the
  /// resolution back; substrate does not interpret it.
  final String toolCallId;

  /// The tool's canonical name (matches a [ToolDescriptor.name] in
  /// the call's [ToolCatalogue]).
  final String toolName;

  /// Argument object, JSON-shaped.
  final Map<String, Object?> arguments;

  const LlmStreamToolCallProposed({
    required this.callId,
    required this.toolCallId,
    required this.toolName,
    required this.arguments,
  });
}

/// Successful completion. Carries the final [LlmCallReport] so the
/// caller does not need to await a separate future after the stream
/// closes.
final class LlmStreamCompleted extends LlmStreamEvent {
  final String callId;
  final LlmCallReport report;

  const LlmStreamCompleted({required this.callId, required this.report});
}

/// Terminal failure. Carries both the typed failure (so the router
/// and the dispatcher can branch on the failure class) and a
/// best-effort [LlmCallReport] reflecting what was known at the
/// point of failure (tokens streamed so far, wall-clock spent,
/// retries already burned).
final class LlmStreamFailed extends LlmStreamEvent {
  final String callId;
  final LlmFailure failure;
  final LlmCallReport report;

  const LlmStreamFailed({
    required this.callId,
    required this.failure,
    required this.report,
  });
}

/// Typed failure envelope.
///
/// [classCode] is a stable kebab-case discriminator drawn from the
/// closed taxonomy in `substrate_specification.md` § 5.4
/// (`rate_limit`, `overloaded`, `billing`, `timeout`, `auth`,
/// `auth_permanent`, `model_not_found`, `context_overflow`,
/// `format`, `network`, `cancelled_by_consumer`, `unknown`).
///
/// `LlmFailure` is the api/-layer carrier; the router-layer
/// (B.18+) maps provider responses into this envelope via
/// `LlmFailureClassifier`. Consumers that need to branch by class
/// should switch on [classCode]; consumers that just need to log
/// or surface the failure use [message].
final class LlmFailure {
  /// Stable kebab-case discriminator. Cf. spec § 5.4 taxonomy.
  final String classCode;

  /// Human-readable diagnostic. Not for end-user display; for
  /// `TomLogger` / trail entries.
  final String message;

  /// Optional underlying error. May be a provider-library exception,
  /// a `SocketException`, a `TimeoutException`, etc. Carried for
  /// debugging only — consumers should not pattern-match on its
  /// runtime type.
  final Object? cause;

  const LlmFailure({
    required this.classCode,
    required this.message,
    this.cause,
  });
}
