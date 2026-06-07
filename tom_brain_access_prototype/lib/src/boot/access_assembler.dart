// AccessAssembler — the per-request admission pipeline that turns one
// validated inbound request into an `Access` and hands it to the dispatcher
// (E.41; proto spec § 8 / § 10.1 / § 13; AC-2 / AC-3 / AC-4 / AC-7 / AC-9).
//
// What this file owns:
//
//   The single place the access edge composes the four already-built
//   subsystems — edge security (E.28–E.31), the three `Access`-filling
//   resolvers (identity E.24, session E.25, persona E.26), the cheap
//   kind-hint classifier (E.33–E.34), and outbound delivery (E.36–E.38) —
//   into the documented inbound flow:
//
//     auth → identity → rate-limit → quota → anchor → session → classify →
//     bind delivery → build `Access` → emit `AccessCreated` → dispatch
//
//   Each component was built channel-blind and validate-or-throw on purpose
//   (E.24 – E.40); this is where they run in order, once per request. The two
//   public entry points ([admitOpenAi] / [admitTelegram]) differ only in how
//   they obtain the `ResolvedIdentity` and which `DeliveryBinding` they build
//   — everything after identity resolution is the shared [_admit] pipeline.
//
// Edge-chain order (proto spec § 8, AC-4). The cheapest, identity-scoped
// checks run first so a rejected/throttled principal sheds load before the
// content scan: auth (validate the credential) → identity (resolve *who*) →
// rate-limit → quota (both keyed on the resolved `principalId`) → anchor
// (content screen). Session resolution and classification run *after* the
// request is fully admitted, because they record/observe a request that is
// going to be answered — a rejected request must leave no session turn and
// trigger no embed call. The first failing check short-circuits the rest
// (validate-or-throw), so no `Access` is ever built for a request that did not
// pass every gate (AC-3 / AC-4).
//
// Failure observability (proto spec § 13.2). The public methods wrap the whole
// flow in one try/catch that tracks the `principalId` *once it is known* (it is
// null for an auth / identity failure that fires before resolution). On any
// failure the assembler emits a correlated `AccessFailed` — its `failureKind`
// mapped from the thrown type by [_failureKindFor] — and then **rethrows**, so
// the channel edge (E.45) can still map the same error onto its wire shape (the
// OpenAI `401` / `429` / `400` envelope, the graceful Telegram message). The
// `AccessFailed` event is the *observability* record; the rethrow is the
// *control flow*. The two are deliberately separate.
//
// Graceful classifier degradation (AC-9, proto spec § 13.1). A classifier seam
// failure is NOT an access failure: `access.classify.unavailable` is a
// degradation, not a leaf of `AccessEvent`. So [_classify] swallows a throwing
// classifier and proceeds with no hint (the dispatcher's `classify_inbound_v1`
// then takes over, D.15). A swallowed classify error therefore never reaches
// the failure catch and never emits an `AccessFailed`.
//
// What this file does NOT do:
//
//   * No wire protocol. It never reads an HTTP request or a Telegram update;
//     the channel edges (E.45) call [admitOpenAi] / [admitTelegram] with the
//     already-decoded credential + envelope + channel sink. The HTTP serve
//     loop and the Telegram inbound-stream driving are E.45 (see the questions
//     doc) — this assembler is the admission core they drive.
//   * No substrate / memory dependency. The classifier reaches substrate +
//     memory only through the injected `HeuristicKindHintClassifier` seams
//     (E.33); boot binds them. The dispatcher is the only lower layer this
//     file names, and only as the `accept(Access)` boundary (the access layer
//     never depends on `tom_brain_memory` / `tom_brain_substrate`).

import 'package:tom_core_agentic/tom_core_agentic.dart' show systemClock;
import 'package:tom_core_kernel/tom_core_kernel.dart' show TomPrincipal;
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart'
    show Dispatcher;
import 'package:tom_brain_shared/tom_brain_shared.dart';

