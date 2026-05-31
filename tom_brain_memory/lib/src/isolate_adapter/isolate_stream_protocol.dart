// Streaming + backpressure protocol for the isolate adapter
// (plan step A.81).
//
// `TomBrainMemoryClient` has five stream-returning methods: `stream`,
// `readTrail`, `events`, `stacks.streamArchived`, `stacks.events`. All
// five share one open / chunk / complete / error / cancel / pull
// protocol. Per Q-A.81.2, A.81 ships the protocol *shape* for all
// five plus end-to-end wiring for `readTrail` (backpressure proof)
// and `events` (cancellation proof). The other three get skeletal
// executor handlers that A.82 will replace.
//
// Routing:
//
//   * The host owns a `_StreamRouter` that maps `StreamId` →
//     `StreamController` (consumer-facing sink) plus `int` credits
//     (for backpressure-capable streams).
//   * The in-isolate executor pushes `StreamChunkEnvelope` and
//     terminal `StreamCompleteEnvelope` / `StreamErrorEnvelope`
//     messages via `TomWorker.sendToCreator(...)` — the one-way
//     isolate → host channel.
//   * A creator-side `TomExecutor` registered by the host (see
//     `tom_brain_memory_isolate_host.dart`) picks up these messages
//     and forwards them to the router by `streamId`.
//
// Backpressure:
//
//   `readTrail` opens with an initial credit allowance
//   (`StreamOpenRequest.initialCredits`). The executor sends chunks
//   while credits are positive; when credits hit zero, the executor
//   pauses. The client tops up by sending `StreamPullRequest(id, n)`;
//   the executor resumes. Streams whose `initialCredits` is `null`
//   are *unbounded* — chunks flow as fast as the producer generates
//   them (the default for `events`, `stacks.events`, and the other
//   non-backpressured streams).
//
// Cancellation:
//
//   Every stream open envelope optionally carries a
//   `CancellationToken`. The executor checks the token's flag between
//   every chunk push. On cancellation, the executor sends a
//   terminal `StreamCancelledEnvelope` and unregisters.
//
// Sendability:
//
//   Every envelope, chunk type, and routing message in this file
//   uses primitive fields (`int`, `String`, sendable value classes)
//   so they cross the isolate boundary by `TomWorker`'s default send
//   rules. The chunk payload type is a generic `Object?` so each
//   stream's per-method protocol can land its own payload class.

import 'dart:async';

import 'isolate_cancellation_protocol.dart';
import 'isolate_messages.dart';

/// Opaque identifier for an open stream, sendable across an isolate
/// boundary.
///
/// Allocated by the client; included in every chunk / control message.
/// Unique per host instance and not recycled within a host lifetime.
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

/// Host-side counter that hands out unique [StreamId]s.
///
/// One allocator per `TomBrainMemoryIsolateClient`. Same single-isolate
/// safety reasoning as `CancellationTokenAllocator`.
final class StreamIdAllocator {
  int _next = 1;
  StreamId next() => StreamId(_next++);
  int get peekNext => _next;
}

// ─── Stream control messages (host → isolate via executor) ────────

/// Pulls more credits for a backpressured stream.
///
/// Sent by the client when local consumer demand exceeds remaining
/// credits. The executor's response is a [StreamPullResponse] sent
/// inline with the request (so the client knows the pull was
/// observed); chunks themselves continue to arrive via the
/// side-channel.
final class StreamPullRequest extends IsolateRequest {
  final StreamId streamId;
  final int credits;

  const StreamPullRequest({required this.streamId, required this.credits})
      : assert(credits > 0, 'credits must be positive');
}

/// Reply to [StreamPullRequest]. Empty payload — confirmation only.
final class StreamPullResponse extends IsolateResponse {
  const StreamPullResponse();
}

/// Cancels an open stream. The executor sends a terminal
/// [StreamCancelledEnvelope] then unregisters.
///
/// Distinct from [CancelRequest]: a cancel request flips a flag on a
/// [CancellationToken] (general-purpose), while a stream-close request
/// also tears down the chunk plumbing for that specific stream.
final class StreamCloseRequest extends IsolateRequest {
  final StreamId streamId;
  const StreamCloseRequest(this.streamId);
}

/// Reply to [StreamCloseRequest].
final class StreamCloseResponse extends IsolateResponse {
  const StreamCloseResponse();
}

// ─── Stream side-channel messages (isolate → host via sendToCreator) ─

/// Marker base for messages travelling on the isolate-to-host side
/// channel (`TomWorker.sendToCreator`). The host-side router switches
/// on the runtime type to dispatch to the right per-stream sink.
abstract class StreamSideChannelMessage {
  const StreamSideChannelMessage();

  /// The stream this message belongs to.
  StreamId get streamId;
}

