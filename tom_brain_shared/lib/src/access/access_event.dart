// AccessEvent — the typed observability events for one Access lifecycle
// (Plan step D.12; def § 1.5; the access edge's observability surface).
//
// What this file owns:
//
//   * `AccessEvent` — a sealed sum extending `BrainEvent`, with the three
//     variants the plan names: `AccessCreated`, `AccessDelivered`,
//     `AccessFailed`. They trace one inbound request from the moment a
//     Phase-E adapter constructs an `Access` (created), through the answer
//     being streamed back to the originating channel (delivered), to a
//     terminal failure anywhere along the way (failed).
//
// Why these live in `tom_brain_shared` next to `Access`:
//
//   The `Access` *shape* lives here because two phases reference it (D.11:
//   Phase D consumes, Phase E produces). Its lifecycle events have the same
//   two-phase reach — Phase E emits `AccessCreated` / `AccessDelivered` /
//   `AccessFailed` from the edge (E.36 `DeliveryRegistry`, E.41 boot), and
//   the dispatcher / a Forge inspector observe them off the shared
//   `BrainEvent` base. A type two components reference is declared once, in
//   shared (the reuse rule), so the events sit beside the shape they observe.
//
// Why sealed:
//
//   Same reason `EngineEvent` (C.44) and `SubstrateEvent` (B.38) are sealed:
//   a new access-lifecycle variant is a contract change, not a silent
//   extension. Adding one bumps this list and forces every exhaustive
//   `switch` consumer to compile-error until it handles the new case.
//
// Why `runId` stays nullable (unlike `EngineEvent`):
//
//   An `Access` is created *before* the dispatcher opens a procedure run, so
//   `AccessCreated` legitimately has no `runId`. `AccessFailed` can fire at
//   the edge (auth / rate-limit / anchor pre-check, E.28–E.31) before any run
//   exists. So this taxonomy keeps `BrainEvent`'s nullable `runId` rather
//   than narrowing it to required the way `EngineEvent` does.
//
// Correlation (`accessId`, Q-D.12.1):
//
//   `Access` carries no first-class id (D.11). To tie the created → delivered
//   / failed triple of one inbound request together without inventing a new
//   id type, the base carries an opaque, nullable `accessId` the producer
//   supplies — typically the channel message id (`InboundRequest.messageId`)
//   or a generated correlation string. It follows `BrainEvent`'s
//   opaque-string philosophy for `runId` / `causedBy`. Whether `Access`
//   should grow a first-class id is recorded as Q-D.12.1; until then the
//   field is optional and the producer chooses the handle.
//
// Privacy: no variant carries the prompt `text` or the answer body. The
// events carry routing-relevant identity (principal / persona / conversation
// / message ids) and counts only — enough to trace and meter the edge
// without dumping user content into the observability stream.

import '../events/brain_event.dart';
// `access.dart` re-exports the sibling field types (InboundRequest,
// OutboundChunk, Persona, ResolvedIdentity, Session), so importing it alone
// brings every type these events read or reference in doc comments.
import 'access.dart';

/// Marker / base for every typed access-lifecycle observability event.
///
/// A consumer subscribed to the access edge's event stream sees only
/// subtypes of this class. The closed taxonomy is three variants —
/// [AccessCreated], [AccessDelivered], [AccessFailed]; an exhaustive
/// `switch` over them is the recommended branch surface.
///
/// Extends [BrainEvent], so each variant inherits `occurredAt` (UTC) +
/// `runId` + `causedBy`, the `payloadJson()` contract, the composed
/// `toJson()`, and the kebab-case `kind` discriminator
/// (`access.<event-name>`).
sealed class AccessEvent extends BrainEvent {
  /// Opaque correlation handle tying the created → delivered / failed
  /// triple of one inbound request together. Typically the channel
  /// message id ([InboundRequest.messageId]) or a generated correlation
  /// string. `null` when the producer has no handle yet (Q-D.12.1).
  final String? accessId;

  /// Builds the base of an access event.
  ///
  /// [runId] stays nullable (the [BrainEvent] default): an `Access` is
  /// created before any procedure run, and an edge failure can fire
  /// before a run exists.
  AccessEvent({
    required super.occurredAt,
    this.accessId,
    super.runId,
    super.causedBy,
  });
}

/// A Phase-E adapter constructed an [Access] for an inbound request and is
/// about to hand it to `Dispatcher.accept`.
///
/// Carries the routing-relevant identity of the request — never the prompt
/// `text`. Build it from a constructed [Access] with [AccessCreated.fromAccess].
final class AccessCreated extends AccessEvent {
  /// The resolved principal id ([ResolvedIdentity.principalId]).
  final String principalId;

  /// The resolved persona id ([Persona.personaId]).
  final String personaId;