import '../adapters/openai_http_sse/chat_completion_sse.dart';
import '../delivery/channel_delivery.dart';
import '../delivery/chunk_stream_delivery.dart';
import '../delivery/delivery_registry.dart';
import '../delivery/sse_delivery.dart';
import '../delivery/telegram_delivery.dart';
import '../edge_security/edge_security.dart';
import '../heuristic_classifier/heuristic_kind_hint_classifier.dart';
import '../identity/identity_resolver.dart';
import '../identity/memory_profile_selector.dart';
import '../identity/persona_resolver.dart';
import '../identity/session_manager.dart';
import 'access_event_bus.dart';

/// Builds the channel-specific [DeliveryBinding] for one admitted request.
///
/// Called by [_admit] *after* identity has resolved and the envelope has been
/// classified, so the binding can carry both the [ResolvedIdentity] and the
/// effective (possibly kind-hinted) [InboundRequest] the registry needs to emit
/// a correlated `AccessDelivered`. The closure closes over the channel-specific
/// wire (the SSE sink + renderer, or the Telegram sink), which only the public
/// entry point knows.
typedef _BuildBinding = DeliveryBinding Function(
  ResolvedIdentity identity,
  InboundRequest envelope,
);

/// The per-request admission pipeline (E.41).
///
/// One instance per running access layer, assembled by `BrainAccessBoot` over
/// a booted [Dispatcher]. The channel edges (E.45) call [admitOpenAi] /
/// [admitTelegram] once per inbound request; the assembler runs the edge-chain,
/// fills the `Access`, emits the lifecycle events, and dispatches.
final class AccessAssembler {
  /// The booted dispatcher's single entry point. Every admitted request lands
  /// on `dispatcher.accept(access)` (PE-11); the assembler never reaches past
  /// it into the engine or memory.
  final Dispatcher dispatcher;

  /// Credential → [ResolvedIdentity] (E.24). Resolution is a registry lookup;
  /// an unbound credential throws [IdentityResolutionException].
  final IdentityResolver identityResolver;

  /// Conversation → sliding-window session (E.25). Resolving a request records
  /// its turn; the projected [Session] handle rides the `Access`.
  final SessionManager sessionManager;

  /// Model id → [Persona] (E.26). An absent / unknown model id defaults to
  /// `Persona.assistant()` (AC-5).
  final PersonaResolver personaResolver;

  /// Short-horizon per-principal burst throttle (E.29). Throws
  /// [RateLimitExceeded] when the bucket is empty.
  final RateLimiter rateLimiter;

  /// Long-horizon per-principal daily cap (E.30). Throws [DailyQuotaExceeded]
  /// once the cap is reached.
  final DailyQuotaLimiter quotaLimiter;

  /// Stateless content screen (E.31). Throws [AnchorPreCheckRejected] when the
  /// prompt trips a disallowed signature.
  final AnchorPreCheck anchorPreCheck;

  /// The optional bearer-credential authenticator (E.28). When non-null,
  /// [admitOpenAi] validates the credential *before* resolving identity; a
  /// failure throws [BearerAuthFailure]. `null` leaves bearer validation to a
  /// deployment that authenticates upstream (the identity registry still
  /// rejects an unbound token).
  final BearerTokenAuthenticator? bearerAuthenticator;

  /// The optional cheap kind-hint classifier (E.33–E.34). When non-null and the
  /// envelope carries no hint, [_classify] attaches a confident hint; a seam
  /// failure degrades gracefully to no hint (AC-9). `null` skips classification
  /// entirely (the dispatcher classifies every request).
  final HeuristicKindHintClassifier? classifier;

  /// Channel-agnostic outbound dispatcher (E.36). Produces the per-`Access`
  /// `deliver` callback from the channel binding and emits `AccessDelivered`
  /// on the final chunk (its `onDelivered` sink is wired to [eventBus]).
  final DeliveryRegistry deliveryRegistry;

  /// The access edge's lifecycle event bus (E.41). The assembler emits
  /// `AccessCreated` (on dispatch) and `AccessFailed` (on any failure); the
  /// registry emits `AccessDelivered`.
  final AccessEventBus eventBus;

  final DateTime Function() _clock;

