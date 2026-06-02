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
//   * `StallReason` — the closed reason set, and the `isTerminal` /
//     `retryAfter` fields the engine keys on to decide between *cancel the
//     run* (a terminal stall — the SSE client is gone) and *yield, then retry
//     after [retryAfter]* (a transient stall — the rate limit clears).
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

  /// Why the channel stalled.
  final StallReason reason;

  /// Whether the stall is permanent. `true` → the wire is gone (a disconnect /
  /// a closed channel); the engine must cancel the run, not resume. `false` →
  /// the stall is transient (a rate limit); the engine yields and retries.
  final bool isTerminal;

  /// For a transient stall ([isTerminal] `false`), the minimum delay before a
  /// retry can succeed (the backend's `Retry-After`, when known). `null` for a
  /// terminal stall, or a transient stall with no known delay.
  final Duration? retryAfter;

  /// A short, content-free description of the stall for logs — never the
  /// prompt or the answer body. Defaults to empty.
  final String detail;

  /// Builds a stall signal. A terminal stall must not carry a [retryAfter]
  /// (there is no retry), and a transient stall's [retryAfter], when supplied,
  /// must be non-negative.
  DeliveryStalled({
    required this.channel,
    required this.reason,
    required this.isTerminal,
    this.retryAfter,
    this.detail = '',
  }) {
    if (isTerminal && retryAfter != null) {
      throw ArgumentError.value(
        retryAfter,
        'retryAfter',
        'a terminal stall cannot carry a retryAfter — there is no retry',
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
  /// cases (E.37). Redirects to the primary constructor so it shares the same
  /// validation.
  DeliveryStalled.terminal({
    required String channel,
    required StallReason reason,
    String detail = '',
  }) : this(
          channel: channel,
          reason: reason,
          isTerminal: true,
          detail: detail,
        );

  /// A transient stall — the channel will recover; the engine yields and
  /// retries after [retryAfter]. Used for the Telegram [StallReason.rateLimited]
  /// case (E.38). Redirects to the primary constructor so a negative
  /// [retryAfter] is rejected here too.
  DeliveryStalled.transient({
    required String channel,
    required StallReason reason,
    Duration? retryAfter,
    String detail = '',
  }) : this(
          channel: channel,
          reason: reason,
          isTerminal: false,
          retryAfter: retryAfter,
          detail: detail,
        );

  @override
  bool operator ==(Object other) =>
      other is DeliveryStalled &&
      other.channel == channel &&
      other.reason == reason &&
      other.isTerminal == isTerminal &&
      other.retryAfter == retryAfter &&
      other.detail == detail;

  @override
  int get hashCode =>
      Object.hash(channel, reason, isTerminal, retryAfter, detail);

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
