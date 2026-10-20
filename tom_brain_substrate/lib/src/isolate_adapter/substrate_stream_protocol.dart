// Streaming protocol for the substrate isolate adapter (Tom Brain
// completion-plan item #12).
//
// `TomBrainSubstrateClient` has two stream-returning methods:
// `completeStream` and `events`. Both are **unbounded** — an LLM
// stream self-terminates when the provider stops, and the event bus
// runs for the worker's lifetime. There is no backpressure: tokens
// flow as fast as the provider produces them. So this protocol drops
// the memory boundary's `StreamPullRequest` / credit machinery and
// keeps only the open / chunk / complete / error / cancel envelopes.
//
// Routing mirrors the memory boundary: the in-isolate executor pushes
// `StreamChunkEnvelope` + terminal envelopes via
// `TomWorker.sendToCreator(...)`; a creator-side `TomExecutor`
// registered by the host forwards them to the per-stream
// `StreamController` by `streamId`.
//
// Sendability:
//
//   The chunk payload is a sanitized stream event — for `completeStream`
//   an `LlmEvent` (with `LlmFailure.cause` nulled), for `events`
//   a `SubstrateEvent` (likewise). All other envelope fields are
//   primitives or sendable value classes.

import '../api/llm_call.dart';
import 'substrate_isolate_messages.dart';

/// Opaque identifier for an open stream, sendable across the boundary.
/// Allocated host-side; included in every chunk / control message.
final class StreamId {
  final int id;
  const StreamId(this.id);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is StreamId && other.id == id);

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'StreamId($id)';
}

/// Host-side counter that hands out unique [StreamId]s. One allocator
/// per host; ids are not recycled within a host lifetime.
final class StreamIdAllocator {
  int _next = 1;
  StreamId next() => StreamId(_next++);
  int get peekNext => _next;
}

// ─── Stream open requests (host → isolate) ───────────────────────

/// Open a `completeStream` over [call]. The executor starts an
/// unbounded producer over `substrate.completeStream(call)` and pushes
/// each `LlmEvent` as a [StreamChunkEnvelope] payload.
final class OpenCompleteStreamRequest extends IsolateRequest {
  final StreamId streamId;
  final LlmCall call;
  const OpenCompleteStreamRequest({required this.streamId, required this.call});
}

/// Open an `events()` stream. The executor starts an unbounded producer
/// over `substrate.events()` and pushes each `SubstrateEvent` as a
/// [StreamChunkEnvelope] payload.
final class OpenEventsStreamRequest extends IsolateRequest {
  final StreamId streamId;
  const OpenEventsStreamRequest(this.streamId);
}

/// Reply confirming a stream was opened. Chunks arrive on the side
/// channel; this only acknowledges the open envelope round-trip.
final class StreamOpenedResponse extends IsolateResponse {
  final StreamId streamId;
  const StreamOpenedResponse(this.streamId);
}

// ─── Stream control (host → isolate) ─────────────────────────────

/// Close an open stream from the host side. The executor fires the
/// producer's close signal so it terminates cleanly.
final class StreamCloseRequest extends IsolateRequest {
  final StreamId streamId;
  const StreamCloseRequest(this.streamId);
}

/// Reply to [StreamCloseRequest].
final class StreamCloseResponse extends IsolateResponse {
  const StreamCloseResponse();
}

// ─── Stream side-channel messages (isolate → host) ───────────────

/// Marker base for messages travelling on the isolate→host side channel
/// (`TomWorker.sendToCreator`). The host's router switches on runtime
/// type to dispatch to the right per-stream sink.
abstract class StreamSideChannelMessage {
  const StreamSideChannelMessage();

  /// The stream this message belongs to.
  StreamId get streamId;
}

/// One chunk pushed from the isolate to the host. The `payload` is a
/// sanitized stream event (`LlmEvent` or `SubstrateEvent`); the
/// producer is responsible for its sendability.
final class StreamChunkEnvelope extends StreamSideChannelMessage {
  @override
  final StreamId streamId;
  final int sequence;
  final Object? payload;

  const StreamChunkEnvelope({
    required this.streamId,
    required this.sequence,
    required this.payload,
  });
}

/// Terminal envelope — the producer finished cleanly. The host closes
/// the consumer-facing `StreamController` on receipt.
final class StreamCompleteEnvelope extends StreamSideChannelMessage {
  @override
  final StreamId streamId;
  final int sequence;

  const StreamCompleteEnvelope({
    required this.streamId,
    required this.sequence,
  });
}

/// Terminal envelope — the producer threw. The host reconstructs the
/// typed exception (or falls back to `IsolateBoundaryException`) and
/// forwards it to the consumer stream as a `Stream.error`.
final class StreamErrorEnvelope extends StreamSideChannelMessage {
  @override
  final StreamId streamId;
  final String message;
  final String exceptionType;
  final Map<String, Object?> details;

  const StreamErrorEnvelope({
    required this.streamId,
    required this.message,
    required this.exceptionType,
    this.details = const <String, Object?>{},
  });
}

/// Terminal envelope — the host requested close. The host completes the
/// consumer-facing stream without an error (close is normal flow).
final class StreamCancelledEnvelope extends StreamSideChannelMessage {
  @override
  final StreamId streamId;

  const StreamCancelledEnvelope({required this.streamId});
}