  /// Builds the assembler over its already-constructed collaborators.
  ///
  /// [clock] stamps the emitted lifecycle events (`occurredAt`, always
  /// normalised to UTC); it defaults to [DateTime.now].
  AccessAssembler({
    required this.dispatcher,
    required this.identityResolver,
    required this.sessionManager,
    required this.personaResolver,
    required this.rateLimiter,
    required this.quotaLimiter,
    required this.anchorPreCheck,
    required this.deliveryRegistry,
    required this.eventBus,
    this.bearerAuthenticator,
    this.classifier,
    DateTime Function()? clock,
  }) : _clock = clock ?? systemClock;

  /// Admits one OpenAI HTTP/SSE request.
  ///
  /// [bearerToken] is the credential lifted from the `Authorization` header
  /// (E.28's `parseBearerHeader`); [modelId] is the requested persona-as-model
  /// id (or `null`); [envelope] is the decoded inbound request; [sink] is the
  /// SSE wire bound to this response. When a [bearerAuthenticator] is wired the
  /// credential is validated first; identity then resolves through
  /// [IdentityResolver.resolveOpenAiBearer]; the persona resolves from
  /// [modelId]; and the request runs the shared [_admit] pipeline with an
  /// [SseDeliveryBinding] carrying [sink] and a per-`Access`
  /// [ChatCompletionSseRenderer] stamped with the resolved persona id (E.15).
  ///
  /// Throws (after emitting a correlated `AccessFailed`) the typed edge failure
  /// for the channel edge (E.45) to map onto the OpenAI error envelope.
  Future<void> admitOpenAi({
    required String bearerToken,
    String? modelId,
    required InboundRequest envelope,
    required SseSink sink,
  }) async {
    String? principalId;
    try {
      final ResolvedIdentity identity = authenticateOpenAi(bearerToken);
      principalId = identity.principalId;
      final Persona persona = personaResolver.resolve(modelId);
      await _admit(
        channel: AccessChannel.openai,
        identity: identity,
        envelope: envelope,
        persona: persona,
        buildBinding: (resolvedIdentity, effectiveEnvelope) =>
            SseDeliveryBinding(
          identity: resolvedIdentity,
          envelope: effectiveEnvelope,
          sink: sink,
          renderer: ChatCompletionSseRenderer.forModel(persona.personaId),
        ),
      );
    } catch (error) {
      _emitFailure(error, envelope: envelope, principalId: principalId);
      rethrow;
    }
  }

  /// Validates an OpenAI bearer credential and resolves the principal, without
  /// running the cognition admission pipeline — the auth gate the embeddings
  /// passthrough reuses (E.51.1 / Q-E.51.1).
  ///
  /// Embeddings are a substrate passthrough, not a cognition (§ 5.6): they
  /// never build an `Access`, never touch the dispatcher, and run none of the
  /// rate-limit / quota / anchor gates (those are reserved for a later
  /// mediated path, Q-E.2.2). But the live edge is auth-gated, so the
  /// passthrough must still reject a missing / invalid / unbound credential.
  /// This runs exactly the auth → identity prefix [admitOpenAi] uses and
  /// returns the resolved [ResolvedIdentity]. It emits no lifecycle event —
  /// there is no `Access` to correlate — and throws the same typed
  /// [BearerAuthFailure] / [IdentityResolutionException] for the channel edge
  /// (E.45) to map onto the OpenAI `401` envelope.
  ///
  /// Composition (Q-E.51.4). When a [bearerAuthenticator] is wired it validates
  /// the credential and yields the principal, which is resolved *directly*
  /// through [IdentityResolver.resolveBearerPrincipal] — identity is never
  /// re-resolved from the raw secret token, so an authenticated principal with
  /// no identity binding is one coherent [IdentityResolutionException] (a valid
  /// JWT for an unprovisioned principal fails resolution, not auth). With no
  /// authenticator wired the identity registry is the sole gate: the raw token
  /// is resolved through [IdentityResolver.resolveBearer] (an unbound token
  /// still fails resolution).
  ResolvedIdentity authenticateOpenAi(String bearerToken) =>
      _authenticateBearer(bearerToken, AccessChannel.openai);

