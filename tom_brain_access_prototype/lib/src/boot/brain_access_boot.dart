// BrainAccessBoot — composes the inbound access layer over a booted
// dispatcher (E.41; proto spec § 11 / § 12; AC-2 / AC-3 / AC-4).
//
// Where this sits relative to `BrainProcessBoot` (D.44):
//
//   The proto spec § 12 bring-up sequence brings up *substrate → memory →
//   engine + dispatcher → access layer*. The first three are owned by
//   `tom_brain_procedure_prototype`'s `BrainProcessBoot`; the access prototype
//   must not depend on `tom_brain_memory` / `tom_brain_substrate` (pubspec
//   § "Explicitly NOT here"), so it cannot compose substrate / memory / engine
//   directly. Instead it composes the *access surface over the booted
//   dispatcher*, plugging into the one seam `BrainProcessBoot` exposes for
//   exactly this — the `AccessLayerInstaller`
//   (`Future<AccessLayerShutdown> Function(Dispatcher)`).
//
//   So [BrainAccessBoot.installer] returns an `AccessLayerInstaller` a caller
//   hands to `BrainProcessConfig.installAccessLayer`; `BrainProcessBoot.boot`
//   then calls it with the dispatcher it just built, and the access layer comes
//   up as bring-up phase 4. Substrate (the embedding source) and memory (the
//   procedure-centroid classifier) reach the classifier only through the two
//   injected function seams on [BrainAccessConfig] — the same anti-dependency
//   discipline E.16 (`EmbeddingSource`) and E.33 (`KindHintEmbedder` /
//   `KindHintClassifier`) adopted. This decision (compose-over-dispatcher
//   rather than compose-substrate-directly, against the literal reading of
//   spec § 11.1 / § 12) is logged in the questions doc.
//
// What this file owns:
//
//   * `BrainAccessConfig` — the access-layer composition inputs: the identity
//     bindings, the persona vocabulary, the three edge-security policies, the
//     optional bearer authenticator, and the optional classifier seams.
//   * `BootedAccessLayer` — the assembled, running access surface: the
//     [AccessAssembler] the channel edges (E.45) drive, the [AccessEventBus]
//     observers subscribe to, and a `shutdown` that closes the bus.
//   * `BrainAccessBoot` — the stateless composer: [install] assembles the
//     surface over a dispatcher; [installer] adapts it to the
//     `AccessLayerInstaller` seam.
//
// Edge wiring (the order the components run is the assembler's, E.41): this
// file only *constructs* the components and registers the two delivery paths.
// It wires the registry's `onDelivered` sink to the event bus's `emit`, so the
// terminal `AccessDelivered` lands on the same bus as `AccessCreated` /
// `AccessFailed`. The classifier is built only when *both* seams are supplied
// (an embedder with no classifier, or vice-versa, cannot classify); when it is
// built the embed seam is wrapped in the E.34 `EmbeddingCache` first.
//
// What this file does NOT do:
//
//   * No socket binding / serve loop, and no Telegram inbound-stream driving —
//     those (the live edges that *call* the assembler) are E.45. E.41 composes
//     the admission core; E.45 drives it. Both deferrals are logged in the
//     questions doc.
//   * No substrate / memory construction (that is `BrainProcessBoot`'s job, and
//     it is reached only through the dispatcher + the injected seams).

import 'package:tom_core_agentic/tom_core_agentic.dart' show systemClock;
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart'
    show AccessLayerInstaller, AccessLayerShutdown, Dispatcher;

import '../delivery/chunk_stream_delivery.dart';
import '../delivery/delivery_registry.dart';
import '../delivery/sse_delivery.dart';
import '../delivery/telegram_delivery.dart';
import '../edge_security/edge_security.dart';
import '../heuristic_classifier/embedding_cache.dart';
import '../heuristic_classifier/heuristic_kind_hint_classifier.dart';
import '../identity/identity_resolver.dart';
import '../identity/persona_resolver.dart';
import '../identity/session_manager.dart';
import 'access_assembler.dart';
import 'access_event_bus.dart';

/// The composition inputs for the access layer (proto spec § 11.4).
///
/// Boot loads these from `AccessConfig` (the on-disk configuration); a test
/// constructs them directly. Every field is configuration the access surface
/// needs to admit a request — except the two classifier seams, which are the
/// substrate / memory edges the access layer reaches only through functions
/// (it depends on neither package).
final class BrainAccessConfig {
  /// OpenAI bearer token → identity binding (E.24). One entry per accepted
  /// shared secret; the resolved `principalId` is the binding's non-secret id,
  /// never the token.
  final Map<String, IdentityBinding> bearerTokenBindings;