/// One chunk pushed from the isolate to the host.
///
/// The `payload` is generic — each producer chooses its own concrete
/// chunk payload class (e.g. `TrailEntry` for `readTrail`,
/// `MemoryEvent` for `events`, `Node` for `stream`). All payload
/// classes used in production must themselves be sendable.
final class StreamChunkEnvelope extends StreamSideChannelMessage {
  @override
  final StreamId streamId;

  /// Sequential per-stream chunk index, starting at 0. Lets the host
  /// detect drops or reordering (A.82 will assert the invariant).
  final int sequence;

  /// The chunk payload. Sendability is the producer's responsibility.
  final Object? payload;

  const StreamChunkEnvelope({
    required this.streamId,
    required this.sequence,
    required this.payload,
  });
}

/// Terminal envelope — the producer finished cleanly.
///
/// `sequence` carries the total number of chunks sent (one past the
/// last chunk's `sequence`). The host closes the consumer-facing
/// `StreamController` on receipt.
final class StreamCompleteEnvelope extends StreamSideChannelMessage {
  @override
  final StreamId streamId;
  final int sequence;

  const StreamCompleteEnvelope({
    required this.streamId,
    required this.sequence,
  });
}

/// Terminal envelope — the producer threw.
///
/// The host forwards the error to the consumer-facing
/// `StreamController` as a `Stream.error(...)`.
final class StreamErrorEnvelope extends StreamSideChannelMessage {
  @override
  final StreamId streamId;
  final String message;
  final String exceptionType;

  const StreamErrorEnvelope({
    required this.streamId,
    required this.message,
    required this.exceptionType,
  });
}

/// Terminal envelope — the consumer cancelled or the cancellation
/// token fired. The host completes the consumer-facing stream
/// without emitting an error (cancellation is normal flow control).
final class StreamCancelledEnvelope extends StreamSideChannelMessage {
  @override
  final StreamId streamId;
  final CancellationToken? token;

  const StreamCancelledEnvelope({required this.streamId, this.token});
}

// ─── Backpressure tracker (executor-side) ────────────────────────

/// Per-stream credit ledger held inside the executor.
///
/// Backpressured streams (e.g. `readTrail`) construct one of these
/// with the initial credit allowance from the open envelope.
/// Unbounded streams (`events`) skip the tracker entirely — chunks
/// flow without credit accounting.
///
/// Usage:
///
///   ```dart
///   final tracker = BackpressureTracker(initialCredits: 16);
///   while (more) {
///     await tracker.awaitCredit();
///     pushChunk();
///     tracker.consume(1);
///   }
///   ```
///
/// `awaitCredit()` returns immediately when credits > 0; otherwise it
/// waits until [grant] is called. Multiple callers may be parked; they
/// are released in FIFO order one credit at a time.
final class BackpressureTracker {
  int _credits;
  final List<Completer<void>> _waiters = <Completer<void>>[];
  bool _closed = false;

  BackpressureTracker({required int initialCredits})
      : _credits = initialCredits {
    if (initialCredits < 0) {
      throw ArgumentError.value(
        initialCredits,
        'initialCredits',
        'must be non-negative',
      );
    }
  }

  /// Remaining credits. Visible for tests.
  int get credits => _credits;

  /// Number of waiters parked on [awaitCredit]. Visible for tests.
  int get waiterCount => _waiters.length;

  /// Whether [close] has been called. Subsequent [awaitCredit] calls
  /// throw [StateError].
  bool get isClosed => _closed;

  /// Returns once at least one credit is available. Does not decrement
  /// — call [consume] after pushing the chunk.
  Future<void> awaitCredit() {
    if (_closed) {
      return Future<void>.error(
        StateError('BackpressureTracker is closed.'),
      );
    }
    if (_credits > 0) return Future<void>.value();
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  /// Consumes [n] credits (default 1). Permits going to zero; rejects
  /// going negative.
  void consume([int n = 1]) {
    if (n < 0) {
      throw ArgumentError.value(n, 'n', 'must be non-negative');
    }
    if (n > _credits) {
      throw StateError(
        'BackpressureTracker.consume($n) but only $_credits credits available.',
      );
    }
    _credits -= n;
  }

  /// Grants [n] more credits. Wakes up to [n] parked waiters in FIFO
  /// order; remaining credits stay on the ledger.
  void grant(int n) {
    if (_closed) return;
    if (n <= 0) {
      throw ArgumentError.value(n, 'n', 'must be positive');
    }
    _credits += n;
    while (_waiters.isNotEmpty && _credits > 0) {
      final w = _waiters.removeAt(0);
      if (!w.isCompleted) {
        w.complete();
      }
    }
  }

  /// Closes the tracker. Pending waiters fail with [StateError].
  void close() {
    if (_closed) return;
    _closed = true;
    final waiters = List<Completer<void>>.from(_waiters);
    _waiters.clear();
    for (final w in waiters) {
      if (!w.isCompleted) {
        w.completeError(StateError('BackpressureTracker is closed.'));
      }
    }
  }
}