  /// Validates a bearer credential arriving over [channel] and resolves the
  /// principal — the channel-blind auth → identity prefix the three HTTP bearer
  /// channels share (OpenAI E.28, Ollama #27, Anthropic #28).
  ///
  /// Identity is channel-blind (E.24): all bearer channels share one
  /// `bearerTokenBindings` map, so the only thing [channel] varies is the name
  /// stamped onto an [IdentityResolutionException]. When a [bearerAuthenticator]
  /// is wired it validates the credential and the principal is resolved through
  /// [IdentityResolver.resolveBearerPrincipal]; otherwise the raw token is
  /// resolved through [IdentityResolver.resolveBearer]. Either way an unbound
  /// credential surfaces as a typed failure, never a fabricated identity.
  ResolvedIdentity _authenticateBearer(
    String bearerToken,
    AccessChannel channel,
  ) {
    final BearerTokenAuthenticator? authenticator = bearerAuthenticator;
    if (authenticator == null) {
      return identityResolver.resolveBearer(
        bearerToken,
        channel: channel.wireName,
      );
    }
    final TomPrincipal principal = authenticator.authenticate(bearerToken);
    return identityResolver.resolveBearerPrincipal(
      principal,
      channel: channel.wireName,
    );
  }

  /// Admits one Telegram request.
  ///
  /// [userId] is the (whitelist-validated, E.22) Telegram sender id; [envelope]
  /// is the mapped inbound request (E.20); [sink] is the Telegram wire bound to
  /// the sender's chat. Identity resolves through
  /// [IdentityResolver.resolveTelegramUser]; the persona defaults
  /// (`resolve(null)` → `Persona.assistant()`, AC-5 — Telegram names no model);
  /// and the request runs the shared [_admit] pipeline with a
  /// [TelegramDeliveryBinding] carrying [sink].
  ///
  /// Throws (after emitting a correlated `AccessFailed`) the typed edge failure
  /// for the channel edge (E.45) to map onto the graceful Telegram message.
  ///
  /// [onAdmitted], when supplied, is awaited once the request has passed every
  /// edge gate and is about to be dispatched — the seam the Telegram edge uses
  /// to send its immediate "Processing" acknowledgement (so a gate-rejected
  /// request, which never reaches dispatch, draws only its decline and not a
  /// contradictory ack). It runs *before* `dispatcher.accept`, so the ack
  /// precedes the streamed answer.
  Future<void> admitTelegram({
    required String userId,
    required InboundRequest envelope,
    required TelegramSink sink,
    Future<void> Function()? onAdmitted,
  }) async {
    String? principalId;
    try {
      final ResolvedIdentity identity =
          identityResolver.resolveTelegramUser(userId);
      principalId = identity.principalId;
      final Persona persona = personaResolver.resolve(null);
      await _admit(
        channel: AccessChannel.telegram,
        identity: identity,
        envelope: envelope,
        persona: persona,
        buildBinding: (resolvedIdentity, effectiveEnvelope) =>
            TelegramDeliveryBinding(
          identity: resolvedIdentity,
          envelope: effectiveEnvelope,
          sink: sink,
        ),
        onAdmitted: onAdmitted,
      );
    } catch (error) {
      _emitFailure(error, envelope: envelope, principalId: principalId);
      rethrow;
    }
  }

  /// Admits one Ollama HTTP request (plan-2 #27).
  ///
  /// Ollama is a bearer HTTP channel like OpenAI, but its adapter renders its
  /// own NDJSON / buffered-JSON dialect from the raw `OutboundChunk` stream
  /// rather than reusing the SSE frames — so it delivers over a
  /// [ChunkStreamDeliveryBinding] (the sink the adapter drains), not an
  /// [SseDeliveryBinding]. Everything else mirrors [admitOpenAi]: auth →
  /// identity → the shared [_admit] pipeline. See [_admitHttpChunkStream].
  Future<void> admitOllama({
    required String bearerToken,
    String? modelId,
    required InboundRequest envelope,
    required OutboundChunkSink sink,
  }) =>
      _admitHttpChunkStream(
        channel: AccessChannel.ollama,
        bearerToken: bearerToken,
        modelId: modelId,
        envelope: envelope,
        sink: sink,
      );

