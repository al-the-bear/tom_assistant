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
import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show Dispatcher;
import 'package:tom_brain_shared/tom_brain_shared.dart';

import '../adapters/openai_http_sse/chat_completion_sse.dart';
import '../config/api_key_config.dart';
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
import 'api_key_registrar.dart';
import 'incoming_trail_record.dart';

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
final class AccessAssembler implements ApiKeyRegistrar {
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

  /// Resolves a token's `profile-<name>` marker to its boot-resolved
  /// [ResolvedProfile] (session_configuration.md § 4, plan step 5, SCP-18).
  /// `null` (the pre-feature default, profiles off) resolves every request to
  /// `ResolvedProfile.cognitiveDefault()` — the SC-5 byte-compatible default —
  /// so `Access.profile` keeps today's behaviour with no wiring. When wired, the
  /// run-side provisioner supplies it over the live `ProfileRegistry`; an unknown
  /// profile throws [ProfileResolutionException] (mapped to `400` /
  /// `profile.unknown` at the edge).
  final ProfileResolver? profileResolver;

  /// The per-(principal, profileId) request-per-minute gate that composes a
  /// profile's `rateLimits` with the global [rateLimiter] (SC-8 / SCP-19). A
  /// no-op for the default profile (no per-minute limit). Always present; the
  /// default profile simply never charges it.
  final ProfileRateLimiter profileRateLimiter;

  /// The optional bearer-credential authenticator (E.28). When non-null,
  /// [admitOpenAi] validates the credential *before* resolving identity; a
  /// failure throws [BearerAuthFailure]. `null` leaves bearer validation to a
  /// deployment that authenticates upstream (the identity registry still
  /// rejects an unbound token).
  final BearerTokenAuthenticator? bearerAuthenticator;

  /// The configured API keys, indexed by their (residual) secret
  /// (memory_session_profiles.md § 5 / § 3.2). When an authenticated residual
  /// key has an entry here, its `sessionPrefix` / `memoryPrefix` namespace the
  /// session + memory ids the token's markers selected ([ApiKeyConfig.resolveScope],
  /// MSP-4). A key with no entry (or the no-authenticator default empty map)
  /// applies no scope — the session resolves as it always did. Only consulted on
  /// the token-keyed bearer path; the authenticator-wired (JWT) path skips marker
  /// parsing entirely (base64url tokens contain `_`).
  ///
  /// Growable: `/create_api_key` (MSP-7) admits a runtime key into it through
  /// [admit] (the namespace half of live admission, MSPP-42); the constructor
  /// copies the supplied map so the caller's is never mutated.
  final Map<String, ApiKeyConfig> apiKeysByKey;

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

