// Barrel for the `access/` module (Plan step D.11). This file also defines
// the `Access` type itself — keeping the primary type in the barrel matches
// the consumer-facing import path (`src/access/access.dart`) and mirrors the
// `budget/budget.dart` precedent.
//
// Module surface:
//
//   * `Access`           — defined below; the one canonical object the
//                          dispatcher's single entry point `accept(Access)`
//                          consumes regardless of channel (proto spec PE-11).
//   * `InboundRequest`   — the normalised inbound request (`inbound_request.dart`).
//   * `OutboundChunk`    — one increment of a streamed answer (`outbound_chunk.dart`).
//   * `ResolvedIdentity` — minimal principal handle (`resolved_identity.dart`).
//   * `Session`          — minimal conversation handle (`session.dart`).
//   * `Persona`          — persona → substrate-role handle (`persona.dart`).
//   * `DeliverCallback`  — the `deliver` field's function type (typedef below).
//
// Ownership boundary (D.4 — "still owned by Phase E; the dispatcher only
// consumes"):
//
//   1. The *shape* lives in `tom_brain_shared` (this module) so Phases D
//      and E import the identical type.
//   2. *Instances* are produced by Phase E (adapters, IdentityResolver,
//      SessionManager, PersonaResolver, DeliveryRegistry). Phase D never
//      constructs an `Access` from a wire payload; its conformance tests
//      (D.53) build synthetic ones directly.
//   3. The dispatcher consumes a closed read-surface: `envelope.text`,
//      `envelope.kindHint`, `persona` (→ substrate role), `identity`
//      (→ memory scope, opaque), `session` (→ run linkage, opaque), and
//      `deliver(chunk)`. It interprets nothing else.
//
// Why this lives in shared and not in `tom_brain_access`: two phases
// reference the type (Phase D consumes, Phase E produces); per the
// reuse rule a type two components share is declared once, in shared.

import 'dart:async';

import 'inbound_request.dart';
import 'outbound_chunk.dart';
import 'persona.dart';
import 'resolved_identity.dart';
import 'session.dart';

export 'access_event.dart'
    show AccessCreated, AccessDelivered, AccessEvent, AccessFailed;
export 'backpressure.dart'
    show Backpressure, BackpressureSignal, DeliveryStalled, StallReason;
export 'inbound_request.dart' show InboundRequest;
export 'outbound_chunk.dart' show OutboundChunk;
export 'persona.dart' show Persona;
export 'resolved_identity.dart' show ResolvedIdentity;
export 'session.dart' show Session;

/// The channel-specific callback that streams an answer chunk back to the
/// originating channel.
///
/// The engine / `answer_with_memory_v1` answer step calls this once per
/// [OutboundChunk] (D.38). The returned `Stream<OutboundChunk>` is the
/// backpressure channel (E.39): it never emits an [OutboundChunk] — it is a
/// pure signal carrier. It either completes empty ([Backpressure.clear] — the
/// chunk was accepted, the channel is ready for more) or carries a
/// [BackpressureSignal] as a stream *error* ([Backpressure.stalled] — the
/// channel cannot accept further chunks). On a stall the engine yields rather
/// than pushing into a dead/throttled wire: a terminal [DeliveryStalled] (an
/// SSE client disconnect) cancels the run; a transient one (a Telegram rate
/// limit) is retried after its `retryAfter`. The signature is kept verbatim
/// from proto spec § 10.1; E.39 finalises the semantics (Q-D.11.4 resolved).
typedef DeliverCallback = Stream<OutboundChunk> Function(OutboundChunk chunk);

/// The one canonical inbound object the dispatcher consumes regardless of
/// channel.
///
/// A Phase-E adapter (OpenAI HTTP/SSE, Telegram, …) constructs exactly one
/// `Access` per inbound request and hands it to `Dispatcher.accept`. The
/// dispatcher never speaks a wire protocol; every byte that goes back to the
/// originating channel goes through [deliver] (proto spec PE-11).
///
/// Immutable value object. The dispatcher never mutates it.
final class Access {
  /// The normalised inbound request. The dispatcher reads
  /// `envelope.text` and `envelope.kindHint`.
  final InboundRequest envelope;

  /// The resolved principal. Threaded into the memory `Scope`; treated
  /// opaquely by the dispatcher.
  final ResolvedIdentity identity;

  /// The conversation context. Used for run / session linkage; treated
  /// opaquely by the dispatcher.
  final Session session;

  /// The persona to hand to substrate. The dispatcher passes
  /// `persona.substrateRole` to the `llm` primitive's `role` path.
  final Persona persona;

  /// The channel-specific streaming-back callback. The *only* outbound
  /// path: the dispatcher hands it to the engine, which calls it per
  /// answer chunk. See [DeliverCallback].
  final DeliverCallback deliver;

  /// Builds an immutable `Access`. All five fields are required — an
  /// `Access` with a missing field could not be routed, scoped, answered,
  /// or delivered.
  ///
  /// Construction of [envelope] already rejects an empty / whitespace-only
  /// prompt (see `InboundRequest`), so an "empty inbound request" can
  /// never reach the dispatcher inside a valid `Access` (D.13).
  const Access({
    required this.envelope,
    required this.identity,
    required this.session,
    required this.persona,
    required this.deliver,
  });

  /// Value equality over the four value fields plus reference identity of
  /// the [deliver] closure. A function has no structural equality, so two
  /// `Access` objects are equal only when they carry the *same* closure
  /// instance; this keeps `==` consistent with [hashCode].
  @override
  bool operator ==(Object other) =>
      other is Access &&
      other.envelope == envelope &&
      other.identity == identity &&
      other.session == session &&
      other.persona == persona &&
      identical(other.deliver, deliver);

  @override
  int get hashCode => Object.hash(
        envelope,
        identity,
        session,
        persona,
        identityHashCode(deliver),
      );

  @override
  String toString() => 'Access('
      'envelope: $envelope, '
      'identity: $identity, '
      'session: $session, '
      'persona: $persona, '
      'deliver: <callback>)';
}