  /// The conversation id from the inbound envelope, when present.
  final String? conversationId;

  /// The per-message id from the inbound envelope, when present.
  final String? messageId;

  /// Whether the originating request asked for a streamed response
  /// ([InboundRequest.streaming]).
  final bool streaming;

  /// The procedure-id hint the edge classifier pre-filled, when confident
  /// ([InboundRequest.kindHint]); `null` means the dispatcher will classify.
  final String? kindHint;

  AccessCreated({
    required super.occurredAt,
    super.accessId,
    super.runId,
    super.causedBy,
    required this.principalId,
    required this.personaId,
    this.conversationId,
    this.messageId,
    required this.streaming,
    this.kindHint,
  });

  /// Builds an [AccessCreated] by reading the routing identity off a
  /// constructed [Access]. Reads `identity.principalId`,
  /// `persona.personaId`, and the envelope's `conversationId` /
  /// `messageId` / `streaming` / `kindHint`. Never reads `envelope.text`.
  ///
  /// [accessId] defaults to the envelope's `messageId` when the caller
  /// supplies none — the most natural per-request correlation handle.
  factory AccessCreated.fromAccess(
    Access access, {
    required DateTime occurredAt,
    String? accessId,
    String? runId,
    String? causedBy,
  }) =>
      AccessCreated(
        occurredAt: occurredAt,
        accessId: accessId ?? access.envelope.messageId,
        runId: runId,
        causedBy: causedBy,
        principalId: access.identity.principalId,
        personaId: access.persona.personaId,
        conversationId: access.envelope.conversationId,
        messageId: access.envelope.messageId,
        streaming: access.envelope.streaming,
        kindHint: access.envelope.kindHint,
      );

  @override
  String get kind => 'access.created';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        if (accessId != null) 'accessId': accessId,
        'principalId': principalId,
        'personaId': personaId,
        if (conversationId != null) 'conversationId': conversationId,
        if (messageId != null) 'messageId': messageId,
        'streaming': streaming,
        if (kindHint != null) 'kindHint': kindHint,
      };
}

/// The answer for an [Access] was fully delivered back to the originating
/// channel — the terminal success of the edge's outbound path.
///
/// Carries the number of [OutboundChunk]s delivered (so a metrics consumer
/// can meter answer size) and the correlating identity — never the answer
/// body.
final class AccessDelivered extends AccessEvent {
  /// The resolved principal id the answer was delivered to.
  final String principalId;

  /// How many [OutboundChunk]s were delivered through the `deliver`
  /// callback. Must be `>= 0`; a single consolidated (non-streamed) answer
  /// is one chunk.
  final int chunkCount;

  /// The conversation id from the inbound envelope, when present.
  final String? conversationId;

  AccessDelivered({
    required super.occurredAt,
    super.accessId,
    super.runId,
    super.causedBy,
    required this.principalId,
    required this.chunkCount,
    this.conversationId,
  }) {
    if (chunkCount < 0) {
      throw ArgumentError.value(
        chunkCount,
        'chunkCount',
        'must be non-negative',
      );
    }
  }

  @override
  String get kind => 'access.delivered';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        if (accessId != null) 'accessId': accessId,
        'principalId': principalId,
        'chunkCount': chunkCount,
        if (conversationId != null) 'conversationId': conversationId,
      };
}

/// Processing or delivery for an [Access] failed — the terminal error of the
/// edge for one inbound request.
///
/// Can fire at the edge before any run exists (auth / rate-limit / anchor
/// pre-check, E.28–E.31), so [principalId] is optional: the identity may not
/// have resolved yet.
final class AccessFailed extends AccessEvent {
  /// The typed failure class — a stable kebab/dot string, e.g.
  /// `access.auth.rejected`, `access.delivery.stalled`,
  /// `access.dispatch.failed`. Non-empty.
  final String failureKind;

  /// A human-readable failure message (the stringified error).
  final String message;

  /// The resolved principal id when identity had resolved before the
  /// failure; `null` for edge failures that fire before resolution.
  final String? principalId;

  /// The conversation id from the inbound envelope, when present.
  final String? conversationId;

  AccessFailed({
    required super.occurredAt,
    super.accessId,
    super.runId,
    super.causedBy,
    required this.failureKind,
    required this.message,
    this.principalId,
    this.conversationId,
  }) {
    if (failureKind.isEmpty) {
      throw ArgumentError.value(
        failureKind,
        'failureKind',
        'must be non-empty',
      );
    }
  }

  @override
  String get kind => 'access.failed';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        if (accessId != null) 'accessId': accessId,
        'failureKind': failureKind,
        'message': message,
        if (principalId != null) 'principalId': principalId,
        if (conversationId != null) 'conversationId': conversationId,
      };
}
