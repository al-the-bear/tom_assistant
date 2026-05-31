// Stream-opening request envelopes used by the A.81 proofs.
//
// Position in the slice (A.79 – A.82):
//
//   * A.79 — base + lifecycle + `MemoryStats` envelopes
//     (`isolate_messages.dart`).
//   * A.81 (this file) — the **stream-open** envelopes that exercise
//     the new cancellation + backpressure mechanisms end-to-end.
//     Per the Q-A.81.2 scope decision, A.81 ships the protocol *shape*
//     for every stream-returning method plus full wiring for two
//     proofs: `readTrail` (backpressure) and `events` (cancellation).
//     The other three stream-returning methods (`stream`,
//     `stacks.streamArchived`, `stacks.events`) get their shapes here
//     but stay marked as `EnvelopeNotWiredError` on the client until
//     A.82.
//   * A.82 — round-trip every envelope through a real isolate and
//     wire the remaining streams + every non-stream rich-type
//     envelope.
//
// Naming convention:
//
//   `OpenXStreamRequest` opens a stream — the response is a
//   `StreamOpenedResponse` carrying the freshly-allocated
//   [StreamId]. Subsequent chunk delivery rides the isolate-to-host
//   side channel (`sendToCreator(StreamChunkEnvelope)`). Closing the
//   stream uses the generic `StreamCloseRequest` from
//   `isolate_stream_protocol.dart`; pulling backpressure credits
//   uses the generic `StreamPullRequest`; cancelling uses the
//   generic `CancelRequest`.

import 'package:tom_brain_shared/tom_brain_shared.dart' show TrailId;

import 'isolate_cancellation_protocol.dart';
import 'isolate_messages.dart';
import 'isolate_stream_protocol.dart';

// ─── Generic stream-opened response ───────────────────────────────

/// Reply to every `OpenXStreamRequest`. Carries the [streamId] the
/// host will use for routing chunks back through the side channel.
///
/// One response shape for every stream-opening envelope so the host
/// only needs one `host.send<StreamOpenedResponse>(...)` codepath
/// for opening any kind of stream.
final class StreamOpenedResponse extends IsolateResponse {
  /// The id assigned by the host (the client-side
  /// [StreamIdAllocator]). The executor echoes it back so the host
  /// can confirm the registration round-tripped.
  final StreamId streamId;

  const StreamOpenedResponse(this.streamId);
}

// ─── readTrail (backpressure proof) ───────────────────────────────

/// Opens a `readTrail(TrailId)` stream.
///
/// `readTrail` is the A.81 **backpressure proof**: chunks are paced
/// by a credit budget. The client primes the budget with
/// [initialCredits]; the executor pushes chunks while credits are
/// positive and pauses when they hit zero, resuming on
/// [StreamPullRequest] credit tops-ups.
///
/// Cancellation is supported via the same [token] mechanism as every
/// other cancellable request — the executor checks the token's flag
/// between every chunk push.
final class OpenReadTrailStreamRequest extends IsolateRequest {
  /// The client-allocated stream id. The host registers it in the
  /// stream router before sending the open envelope.
  final StreamId streamId;

  /// The trail to read.
  final TrailId trailId;

  /// Initial credit allowance on the per-stream
  /// [BackpressureTracker]. Must be positive.
  final int initialCredits;

  /// Optional cancellation token. When the host wants to abort an
  /// in-flight trail read, it sends a [CancelRequest] for this token
  /// and the executor honours it at the next chunk-boundary
  /// checkpoint.
  final CancellationToken? cancellation;

  const OpenReadTrailStreamRequest({
    required this.streamId,
    required this.trailId,
    required this.initialCredits,
    this.cancellation,
  })  : assert(initialCredits > 0, 'initialCredits must be positive');
}

// ─── events (cancellation proof) ──────────────────────────────────

/// Opens a `events()` stream.
///
/// `events()` is the A.81 **cancellation proof**: the stream is
/// unbounded (no backpressure — events are produced rarely and
/// consumers drive the rate), and the only way to stop it is the
/// cancellation token mechanism or a [StreamCloseRequest].
final class OpenEventsStreamRequest extends IsolateRequest {
  /// The client-allocated stream id.
  final StreamId streamId;

  /// Cancellation token. Required (not optional) because the only
  /// way to stop an unbounded stream from the client is the cancel
  /// path; making the token mandatory makes that intent visible at
  /// the type level.
  final CancellationToken cancellation;

  const OpenEventsStreamRequest({
    required this.streamId,
    required this.cancellation,
  });
}