  /// Telegram user id → identity binding (E.24). One entry per whitelisted
  /// sender; the same person's OpenAI + Telegram bindings may map to one
  /// `principalId`.
  final Map<String, IdentityBinding> telegramUserIdBindings;

  /// The persona-as-model vocabulary (E.26), or `null` for the shared default
  /// (`OpenAiPersonaMapping.knownModels`).
  final List<String>? personaVocabulary;

  /// Short-horizon burst-throttle policy (E.29).
  final RateLimitPolicy rateLimitPolicy;

  /// Long-horizon daily-cap policy (E.30).
  final DailyQuotaPolicy dailyQuotaPolicy;

  /// Content-screen signature policy (E.31). An empty policy admits every
  /// prompt (the screen is disabled).
  final AnchorPolicy anchorPolicy;

  /// The optional bearer authenticator (E.28). `null` leaves bearer validation
  /// to the identity registry (an unbound token still fails resolution).
  final BearerTokenAuthenticator? bearerAuthenticator;

  /// The embedding seam (E.33 / E.16): substrate's embed call, as a function.
  /// `null` (with or without [kindHintClassifier]) disables classification —
  /// the dispatcher then classifies every request.
  final KindHintEmbedder? kindHintEmbedder;

  /// The classify seam (E.33): memory's `classify(embedding,
  /// ClassificationTarget.procedure)`, as a function. `null` disables
  /// classification.
  final KindHintClassifier? kindHintClassifier;

  /// The embedding-cache TTL (E.34). Defaults to the cache's own 5-minute
  /// default; only consulted when the classifier is built.
  final Duration embeddingCacheTtl;

  /// Clock for the session turns, the edge-security limiters, the embedding
  /// cache, and the emitted lifecycle events. Defaults to [DateTime.now];
  /// tests inject a fixed clock.
  final DateTime Function() clock;

  /// Durable backing for the rate limiter's per-principal buckets (E.29 /
  /// P1.4), or `null` to keep them in process only. The process boot (E.45)
  /// supplies a [JsonFileEdgeStateStore] when `access.edgeState.directory` is
  /// configured; tests inject a [MapEdgeStateStore].
  final EdgeStateStore? rateLimitStore;

  /// Durable backing for the daily quota's per-principal counters (E.30 /
  /// P1.4), or `null` to keep them in process only. Kept separate from
  /// [rateLimitStore] so each limiter owns its own file / row format.
  final EdgeStateStore? quotaStore;

  /// Builds an access-layer composition config.
  BrainAccessConfig({
    required this.rateLimitPolicy,
    required this.dailyQuotaPolicy,
    required this.anchorPolicy,
    this.bearerTokenBindings = const {},
    this.telegramUserIdBindings = const {},
    this.personaVocabulary,
    this.bearerAuthenticator,
    this.kindHintEmbedder,
    this.kindHintClassifier,
    this.embeddingCacheTtl = const Duration(minutes: 5),
    DateTime Function()? clock,
    this.rateLimitStore,
    this.quotaStore,
  }) : clock = clock ?? systemClock;
}

/// A composed, running access layer plus its teardown.
///
/// Returned by [BrainAccessBoot.install]. The channel edges (E.45) drive
/// [assembler]; observers (a Forge inspector, a test) subscribe to
/// [eventBus]`.events()`. The caller owns the lifetime — call [shutdown] once
/// when the access layer winds down (it is the `AccessLayerShutdown`
/// `BrainProcessBoot` invokes before tearing the dispatcher down).
final class BootedAccessLayer {
  /// The per-request admission pipeline the channel edges drive.
  final AccessAssembler assembler;

  /// The access edge's lifecycle event bus.
  final AccessEventBus eventBus;

  bool _shutDown = false;

  BootedAccessLayer._({
    required this.assembler,
    required this.eventBus,
  });

  /// Tears the access layer down: closes the event bus so observers see a
  /// done-stream and a late `emit` throws. Idempotent — safe in a `finally`
  /// and safe to use as the `AccessLayerShutdown` callback.
  Future<void> shutdown() async {
    if (_shutDown) return;
    _shutDown = true;
    await eventBus.close();
  }
}