  /// Admits one Anthropic Messages HTTP request (plan-2 #28).
  ///
  /// Anthropic is a bearer HTTP channel like OpenAI, but its adapter renders
  /// its own named-SSE / buffered-Message dialect from the raw `OutboundChunk`
  /// stream — so, like Ollama, it delivers over a [ChunkStreamDeliveryBinding].
  /// Everything else mirrors [admitOpenAi]: auth → identity → the shared
  /// [_admit] pipeline. See [_admitHttpChunkStream].
  Future<void> admitAnthropic({
    required String bearerToken,
    String? modelId,
    required InboundRequest envelope,
    required OutboundChunkSink sink,
  }) =>
      _admitHttpChunkStream(
        channel: AccessChannel.anthropic,
        bearerToken: bearerToken,
        modelId: modelId,
        envelope: envelope,
        sink: sink,
      );

  /// The shared admission edge for the adapter-renders HTTP bearer channels
  /// (Ollama #27, Anthropic #28).
  ///
  /// The chunk-stream analogue of [admitOpenAi]: the credential is authenticated
  /// for [channel] (the channel-blind [_authenticateBearer] prefix), the persona
  /// resolves from [modelId], and the request runs the shared [_admit] pipeline
  /// with a [ChunkStreamDeliveryBinding] carrying [sink] — the raw-chunk wire the
  /// originating adapter drains and renders into its own dialect. On any failure
  /// it emits a correlated `AccessFailed` and rethrows, exactly as the other
  /// edges do, so the channel edge can map the error onto its wire shape.
  Future<void> _admitHttpChunkStream({
    required AccessChannel channel,
    required String bearerToken,
    required String? modelId,
    required InboundRequest envelope,
    required OutboundChunkSink sink,
  }) async {
    String? principalId;
    try {
      final ResolvedIdentity identity =
          _authenticateBearer(bearerToken, channel);
      principalId = identity.principalId;
      final Persona persona = personaResolver.resolve(modelId);
      await _admit(
        channel: channel,
        identity: identity,
        envelope: envelope,
        persona: persona,
        buildBinding: (resolvedIdentity, effectiveEnvelope) =>
            ChunkStreamDeliveryBinding(
          channel: channel,
          identity: resolvedIdentity,
          envelope: effectiveEnvelope,
          sink: sink,
        ),
      );
    } catch (error) {
      _emitFailure(error, envelope: envelope, principalId: principalId);
      rethrow;
    }
  }

  /// The shared admission pipeline, run once identity + persona are resolved.
  ///
  /// Order (AC-4): rate-limit → quota → anchor (the remaining edge gates) →
  /// session resolution (records the turn) → classify (graceful, AC-9) → bind
  /// delivery → build the `Access` → emit `AccessCreated` → `dispatcher.accept`.
  /// A throw from any edge gate propagates to the public method's catch (which
  /// emits `AccessFailed` and rethrows); a classifier failure is swallowed in
  /// [_classify] and never reaches that catch.
  Future<void> _admit({
    required AccessChannel channel,
    required ResolvedIdentity identity,
    required InboundRequest envelope,
    required Persona persona,
    required _BuildBinding buildBinding,
    Future<void> Function()? onAdmitted,
  }) async {
    final String principalId = identity.principalId;

    // ── Remaining edge gates (auth + identity already ran in the caller). ──
    rateLimiter.check(principalId);
    quotaLimiter.check(principalId);
    anchorPreCheck.check(envelope.text);

    // ── Session: resolve the conversation and record this turn against its
    //    histories (the request is now fully admitted, so it legitimately gets
    //    a turn). The resolution carries the history the engine answers from. ──
    final SessionResolution session = sessionManager.resolve(
      identity: identity,
      channel: channel,
      envelope: envelope,
    );

    // ── Memory-profile selection (Extension H, access spec § 7.4): pick the
    //    profile this conversation recalls against and stamp it on the session
    //    handle. Disabled / unwired → the process default (no pinned name); a
    //    selector outage degrades gracefully (PE-6), it is not a failure. ──
    final MemoryProfileSelectionOutcome profileOutcome =
        await sessionManager.selectMemoryProfile(
      resolution: session,
      envelope: envelope,
    );
    final Session stampedSession =
        session.session.withMemoryProfile(profileOutcome.profile);

    // ── Classify (graceful, AC-9): attach a confident kind-hint or leave the
    //    envelope untouched; a classifier outage is not a failure. ──
    final InboundRequest effectiveEnvelope = await _classify(envelope);

    // ── Delivery: bind the channel wire to the per-`Access` deliver callback. ──
    final DeliveryBinding binding = buildBinding(identity, effectiveEnvelope);
    final DeliverCallback deliver = deliveryRegistry.deliverFor(binding);

    // ── Build the one canonical Access and announce it before dispatch. ──
    final Access access = Access(
      envelope: effectiveEnvelope,
      identity: identity,
      session: stampedSession,
      persona: persona,
      deliver: deliver,
      history: session.history,
    );
    eventBus.emit(
      AccessCreated.fromAccess(access, occurredAt: _clock().toUtc()),
    );

    // The request is fully admitted and about to be dispatched: fire the
    // post-admission hook (the Telegram edge's immediate "Processing" ack)
    // before the run streams, so a gate-rejected request never reaches here and
    // the ack always precedes the answer.
    if (onAdmitted != null) {
      await onAdmitted();
    }

    await dispatcher.accept(access);
  }

