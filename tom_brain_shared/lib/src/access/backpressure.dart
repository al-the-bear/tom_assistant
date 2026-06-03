// Backpressure signalling for the outbound delivery path (Plan step E.39;
// proto spec § 10.1; AC-2).
//
// What this file owns:
//
//   * `BackpressureSignal` — the sealed base the engine reacts to: when one
//     is surfaced through the `DeliverCallback`'s backpressure
//     `Stream<OutboundChunk>` the engine yields rather than pushing more
//     chunks into a wire that cannot take them.
//
//   * `DeliveryStalled` — the one concrete signal the prototype carries: the
//     originating channel cannot accept further chunks. The two stall causes
//     the plan names — an SSE client that disconnected, a Telegram rate limit
//     — are the two `StallReason`s, distinguished from `channelClosed`.
//
//   * `StallReason` — the closed reason set. Terminality is intrinsic to the
//     reason (`StallReasonTerminality.isTerminal`): the engine keys on it (and
//     on `retryAfter`) to decide between *cancel the run* (a terminal stall —
//     the SSE client is gone) and *yield, then retry after [retryAfter]* (a
//     transient stall — the rate limit clears). `DeliveryStalled.isTerminal`
//     is a derived getter, never an independently-set field, so a stall can
//     never disagree with its own reason.
//
//   * `Backpressure` — the two stream builders a delivery path returns from
//     its `DeliverCallback`: `clear` (the chunk was accepted, ready for more)
//     and `stalled(signal)` (the channel stalled; the signal rides the stream
//     as an error).
//
// Why this lives in `tom_brain_shared` (next to `OutboundChunk` / `Access`):
//
//   The `DeliverCallback` backpressure stream is produced by the Phase-E
//   delivery paths and consumed by the engine (Phase C/D) — two components on
//   one contract, so the type is declared once, in shared (the reuse rule).
//   `access.dart`'s `DeliverCallback` doc already anticipated the
//   `DeliveryStalled` home here; `OutboundChunk` (D.11) and `InboundRequest`
//   followed the same pull-forward, so `DeliveryStalled` / `BackpressureSignal`
//   join them rather than being defined in the access prototype and moved at
//   the E.52 extraction pass.
//
// Why the signal carries the channel as a `String` wire name (not an
// `AccessChannel`): `AccessChannel` lives in the access prototype
// (`session_manager.dart`, E.25); shared cannot depend on it without inverting
// the dependency arrow. The wire name (`channel.wireName` — "openai" /
// "telegram") is the stable, neutral handle, so the signal stays in shared and
// channel-agnostic (Q-E.39.2).
//
// What this file does NOT do:
//
//   * No wire formatting (the delivery paths own it, E.37 / E.38).
//   * No engine reaction. Surfacing a signal is this layer's job; *yielding*
//     on it is the engine's, once the `answer_with_memory_v1` streaming gap is
//     wired. The contract is documented here and exercised by the delivery
//     paths' suites; the engine wiring is a later step.

import 'dart:async';

import 'outbound_chunk.dart';

/// Why the originating channel stalled.
///
/// The reason, together with [DeliveryStalled.isTerminal], tells the engine
/// how to react: a [clientDisconnected] / [channelClosed] stall is terminal
/// (the wire is gone — cancel the run), a [rateLimited] stall is transient
/// (yield, then retry after [DeliveryStalled.retryAfter]).
enum StallReason {
  /// The SSE response-body subscription was cancelled — the OpenAI client
  /// disconnected before the answer finished streaming (E.37). Terminal.
  clientDisconnected,

  /// The channel backend throttled the send — a Telegram rate limit (E.38).
  /// Transient: the engine yields and retries after [DeliveryStalled.retryAfter].
  rateLimited,

  /// The wire was already closed when a chunk arrived (a delivery path that
  /// closed its sink, or a write past the terminator). Terminal.
  channelClosed,
}

/// Terminality is an intrinsic property of the [StallReason], not a separate
/// flag a caller chooses.
///
/// A [StallReason.clientDisconnected] / [StallReason.channelClosed] stall is
/// permanent — the wire is gone, so the engine cancels the run. A
/// [StallReason.rateLimited] stall is transient — the engine yields and
/// retries. Deriving [DeliveryStalled.isTerminal] from here (rather than
/// storing an independent field) makes a reason↔terminality contradiction
/// unrepresentable.
extension StallReasonTerminality on StallReason {
  /// Whether a stall with this reason is permanent (`true`) or recoverable
  /// (`false`).
  bool get isTerminal => switch (this) {
        StallReason.clientDisconnected => true,
        StallReason.channelClosed => true,
        StallReason.rateLimited => false,
      };
}

/// The signal a delivery path surfaces through the `DeliverCallback`'s
/// backpressure `Stream<OutboundChunk>` — as a stream *error* — when the
/// originating channel cannot accept further chunks.
///
/// Sealed: the engine reacts to this base type (any `BackpressureSignal`
/// surfaced through the backpressure stream means *yield*), and a new
/// realisation is a contract change that forces exhaustive `switch` consumers
/// to recompile. [DeliveryStalled] is the one realisation the prototype
/// carries.
///
/// Implements [Exception] so it rides a `Stream.error` idiomatically and a
/// consumer can `try`/`catch` it off the backpressure stream.
sealed class BackpressureSignal implements Exception {
  /// Const base constructor for the sealed hierarchy.
  const BackpressureSignal();
}