/// Composes the inbound access layer over a booted [Dispatcher] (E.41).
///
/// Stateless: [install] and [installer] are the whole surface. It is an
/// `abstract final class` (a named namespace, no instances) so the composition
/// has a named home the spec section maps onto, mirroring `BrainProcessBoot`.
abstract final class BrainAccessBoot {
  /// Assembles the access surface over [dispatcher] from [config] and returns
  /// the running [BootedAccessLayer].
  ///
  /// Constructs the event bus, the delivery registry (its `onDelivered` sink
  /// wired to the bus, all four delivery paths registered — SSE, Telegram, and
  /// the Ollama / Anthropic chunk-stream paths), the three resolvers,
  /// the three edge-security limiters, the optional bearer authenticator, and
  /// the optional classifier (built only when both seams are supplied, with the
  /// embed seam wrapped in the E.34 cache), then wires them into one
  /// [AccessAssembler].
  static BootedAccessLayer install({
    required Dispatcher dispatcher,
    required BrainAccessConfig config,
  }) {
    final AccessEventBus eventBus = AccessEventBus();

    final DeliveryRegistry deliveryRegistry = DeliveryRegistry(
      onDelivered: eventBus.emit,
      clock: config.clock,
    )
      ..register(const SseChannelDelivery())
      ..register(const TelegramChannelDelivery())
      ..register(const ChunkStreamChannelDelivery(AccessChannel.ollama))
      ..register(const ChunkStreamChannelDelivery(AccessChannel.anthropic));

    final AccessAssembler assembler = AccessAssembler(
      dispatcher: dispatcher,
      identityResolver: IdentityResolver(
        bearerTokenBindings: config.bearerTokenBindings,
        telegramUserIdBindings: config.telegramUserIdBindings,
      ),
      sessionManager: SessionManager(now: config.clock),
      personaResolver: PersonaResolver(knownModels: config.personaVocabulary),
      rateLimiter: RateLimiter(
        policy: config.rateLimitPolicy,
        clock: config.clock,
        store: config.rateLimitStore,
      ),
      quotaLimiter: DailyQuotaLimiter(
        policy: config.dailyQuotaPolicy,
        clock: config.clock,
        store: config.quotaStore,
      ),
      anchorPreCheck: AnchorPreCheck(config.anchorPolicy),
      deliveryRegistry: deliveryRegistry,
      eventBus: eventBus,
      bearerAuthenticator: config.bearerAuthenticator,
      classifier: _buildClassifier(config),
      clock: config.clock,
    );

    return BootedAccessLayer._(assembler: assembler, eventBus: eventBus);
  }

  /// Adapts [install] to the `BrainProcessBoot` [AccessLayerInstaller] seam.
  ///
  /// Returns a closure a caller hands to `BrainProcessConfig.installAccessLayer`;
  /// `BrainProcessBoot.boot` calls it with the dispatcher it just built (bring-up
  /// phase 4) and stores the returned [AccessLayerShutdown] (the
  /// [BootedAccessLayer.shutdown] tear-off) to invoke before tearing the
  /// dispatcher down.
  ///
  /// The assembled [BootedAccessLayer] is not surfaced through this seam (the
  /// seam returns only the shutdown) — driving the assembler from a live socket
  /// / Telegram stream is E.45, which composes through [install] directly to
  /// hold the surface. The installer is the production wiring path; [install]
  /// is the testable / E.45 path.
  static AccessLayerInstaller installer(BrainAccessConfig config) {
    return (Dispatcher dispatcher) async {
      final BootedAccessLayer booted =
          install(dispatcher: dispatcher, config: config);
      return booted.shutdown;
    };
  }

  /// Builds the cheap kind-hint classifier from the config seams, or `null`
  /// when classification is disabled.
  ///
  /// Both seams are required: an embedder with no classifier (or vice-versa)
  /// cannot produce a hint, so the classifier is left `null` and the dispatcher
  /// classifies every request. When both are present the embed seam is wrapped
  /// in the E.34 [EmbeddingCache] first (so a repeated prompt skips the embed
  /// call), then handed to the [HeuristicKindHintClassifier].
  static HeuristicKindHintClassifier? _buildClassifier(
    BrainAccessConfig config,
  ) {
    final KindHintEmbedder? embedder = config.kindHintEmbedder;
    final KindHintClassifier? classifier = config.kindHintClassifier;
    if (embedder == null || classifier == null) {
      return null;
    }
    final EmbeddingCache cache = EmbeddingCache(
      embedder: embedder,
      ttl: config.embeddingCacheTtl,
      clock: config.clock,
    );
    return HeuristicKindHintClassifier(
      embedder: cache.embed,
      classifier: classifier,
    );
  }
}