  /// Runs the cheap kind-hint classifier over [envelope], returning the
  /// envelope to dispatch.
  ///
  /// No classifier wired, or the envelope already carries a hint → return it
  /// unchanged. A confident classification → a copy with the hint attached
  /// (via [_withKindHint], since `InboundRequest` has no `copyWith`). A
  /// non-confident classification → the original (no hint). A classifier seam
  /// *failure* → the original, swallowed: `access.classify.unavailable` is
  /// graceful degradation (AC-9), not an access failure, so the dispatcher's
  /// `classify_inbound_v1` simply takes over.
  Future<InboundRequest> _classify(InboundRequest envelope) async {
    final HeuristicKindHintClassifier? classifier = this.classifier;
    if (classifier == null || envelope.kindHint != null) {
      return envelope;
    }
    try {
      final String? hint = await classifier.classifyKindHint(envelope.text);
      if (hint == null) {
        return envelope;
      }
      return _withKindHint(envelope, hint);
    } catch (_) {
      // AC-9: the classifier is allowed to be unavailable. Degrade to no hint;
      // never surface this as an `AccessFailed`.
      return envelope;
    }
  }

  /// Emits a correlated `AccessFailed` for [error].
  ///
  /// The correlation handle is the envelope's `messageId` (the same default
  /// `AccessCreated` uses); [principalId] is carried when identity had resolved
  /// before the failure (null for an auth / identity failure). The `failureKind`
  /// is mapped from the thrown type by [_failureKindFor].
  void _emitFailure(
    Object error, {
    required InboundRequest envelope,
    required String? principalId,
  }) {
    eventBus.emit(
      AccessFailed(
        occurredAt: _clock().toUtc(),
        accessId: envelope.messageId,
        failureKind: _failureKindFor(error),
        message: error.toString(),
        principalId: principalId,
        conversationId: envelope.conversationId,
      ),
    );
  }

  /// Maps a thrown edge / dispatch error to its stable `AccessFailed.failureKind`
  /// string (proto spec § 13.2).
  ///
  /// The four edge-security failures and the identity-resolution failure each
  /// get a distinct kind; anything else (a dispatch / engine failure surfacing
  /// through `dispatcher.accept`) is the catch-all `access.dispatch.failed`.
  static String _failureKindFor(Object error) {
    if (error is BearerAuthFailure) {
      return 'access.auth.failed';
    }
    if (error is IdentityResolutionException) {
      return 'access.identity.unresolved';
    }
    if (error is RateLimitExceeded) {
      return 'access.ratelimit.exceeded';
    }
    if (error is DailyQuotaExceeded) {
      return 'access.quota.exceeded';
    }
    if (error is AnchorPreCheckRejected) {
      return 'access.anchor.precheck.rejected';
    }
    return 'access.dispatch.failed';
  }

  /// Rebuilds [envelope] with [hint] as its `kindHint`, preserving every other
  /// field. `InboundRequest` is immutable and has no `copyWith`, so attaching a
  /// hint is a full reconstruction.
  static InboundRequest _withKindHint(InboundRequest envelope, String hint) =>
      InboundRequest(
        text: envelope.text,
        kindHint: hint,
        conversationId: envelope.conversationId,
        messageId: envelope.messageId,
        streaming: envelope.streaming,
        metadata: envelope.metadata,
      );
}