  /// The optional §5.3 incoming-prompt trail sink (`tom_brain_logging.md`
  /// §10 step #7). When non-null, [_admit] hands it one [IncomingTrailRecord]
  /// per admitted request at the dispatch boundary — the content-bearing
  /// counterpart to the privacy-bounded `AccessCreated` event. `null` (the
  /// unconfigured / no-trail default) leaves the `incoming/` surface unwritten.
  /// The call is guarded so a sink failure never fails the turn (§9).
  final IncomingTrailSink? incomingTrailSink;

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
    Map<String, ApiKeyConfig> apiKeysByKey = const {},
    this.classifier,
    this.incomingTrailSink,
    this.profileResolver,
    ProfileRateLimiter? profileRateLimiter,
    DateTime Function()? clock,
  })  : apiKeysByKey = Map.of(apiKeysByKey),
        profileRateLimiter =
            profileRateLimiter ?? ProfileRateLimiter(clock: clock),
        _clock = clock ?? systemClock;

  /// Admits a runtime API key into the live registry (`/create_api_key`,
  /// MSP-7 — [ApiKeyRegistrar.admit]).
  ///
  /// Mutates both structures the no-authenticator bearer path consults, so the
  /// key takes effect on the very next request: the identity registry (so the
  /// residual key authenticates to [config]'s principal) and [apiKeysByKey] (so
  /// the key scopes sessions/memory into [config]'s namespace). One operation,
  /// both maps — the orchestration ([ApiKeyCreator]) never sees the split.
  @override
  void admit(ApiKeyConfig config) {
    apiKeysByKey[config.key] = config;
    identityResolver.admitBearer(config.key, config.toBinding());
  }

  /// Removes a runtime API key from the live registry — the exact reverse of
  /// [admit] ([ApiKeyRegistrar.revoke]).
  ///
  /// Used to roll back a live admission when the durable persist fails (§ 13),
  /// so the running process never authenticates a key that did not survive to
  /// disk (live == disk).
  @override
  void revoke(ApiKeyConfig config) {
    apiKeysByKey.remove(config.key);
    identityResolver.revokeBearer(config.key);
  }

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
      final ({
        ResolvedIdentity identity,
        ResolvedProfileScope? scope,
        ResolvedProfile profile,
      }) auth = _authenticateBearerScoped(bearerToken, AccessChannel.openai);
      final ResolvedIdentity identity = auth.identity;
      principalId = identity.principalId;
      final Persona persona = personaResolver.resolve(modelId);
      await _admit(
        channel: AccessChannel.openai,
        identity: identity,
        envelope: envelope,
        persona: persona,
        profile: auth.profile,
        scope: auth.scope,
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
  /// Discards any profile scope; the scope-aware [_authenticateBearerScoped] is
  /// the full path the cognition edges use. This thin wrapper is the auth-only
  /// view the embeddings passthrough ([authenticateOpenAi]) reuses — embeddings
  /// build no `Access`, so a session/memory selection has nowhere to land.
  ResolvedIdentity _authenticateBearer(
    String bearerToken,
    AccessChannel channel,
  ) =>
      _authenticateBearerScoped(bearerToken, channel).identity;

  /// Validates a bearer credential over [channel] and resolves both the
  /// principal *and* the (optional) profile scope its embedded markers select
  /// (memory_session_profiles.md § 3 / § 4).
  ///
  /// Two paths, by whether a [bearerAuthenticator] is wired:
  ///
  ///   * **Authenticator-wired (JWT, MSP-3 carve-out).** The full token is
  ///     authenticated as-is and the principal resolved through
  ///     [IdentityResolver.resolveBearerPrincipal] — *no marker parse*. A
  ///     base64url JWT legitimately contains `_`, so splitting it on `_` would
  ///     corrupt the credential; a deployment that authenticates upstream opts
  ///     out of credential-embedded selection. Scope is always `null`.
  ///   * **Token-keyed (the API-key path).** The token is split into its
  ///     markers + residual ([parseApiKeyMarkers], § 3.1); the residual (or the
  ///     `no-key` substitute for an empty residual, § 6) is authenticated
  ///     through [IdentityResolver.resolveBearer]. When that residual key has an
  ///     [ApiKeyConfig] in [apiKeysByKey], its prefixes resolve the markers into
  ///     a [ResolvedProfileScope] (MSP-4); a key with no entry resolves the
  ///     markers under the built-in **default** prefixes ([resolveDefaultScope],
  ///     MSPP-62) so no token runs bare-root (§ 8.1).
  ///
  /// Either way an unbound credential surfaces as a typed failure, never a
  /// fabricated identity; a duplicate marker throws [ApiKeyMarkerException]
  /// before authentication (the edge maps it to `400`, § 13).
  ({
    ResolvedIdentity identity,
    ResolvedProfileScope? scope,
    ResolvedProfile profile,
  }) _authenticateBearerScoped(
    String bearerToken,
    AccessChannel channel,
  ) {
    final BearerTokenAuthenticator? authenticator = bearerAuthenticator;
    if (authenticator != null) {
      // The JWT carve-out parses no markers (MSP-3): no session/memory/profile
      // selection rides an upstream-authenticated token, so the request runs the
      // default profile and a null scope.
      final TomPrincipal principal = authenticator.authenticate(bearerToken);
      return (
        identity: identityResolver.resolveBearerPrincipal(
          principal,
          channel: channel.wireName,
        ),
        scope: null,
        profile: _resolveProfile(null),
      );
    }
    final ApiKeyMarkers markers = parseApiKeyMarkers(bearerToken);
    final ResolvedIdentity identity = identityResolver.resolveBearer(
      markers.effectiveResidualKey,
      channel: channel.wireName,
    );
    // Resolve the profile FIRST (plan step 5): its cross-axis defaults feed the
    // no-marker fallback in scope resolution, and an unknown profile fails here
    // (before scope is built) as a `400`/`profile.unknown` (SCP-18).
    final ResolvedProfile profile = _resolveProfile(markers.profileSelector);
    final ApiKeyConfig? keyConfig = apiKeysByKey[markers.effectiveResidualKey];
    // A configured key resolves the markers under its own prefixes; an
    // unconfigured token (no `apiKeys[]` entry) resolves under the built-in
    // default prefixes (MSPP-62) — so every authenticated API-key token runs
    // under some profile rather than bare-root (§ 8.1). The resolved profile's
    // `defaultSession` / `defaultMemory` are the no-marker fallback, applied
    // through the per-tenant prefix so a default cannot escape the namespace
    // (explicit marker still wins — SC-1 / SC-Q14).
    return (
      identity: identity,
      scope: keyConfig?.resolveScope(
            markers,
            defaultSession: profile.defaultSession,
            defaultMemory: profile.defaultMemory,
          ) ??
          resolveDefaultScope(
            markers,
            defaultSession: profile.defaultSession,
            defaultMemory: profile.defaultMemory,
          ),
      profile: profile,
    );
  }

  /// Resolves a `profile-<name>` selector to its [ResolvedProfile] through the
  /// injected [profileResolver] seam (SCP-18).
  ///
  /// No resolver wired (profiles off) → the SC-5 byte-compatible
  /// `ResolvedProfile.cognitiveDefault()`, so `Access.profile` is unchanged from
  /// today. An unknown profile surfaces as [ProfileResolutionException] (thrown
  /// by the wired resolver), which the public methods' catch maps to an
  /// `AccessFailed` and the channel edge maps to `400` / `profile.unknown`.
  ResolvedProfile _resolveProfile(String? profileSelector) {
    final ProfileResolver? resolver = profileResolver;
    if (resolver == null) {
      return const ResolvedProfile.cognitiveDefault();
    }
    return resolver(profileSelector);
  }

  /// Resolves a processing-profile [selector] to its [ResolvedProfile] (§ 6).
  ///
  /// The public face of [_resolveProfile]: the Telegram edge owns profile
  /// selection on the user's behalf (there is no credential marker to carry it),
  /// so it resolves the active profile *name* through the
  /// `TelegramSessionRegistry`, then calls this to obtain the `ResolvedProfile`
  /// whose advisory `defaultSession` / `defaultMemory` seed the session / memory
  /// resolution before [admitTelegram] stamps the result. An unknown profile
  /// surfaces as [ProfileResolutionException] (SC-6).
  ResolvedProfile resolveProfile(String? selector) => _resolveProfile(selector);

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
  ///
  /// [memoryProfile], when supplied, is the chat's active memory profile id
  /// resolved by the `TelegramSessionRegistry` from the user's `/switch_memory`
  /// selection (the chat's `memoryPrefix` already applied, § 9.2). Telegram
  /// owns memory selection *on the user's behalf* (there is no credential scope
  /// to carry it), so it is stamped directly onto the `Access` — authoritative
  /// over Extension H's content-driven selection (MSP-5). `null` keeps the
  /// resolve-then-select-profile flow (MSPP-35).
  ///
  /// [profile], when supplied, is the chat's active processing profile already
  /// resolved by the edge via [resolveProfile] from the user's `/switch_profile`
  /// selection (§ 6). Telegram owns profile selection on the user's behalf (no
  /// credential marker carries it), so the edge resolves it once — its advisory
  /// `defaultSession` / `defaultMemory` having already seeded session / memory —
  /// and passes it straight through here. `null` runs the default profile.
  Future<void> admitTelegram({
    required String userId,
    required InboundRequest envelope,
    required TelegramSink sink,
    String? memoryProfile,
    ResolvedProfile? profile,
    Future<void> Function()? onAdmitted,
  }) async {
    String? principalId;
    try {
      final ResolvedIdentity identity =
          identityResolver.resolveTelegramUser(userId);
      principalId = identity.principalId;
      final Persona persona = personaResolver.resolve(null);
      // The edge resolves the active profile (`/switch_profile`, § 6) and passes
      // it in; absent it (isolated callers) the default profile applies.
      final ResolvedProfile resolvedProfile = profile ?? _resolveProfile(null);
      await _admit(
        channel: AccessChannel.telegram,
        identity: identity,
        envelope: envelope,
        persona: persona,
        profile: resolvedProfile,
        memoryProfile: memoryProfile,
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
      final ({
        ResolvedIdentity identity,
        ResolvedProfileScope? scope,
        ResolvedProfile profile,
      }) auth = _authenticateBearerScoped(bearerToken, channel);
      final ResolvedIdentity identity = auth.identity;
      principalId = identity.principalId;
      final Persona persona = personaResolver.resolve(modelId);
      await _admit(
        channel: channel,
        identity: identity,
        envelope: envelope,
        persona: persona,
        profile: auth.profile,
        scope: auth.scope,
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
  ///
  /// [scope] is the optional profile scope an API key's embedded markers
  /// selected ([_authenticateBearerScoped], MSP-4). When present it is
  /// *authoritative* over content-driven selection: the session resolves under
  /// the scope's prefixed id ([SessionManager.resolve]'s `overrideSessionId`)
  /// and the memory profile is stamped directly from `scope.memoryProfile`,
  /// bypassing Extension H's [SessionManager.selectMemoryProfile] (MSP-5 — the
  /// credential already named the profile; nothing past the edge re-derives it).
  /// `null` (the JWT path, the no-scope key, every non-bearer channel) keeps the
  /// existing resolve-then-select-profile flow.
  ///
  /// [memoryProfile] is the Telegram channel's already-resolved active memory
  /// profile id (the chat's `memoryPrefix` applied, § 9.2). Like a credential
  /// [scope] it is authoritative over content-driven selection — Telegram named
  /// the profile via `/switch_memory`, so nothing past the edge re-derives it
  /// (MSP-5 / MSPP-35). A credential [scope], when present, still wins (only the
  /// bearer channels carry a scope, and they never pass a [memoryProfile], so
  /// the two never collide). `null` keeps the resolve-then-select flow.
  Future<void> _admit({
    required AccessChannel channel,
    required ResolvedIdentity identity,
    required InboundRequest envelope,
    required Persona persona,
    required ResolvedProfile profile,
    required _BuildBinding buildBinding,
    ResolvedProfileScope? scope,
    String? memoryProfile,
    Future<void> Function()? onAdmitted,
  }) async {
    final String principalId = identity.principalId;

    // ── Remaining edge gates (auth + identity already ran in the caller). The
    //    profile rate-limit composes with the global one: a request must clear
    //    both, so the tighter (principal, profileId) bound governs (SC-8 /
    //    SCP-19). A no-op for the default profile (no per-minute limit). ──
    rateLimiter.check(principalId);
    profileRateLimiter.check(principalId, profile);
    quotaLimiter.check(principalId);
    anchorPreCheck.check(envelope.text);

    // ── Persona: the profile's pinned substrate role wins over the model-id
    //    persona (spec § 3.3); the persona id (the answered-as model echo) is
    //    preserved so only the substrate role changes. A null `profile.role`
    //    (the default profile) leaves the model-id persona untouched. ──
    final Persona effectivePersona = profile.role == null
        ? persona
        : Persona(
            personaId: persona.personaId,
            substrateRole: profile.role!,
          );

    // ── Turn id: the request has now cleared every edge gate, so it is
    //    admitted. Mint the turn correlation id here — the single instant
    //    §3 names — and ride it onto the `Access`. It threads from here through
    //    the dispatcher and engine onto every substrate call this turn issues,
    //    so `turnId` + `callSeq` uniquely name any LLM call of the turn. ──
    final TurnId turnId = TurnId.generate();

    // ── Session: resolve the conversation and record this turn against its
    //    histories (the request is now fully admitted, so it legitimately gets
    //    a turn). The resolution carries the history the engine answers from.
    //    A profile [scope] overrides the conversation id with its prefixed
    //    session id (MSP-4) — the credential's `session-` marker, not the
    //    request envelope, names the session. ──
    final SessionResolution session = sessionManager.resolve(
      identity: identity,
      channel: channel,
      envelope: envelope,
      overrideSessionId: scope?.sessionId,
    );

    // ── Memory-profile selection. With a credential [scope] the memory profile
    //    is already named (MSP-5): stamp the scope's prefixed profile directly
    //    and bypass Extension H — nothing past the edge re-derives a profile the
    //    credential chose. Without a scope, run the content-driven selection
    //    (access spec § 7.4): disabled / unwired → the process default; a
    //    selector outage degrades gracefully (PE-6), it is not a failure. ──
    final Session stampedSession;
    if (scope != null) {
      stampedSession = session.session.withMemoryProfile(scope.memoryProfile);
    } else if (memoryProfile != null) {
      // Telegram resolved the active memory on the user's behalf (§ 9.2); it is
      // authoritative just like a credential scope (MSP-5 / MSPP-35).
      stampedSession = session.session.withMemoryProfile(memoryProfile);
    } else {
      final MemoryProfileSelectionOutcome profileOutcome =
          await sessionManager.selectMemoryProfile(
        resolution: session,
        envelope: envelope,
      );
      stampedSession =
          session.session.withMemoryProfile(profileOutcome.profile);
    }

    // ── Classify (graceful, AC-9): attach a confident kind-hint or leave the
    //    envelope untouched; a classifier outage is not a failure. ──
    final InboundRequest effectiveEnvelope = await _classify(envelope);

    // ── Delivery: bind the channel wire to the per-`Access` deliver callback. ──
    final DeliveryBinding binding = buildBinding(identity, effectiveEnvelope);
    final DeliverCallback deliver = deliveryRegistry.deliverFor(binding);

    // ── Build the one canonical Access and announce it before dispatch. The
    //    resolved profile rides onto `Access.profile` (the dispatcher/engine
    //    read it for entry-procedure, role, overlay, MCP, budget — steps 6/8);
    //    the marker itself never reaches the dispatcher (SC-4). ──
    final Access access = Access(
      envelope: effectiveEnvelope,
      identity: identity,
      session: stampedSession,
      persona: effectivePersona,
      deliver: deliver,
      history: session.history,
      turnId: turnId,
      profile: profile,
    );
    eventBus.emit(
      AccessCreated.fromAccess(access, occurredAt: _clock().toUtc()),
    );

    // §5.3 incoming-prompt trail (§10 step #7): capture the content-bearing
    // record at the dispatch boundary. This is the one place channel + turnId +
    // the full envelope + the resolved identity / session / persona are all in
    // scope, and it runs *before* dispatch (the §5.3 seam). Best-effort (§9): a
    // trail-write failure must never fail an otherwise-admitted turn.
    _trailIncoming(
      channel: channel,
      turnId: turnId,
      identity: identity,
      session: stampedSession,
      persona: effectivePersona,
      profile: profile,
      envelope: effectiveEnvelope,
    );

    // The request is fully admitted and about to be dispatched: fire the
    // post-admission hook (the Telegram edge's immediate "Processing" ack)
    // before the run streams, so a gate-rejected request never reaches here and
    // the ack always precedes the answer.
    if (onAdmitted != null) {
      await onAdmitted();
    }

    await dispatcher.accept(access);

    // The run has streamed and the engine has back-filled its answer into the
    // session's *answered-from* history (the same ConversationHistory the
    // SessionManager holds). For a known dedicated session that is the
    // per-session history; the per-(principal, channel) global history recorded
    // the same turn with an empty answer, so mirror the answer across before
    // persisting — otherwise the durable "all prompts" record loses every reply
    // (umbrella Hard principle 6; access spec § 7.2).
    sessionManager.backfillGlobalAnswer(
      identity: identity,
      channel: channel,
      resolution: session,
    );

    // Persist both history stores now so the exchange survives a process
    // restart — the "nothing is ever lost" contract (umbrella Hard principle 6;
    // access spec § 21.10). Best-effort: a persistence failure must never fail
    // an otherwise-completed turn (it is a no-op when no durable HistoryStore is
    // wired).
    _persistHistories();
  }

  /// Writes the live conversation histories to the SessionManager's durable
  /// store, swallowing any failure (§9 best-effort, mirroring the trail sinks).
  void _persistHistories() {
    try {
      sessionManager.persist();
    } catch (_) {
      // A history-persistence miss is never an access failure — the answer was
      // already delivered. The next persisted turn re-captures the full
      // snapshot (persist writes the whole document, not a delta).
    }
  }

  /// Hands the configured [incomingTrailSink] one [IncomingTrailRecord] for the
  /// admitted request (the §5.3 incoming-prompt trail, §10 step #7).
  ///
  /// No-op when no sink is wired (unconfigured mode). Best-effort (§9): any
  /// failure building or writing the record is swallowed so the admitted turn
  /// dispatches regardless — a trail miss is never an access failure.
  void _trailIncoming({
    required AccessChannel channel,
    required TurnId turnId,
    required ResolvedIdentity identity,
    required Session session,
    required Persona persona,
    required ResolvedProfile profile,
    required InboundRequest envelope,
  }) {
    final IncomingTrailSink? sink = incomingTrailSink;
    if (sink == null) {
      return;
    }
    try {
      sink(
        IncomingTrailRecord.fromAdmission(
          channel: channel,
          turnId: turnId,
          receivedAt: _clock().toUtc(),
          identity: identity,
          session: session,
          persona: persona,
          profile: profile,
          envelope: envelope,
        ),
      );
    } catch (_) {
      // §9: the incoming trail is non-essential; never surface its failure.
    }
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
    if (error is ApiKeyMarkerException) {
      return 'access.auth.markers.invalid';
    }
    if (error is ProfileResolutionException) {
      return 'access.profile.unknown';
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