/// The originating channel cannot accept further chunks.
///
/// Surfaced by the delivery paths (E.37 SSE, E.38 Telegram) through the
/// backpressure stream when the wire stalls. The engine reads [isTerminal] to
/// choose between cancelling the run (terminal — the SSE client is gone) and
/// yielding then retrying after [retryAfter] (transient — the Telegram rate
/// limit clears).
///
/// Immutable value object.
final class DeliveryStalled extends BackpressureSignal {
  /// The stable, lower-case wire name of the stalled channel
  /// (`AccessChannel.wireName` — "openai" / "telegram"). A `String` rather
  /// than `AccessChannel` so this shared type stays free of the access
  /// prototype's channel enum (Q-E.39.2).
  final String channel;

  /// Why the channel stalled. Terminality is derived from this reason — see
  /// [isTerminal].
  final StallReason reason;

  /// Whether the stall is permanent, derived from [reason]
  /// ([StallReasonTerminality.isTerminal]). `true` → the wire is gone (a
  /// disconnect / a closed channel); the engine must cancel the run, not
  /// resume. `false` → the stall is transient (a rate limit); the engine
  /// yields and retries. Not a stored field: a stall cannot disagree with
  /// its own reason.
  bool get isTerminal => reason.isTerminal;

  /// For a transient stall ([isTerminal] `false`), the minimum delay before a
  /// retry can succeed (the backend's `Retry-After`, when known). `null` for a
  /// terminal stall, or a transient stall with no known delay.
  final Duration? retryAfter;

  /// A short, content-free description of the stall for logs — never the
  /// prompt or the answer body. Defaults to empty.
  final String detail;

  /// Builds a stall signal. Terminality follows [reason]: a stall whose
  /// reason is terminal ([StallReasonTerminality.isTerminal]) must not carry a
  /// [retryAfter] (there is no retry), and a [retryAfter], when supplied, must
  /// be non-negative.
  DeliveryStalled({
    required this.channel,
    required this.reason,
    this.retryAfter,
    this.detail = '',
  }) {
    if (reason.isTerminal && retryAfter != null) {
      throw ArgumentError.value(
        retryAfter,
        'retryAfter',
        'a terminal stall (${reason.name}) cannot carry a retryAfter — '
            'there is no retry',
      );
    }
    if (retryAfter != null && retryAfter!.isNegative) {
      throw ArgumentError.value(
        retryAfter,
        'retryAfter',
        'must be non-negative when supplied',
      );
    }
  }

  /// A terminal stall — the wire is gone; the engine cancels the run. Used for
  /// the SSE [StallReason.clientDisconnected] / [StallReason.channelClosed]
  /// cases (E.37). Rejects a transient [reason], so the factory name can never
  /// disagree with the stored reason.
  factory DeliveryStalled.terminal({
    required String channel,
    required StallReason reason,
    String detail = '',
  }) {
    if (!reason.isTerminal) {
      throw ArgumentError.value(
        reason,
        'reason',
        'DeliveryStalled.terminal requires a terminal reason; '
            '${reason.name} is transient — use DeliveryStalled.transient',
      );
    }
    return DeliveryStalled(channel: channel, reason: reason, detail: detail);
  }

  /// A transient stall — the channel will recover; the engine yields and
  /// retries after [retryAfter]. Used for the Telegram [StallReason.rateLimited]
  /// case (E.38). Rejects a terminal [reason] and a negative [retryAfter].
  factory DeliveryStalled.transient({
    required String channel,
    required StallReason reason,
    Duration? retryAfter,
    String detail = '',
  }) {
    if (reason.isTerminal) {
      throw ArgumentError.value(
        reason,
        'reason',
        'DeliveryStalled.transient requires a transient reason; '
            '${reason.name} is terminal — use DeliveryStalled.terminal',
      );
    }
    return DeliveryStalled(
      channel: channel,
      reason: reason,
      retryAfter: retryAfter,
      detail: detail,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DeliveryStalled &&
      other.channel == channel &&
      other.reason == reason &&
      other.retryAfter == retryAfter &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(channel, reason, retryAfter, detail);

  @override
  String toString() => 'DeliveryStalled('
      'channel: $channel, '
      'reason: ${reason.name}, '
      'isTerminal: $isTerminal, '
      'retryAfter: $retryAfter'
      "${detail.isEmpty ? '' : ', detail: $detail'})";
}

/// The two streams a delivery path's `DeliverCallback` returns to signal
/// backpressure (or its absence).
///
/// The `DeliverCallback` signature returns `Stream<OutboundChunk>` (proto spec
/// § 10.1, kept verbatim). That stream is a pure *signal carrier* — it never
/// emits an [OutboundChunk]; it either completes empty ([clear]) or carries a
/// [BackpressureSignal] as an error ([stalled]). The engine listens to it
/// after each `deliver(chunk)` call.
abstract final class Backpressure {
  Backpressure._();

  /// The chunk was accepted and the channel is ready for the next one — the
  /// common case. An empty, normally-completing stream (no signal).
  static Stream<OutboundChunk> get clear =>
      const Stream<OutboundChunk>.empty();

  /// The channel stalled: the returned stream carries [signal] as a stream
  /// error so the engine, listening to it, yields. The element type is never
  /// produced — the stream is a pure signal carrier.
  static Stream<OutboundChunk> stalled(BackpressureSignal signal) =>
      Stream<OutboundChunk>.error(signal);
}
