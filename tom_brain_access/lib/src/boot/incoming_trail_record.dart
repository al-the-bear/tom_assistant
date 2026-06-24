// IncomingTrailRecord — the content-bearing inbound-request record emitted at
// access admission, pre-dispatch, for the §5.3 incoming-prompt trail
// (`tom_brain_logging.md` §5.3 / §9 / §10 step #7).
//
// Why this is NOT an `AccessEvent`:
//
//   The `AccessEventBus` taxonomy (`AccessCreated` / `AccessDelivered` /
//   `AccessFailed`) is deliberately privacy-bounded — "no variant carries the
//   prompt text" — so an observability consumer never sees user content. The
//   §5.3 incoming trail is the opposite contract: it captures the *full* prompt
//   text + the channel-specific raw envelope into the git-ignored raw tier so an
//   operator can read exactly what arrived. Routing those two needs through one
//   event would force user content onto the observability stream. So the
//   incoming trail rides its own dedicated sink, populated at the one admission
//   instant where channel + turnId + the full envelope + the resolved identity /
//   session / persona are all in scope (`AccessAssembler._admit`), and the
//   `AccessEvent` taxonomy keeps its no-content promise.
//
// Secret handling: this record carries `rawEnvelope` verbatim (the envelope's
// channel-specific `metadata`); the bearer / bot token never enters it because
// the credential is a *separate* admission argument, never a field of
// `InboundRequest`. The writer (`tom_brain_run`) redacts any secret-looking
// metadata keys as a defence-in-depth net before serialising (§5.3 "redacted of
// secrets").

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show InboundRequest, Persona, ResolvedIdentity, ResolvedProfile, Session,
        TurnId;

import '../identity/session_manager.dart' show AccessChannel;

/// One admitted inbound request, captured at the access-admission seam for the
/// §5.3 incoming-prompt trail.
///
/// Immutable. Built by [IncomingTrailRecord.fromAdmission] inside
/// `AccessAssembler._admit` from the in-scope admission values, then handed to
/// the configured [IncomingTrailSink] (the `tom_brain_run` `IncomingTrailWriter`
/// in full-trail mode; `null` — no sink — in unconfigured mode, §4.1).
final class IncomingTrailRecord {
  /// The turn correlation id minted at admission (the trail filename stem).
  final TurnId turnId;

  /// The channel the request arrived on (the trail sub-folder).
  final AccessChannel channel;

  /// The admission instant (UTC) — the closest available "receivedAt".
  final DateTime receivedAt;

  /// The resolved principal id ([ResolvedIdentity.principalId]). Never the
  /// bearer / bot credential.
  final String principalId;

  /// The resolved session id ([Session.sessionId]).
  final String sessionId;

  /// The conversation id from the envelope, when present.
  final String? conversationId;

  /// The memory profile pinned on the session ([Session.memoryProfile]), or
  /// `null` for the process default.
  final String? profile;

  /// The selected **processing** profile id ([ResolvedProfile.id]) — the third
  /// selection axis (session_configuration.md §7.2 item 6). Distinct from
  /// [profile] (the memory axis); `default` for a request that selected none.
  final String processingProfile;

  /// The processing profile's mode wire token ([ProfileMode.wireName]:
  /// `cognitive` / `answer` / `passthrough`).
  final String processingMode;

  /// Whether the assistant-dedication anchor was injected for this turn's
  /// prompts ([ResolvedProfile.anchored]). `true` for every default/anchored
  /// profile; `false` only for an explicitly un-anchored relay — recorded so
  /// every un-anchored run is auditable (§7.1).
  final bool anchored;

  /// The resolved persona id ([Persona.personaId]).
  final String persona;

  /// The full prompt text ([InboundRequest.text]).
  final String text;

  /// The inbound attachments. `InboundRequest` carries none yet (the gateway
  /// normalises to `text` + history), so this is empty for now; the field is
  /// present so the §5.3 shape is complete when attachments land.
  final List<Object?> attachments;

  /// The channel-specific raw envelope ([InboundRequest.metadata]) — the
  /// "rawEnvelope" §5.3 captures. Secret-looking keys are redacted by the
  /// writer before serialisation.
  final Map<String, Object?> rawEnvelope;

  IncomingTrailRecord({
    required this.turnId,
    required this.channel,
    required this.receivedAt,
    required this.principalId,
    required this.sessionId,
    required this.persona,
    required this.text,
    this.conversationId,
    this.profile,
    this.processingProfile = 'default',
    this.processingMode = 'cognitive',
    this.anchored = true,
    this.attachments = const [],
    this.rawEnvelope = const {},
  });

  /// Builds the record from the values in scope at the admission seam
  /// (`AccessAssembler._admit`), mirroring `AccessCreated.fromAccess` — but
  /// reading the *content* fields (`text`, `metadata`) the privacy-bounded
  /// event deliberately omits.
  factory IncomingTrailRecord.fromAdmission({
    required AccessChannel channel,
    required TurnId turnId,
    required DateTime receivedAt,
    required ResolvedIdentity identity,
    required Session session,
    required Persona persona,
    required ResolvedProfile profile,
    required InboundRequest envelope,
  }) =>
      IncomingTrailRecord(
        turnId: turnId,
        channel: channel,
        receivedAt: receivedAt,
        principalId: identity.principalId,
        sessionId: session.sessionId,
        conversationId: envelope.conversationId,
        profile: session.memoryProfile,
        processingProfile: profile.id,
        processingMode: profile.mode.wireName,
        anchored: profile.anchored,
        persona: persona.personaId,
        text: envelope.text,
        rawEnvelope: envelope.metadata,
      );
}

/// Sink the access assembler hands each admitted request's [IncomingTrailRecord]
/// to (the §5.3 incoming-prompt trail seam). The `tom_brain_run`
/// `IncomingTrailWriter.write` binds this in full-trail mode; unconfigured mode
/// leaves it `null` so the `incoming/` surface is never written (§4.1). The
/// assembler guards the call so a sink failure never fails the turn (§9).
typedef IncomingTrailSink = void Function(IncomingTrailRecord record);
