// B.36 — `SubstrateConfig`: typed root of the substrate's YAML config.
//
// Plan step (verbatim):
//   "B.36 Implement `SubstrateConfig` YAML loader with the provider
//    routing policy + role registry + embedding choice."
//
// substrate_specification.md § 9 frames the YAML shape:
//
// ```yaml
// substrate:
//   providers: [ ... ]
//   roleRoutes: { roleId: [{ providerId, model }, ...], ... }
//   embedding: { providerId, model, dims, normalize }
//   router:    { retriesPerClass, overloadedBackoffMs, cooldownsSeconds: { class: secs } }
//   webSearch: { defaultProvider, providers: { name: { kind, auth? } } }
//   webFetch:  { defaultBudgetBytes, userAgent }
//   mcpClient: { endpoints: { id: { transport, ... } } }
//   priceTable: { 'providerId/modelId': { inputPerMTokens, outputPerMTokens } }
// ```
//
// B.36 lays down the **typed model** here and the **YAML parser** in
// the sibling `substrate_config_loader.dart`. The B.40 in-process
// facade (`InProcessTomBrainSubstrate`) is the eventual consumer; it
// reads each section to construct the runtime objects (`LlmRouter`
// from `providers` + `roleRoutes`, `OllamaEmbeddingService` from
// `embedding`, `DefaultWebSearch` from `webSearch`, etc.).
//
// Why a typed model rather than handing the raw YAML around:
//
//   * **One schema, one validation surface.** The loader is the only
//     place that knows the YAML key names; the facade reads typed
//     fields with autocomplete and compile-time checks.
//   * **Cross-section invariants get a place to live.** "Every
//     `roleRoutes` entry references a known `providers.id`",
//     "`embedding.providerId` exists in `providers`",
//     "`webSearch.defaultProvider` is a registered web-search provider"
//     — all cross-references are validated once at load time so the
//     facade can stay simple.
//   * **The data is reusable.** Test fixtures construct
//     `SubstrateConfig` values directly without round-tripping
//     through YAML; the loader's failure modes are exercised in
//     isolation from the facade's wiring.
//
// What this file deliberately does NOT do:
//
//   * It does not resolve secret references. Like the B.34
//     `McpAuthResolver`, secret-file reading is deferred to runtime
//     (the facade has a per-call freedom to refresh tokens; baking the
//     resolved value into the config would freeze it for the process
//     lifetime). The typed model carries the *reference* shape
//     (`secretRef: '_ai/secrets/...'`); the resolver runs at facade
//     boot.
//   * It does not construct any runtime object. `buildRouterPolicy()`,
//     for example, returns a `RouterPolicy` value — the actual
//     `LlmRouter` and provider instances are constructed at B.40.
//   * It does not bind to the `RoleRegistry`. The six core
//     roles are bootstrapped in `bootstrap_roles.dart` (deferred
//     file-backed loading per Q-B.22.1/.2/.3); SubstrateConfig only
//     provides the cross-validation hook (`validateRoleRegistry`)
//     that asserts every `roleRoutes` key has a registered template
//     (Q-B.22.4).
//
// Folder location decision (Q-B.9.5).
//   Memory's precedent puts the typed config + loader in
//   `lib/src/config/`. The substrate B.9 stub of `SubstrateConfig`
//   lived in `lib/src/api/` (because the consumer-facing
//   `TomBrainSubstrateClient.open(SubstrateConfig)` was the first
//   reference) with an explicit "Q-B.9.5: should we mirror memory's
//   pattern?". B.36 takes the mirror-memory path: the typed model
//   moves to `lib/src/config/`, the api/ barrel re-exports from
//   there, and consumers using `package:tom_brain_substrate/
//   tom_brain_substrate.dart` see no change.

import 'package:tom_llm/tom_llm.dart' show LlmProvider;
import '../mcp_client/mcp_auth.dart' show McpAuthConfig;
import '../roles/role_registry.dart' show RoleRegistry, RoleTemplateNotFound;
import '../router/llm_failure_classifier.dart' show LlmFailureClass;
import '../router/route_entry.dart' show RouteEntry, RouteConditions;
import '../router/router_policy.dart' show RouterPolicy;

/// Provider kind discriminator. Mirrors the substrate's concrete
/// `LlmProvider` implementations (B.14 / B.15 / B.16 / plan-2 item 10).
///
/// A `kind` other than these is a config-load error — the loader has no
/// constructor to dispatch to.
enum ProviderKind {
  /// `OllamaLlmProvider` against a local Ollama daemon.
  ollama,

  /// `OpenAiPassthroughProvider` against any OpenAI-format vendor.
  openai,

  /// `AnthropicLlmProvider` against the Anthropic Messages API.
  anthropic,

  /// `AgentSdkLlmProvider` (run layer) — drives the Anthropic Agent SDK
  /// through the VS Code Scripting API bridge. Control-inverted: Claude
  /// Code owns the tool / MCP / memory loop; the provider sees a single
  /// black-box completion. Construction lives in `tom_brain_run`
  /// (`brain_substrate_builder.dart`) because it depends on
  /// `tom_vscode_scripting_api` + a live bridge. Its bridge host/port,
  /// session mode, and MCP allow-list ride in [ProviderProfile.options]
  /// rather than [ProviderProfile.baseUrl] / `auth` (the bridge owns the
  /// Anthropic credential).
  agentSdk,

  /// `StubLlmProvider` — test-only, no transport.
  stub,
}

/// Provider-side auth configuration. Two cases per spec § 9:
///
///   * `none` — no credential (Ollama default, stub default).
///   * `api_key` — bearer / API-key auth, supplied inline or
///     resolved from a secret file at facade-construction time.
///
/// Sealed so the facade's switch over cases stays exhaustive.
sealed class ProviderAuthConfig {
  const ProviderAuthConfig._();

  /// No authentication.
  static const ProviderAuthConfig none = _ProviderAuthNone._();

  /// API-key authentication. Exactly one of [token] or [secretRef]
  /// must be supplied; the loader's parser enforces the constraint
  /// at YAML parse time.
  ///
  /// [token] — inline credential. Convenient for tests, bootstrap,
  /// and self-hosted deployments where the secret lives in env vars.
  ///
  /// [secretRef] — workspace-relative or absolute file path holding
  /// the raw token. Read once at facade boot (mirrors the B.34
  /// `McpAuthResolver` posture); the file's contents are trimmed of
  /// surrounding whitespace before use.
  factory ProviderAuthConfig.apiKey({String? token, String? secretRef}) {
    final hasInline = token != null;
    final hasRef = secretRef != null;
    if (hasInline == hasRef) {
      throw ArgumentError(
        'ProviderAuthConfig.apiKey requires exactly one of `token` or '
        '`secretRef`; got '
        '${hasInline && hasRef ? "both" : "neither"}.',
      );
    }
    if (hasInline && token.isEmpty) {
      throw ArgumentError('ProviderAuthConfig.apiKey.token must be non-empty.');
    }
    if (hasRef && secretRef.isEmpty) {
      throw ArgumentError(
        'ProviderAuthConfig.apiKey.secretRef must be non-empty.',
      );
    }
    return _ProviderAuthApiKey._(token: token, secretRef: secretRef);
  }
}

final class _ProviderAuthNone extends ProviderAuthConfig {
  const _ProviderAuthNone._() : super._();

  @override
  String toString() => 'ProviderAuthConfig.none';
}

final class _ProviderAuthApiKey extends ProviderAuthConfig {
  /// Inline API key. Mutually exclusive with [secretRef].
  final String? token;

  /// File path holding the raw API key. Mutually exclusive with
  /// [token].
  final String? secretRef;

  const _ProviderAuthApiKey._({this.token, this.secretRef}) : super._();

  @override
  String toString() {
    if (token != null) return 'ProviderAuthConfig.apiKey(inline)';
    return 'ProviderAuthConfig.apiKey(secretRef: $secretRef)';
  }
}

/// Pattern-matching helpers for [ProviderAuthConfig].
///
/// Exposed because the sealed subtypes are private; consumers reach
/// the inline-vs-secretRef shape through these helpers rather than
/// through `is _ProviderAuthApiKey` (which would be impossible
/// outside the library) or through a `switch` over private types
/// (which would not compile).
extension ProviderAuthConfigCases on ProviderAuthConfig {
  /// True when this config is `ProviderAuthConfig.none`.
  bool get isNone => this is _ProviderAuthNone;

  /// True when this config is `ProviderAuthConfig.apiKey(...)`.
  bool get isApiKey => this is _ProviderAuthApiKey;

  /// Inline token when [isApiKey] and the credential was declared
  /// inline; `null` otherwise.
  String? get apiKeyInlineToken {
    final self = this;
    return self is _ProviderAuthApiKey ? self.token : null;
  }

  /// Secret-file reference when [isApiKey] and the credential was
  /// declared via a `secretRef`; `null` otherwise.
  String? get apiKeySecretRef {
    final self = this;
    return self is _ProviderAuthApiKey ? self.secretRef : null;
  }
}

/// One row of `substrate.providers` (spec § 9).
///
/// The facade (B.40) reads this list and constructs one concrete
/// [LlmProvider] per row, keyed by [id]. The router (B.18+) is then
/// handed a `Map<String, LlmProvider>` keyed by id; `roleRoutes`
/// entries reference these ids.
final class ProviderProfile {
  /// Stable identifier referenced by `roleRoutes[*].providerId`.
  /// Must be non-empty and unique across the providers list.
  final String id;

  /// Discriminator that picks the concrete `LlmProvider`
  /// implementation at facade boot.
  final ProviderKind kind;

  /// Base URL for the provider's HTTP endpoint. `null` for
  /// [ProviderKind.stub] (no transport).
  final Uri? baseUrl;

  /// Auth profile. `none` for Ollama and stub; `apiKey` for
  /// OpenAI-format vendors.
  final ProviderAuthConfig auth;

  /// Models advertised by this provider. The router validates that
  /// every `roleRoutes[*]` entry referencing this provider names a
  /// model from this list (cross-validation at load time, not at
  /// dispatch time).
  ///
  /// An empty list is rejected by the loader — a provider with no
  /// declared models has no useful routing target.
  final List<String> models;

  /// Provider-specific opaque settings, parsed by the loader as a
  /// passthrough of an optional `options:` sub-map and interpreted only
  /// by the concrete provider builder for kinds that need extra
  /// configuration.
  ///
  /// Generic providers (ollama / openai / anthropic / stub) ignore it.
  /// [ProviderKind.agentSdk] reads `bridgeHost` / `bridgePort` /
  /// `sessionMode` / `permissionMode` / `maxTurns` / `mcpServers` and the
  /// quest-mode `questId` / `sessionKey` / `questHistoryRoot` from here
  /// (see the agent-SDK design spec § 1.3). Keeping it a generic bag
  /// avoids leaking run-layer provider specifics into this substrate-level
  /// config type.
  ///
  /// Defaults to the empty map; values are whatever the YAML carried
  /// (strings / nums / bools / lists / maps), validated by the consuming
  /// builder, not here.
  final Map<String, Object?> options;

  const ProviderProfile({
    required this.id,
    required this.kind,
    required this.auth,
    required this.models,
    this.baseUrl,
    this.options = const <String, Object?>{},
  });
}

/// One row of `substrate.roleRoutes[roleId]` (spec § 9).
///
/// Mirrors `RouteEntry` shape but at the *config* layer (the runtime
/// `RouteEntry` lives in `lib/src/router/`). The loader converts
/// configs into runtime entries via [SubstrateConfig.buildRouterPolicy].
final class RoleRouteEntryConfig {
  /// References `ProviderProfile.id`. Cross-validated at load time.
  final String providerId;

  /// References a model from `ProviderProfile.models` of the named
  /// provider. Cross-validated at load time.
  final String model;

  /// Optional per-entry filter (spec § 5.1 `conditions?`). For the
  /// prototype only `maxInputTokens` is wired; later steps may grow
  /// the shape.
  final RouteConditionsConfig? conditions;

  const RoleRouteEntryConfig({
    required this.providerId,
    required this.model,
    this.conditions,
  });
}

/// YAML-side mirror of `RouteConditions`. Lives separately so the
/// loader's parser can validate the YAML shape before constructing
/// the runtime value.
final class RouteConditionsConfig {
  /// Skip this entry when the caller's prompt is estimated to
  /// exceed [maxInputTokens] input tokens. `null` ⇒ no upper bound.
  final int? maxInputTokens;

  const RouteConditionsConfig({this.maxInputTokens});
}

/// The `substrate.router` subtree — the router's failover tunables
/// (spec § 5.3 / § 5.4), exposed on the YAML schema so a deployment can
/// adjust cooldown windows, the in-route retry budget, and the
/// `overloaded` backoff without a code change (Q-B.36.2).
///
/// The defaults mirror [RouterPolicy.defaultRetriesPerClass],
/// [RouterPolicy.defaultOverloadedBackoff], and (when [cooldownByClass]
/// is `null`) [RouterPolicy.defaultCooldowns] — `RouterPolicy` remains
/// the single source of truth for the default values. Omitting the
/// `router:` block entirely produces [RouterTunables.defaults], so the
/// loaded policy is byte-for-byte the historical hard-coded behaviour.
///
/// [cooldownByClass] semantics: `null` means "the operator did not
/// configure a schedule — use [RouterPolicy.defaultCooldowns]". A
/// non-null map is the operator's **complete** schedule: a failure class
/// absent from the map gets zero cooldown (handled by retry), exactly
/// as [RouterPolicy] treats an absent key. The map never *patches* the
/// defaults — that would make "which cooldown applies" depend on a
/// hidden merge, which is the ambiguity the explicit-replace rule
/// avoids.
final class RouterTunables {
  /// Per-[LlmFailureClass] cooldown window, or `null` to defer to
  /// [RouterPolicy.defaultCooldowns]. When non-null this is the full
  /// schedule (absent classes ⇒ zero cooldown).
  final Map<LlmFailureClass, Duration>? cooldownByClass;

  /// In-route retry count for `retryThenRotate` failure classes.
  final int retriesPerClass;

  /// Base for the jittered backoff inserted before an `overloaded`
  /// retry.
  final Duration overloadedBackoff;

  /// Constructs router tunables. Validation (non-negativity) lives in
  /// the loader's parser and in [RouterPolicy]'s constructor; this
  /// value class trusts its caller (the loader is the only producer
  /// outside tests).
  const RouterTunables({
    this.cooldownByClass,
    this.retriesPerClass = RouterPolicy.defaultRetriesPerClass,
    this.overloadedBackoff = RouterPolicy.defaultOverloadedBackoff,
  });

  /// The all-defaults tunables — used when the `router:` block is
  /// omitted. Equivalent to constructing a [RouterPolicy] with no
  /// tunable arguments.
  static const RouterTunables defaults = RouterTunables();
}

/// The embedding choice — which provider + model the substrate uses
/// for `EmbeddingService.embed()` calls (spec § 9, § 7.2).
///
/// At facade boot (B.40), this is converted into an
/// `OllamaEmbeddingService` (the only concrete backend at B.36) or
/// a future second-backend impl. The `dims` value is the canonical
/// declared dimension — every backend vector that does not match
/// surfaces as `EmbeddingDimensionMismatch` at the first call.
final class EmbeddingChoice {
  /// References a `ProviderProfile.id`. Cross-validated at load
  /// time. The named provider must declare [model] in its `models`
  /// list.
  final String providerId;

  /// Embedding-model id within the provider (e.g.
  /// `nomic-embed-text` for Ollama, `text-embedding-3-small` for
  /// OpenAI).
  final String model;

  /// Declared vector dimension (e.g. 768 for `nomic-embed-text`,
  /// 1536 for `text-embedding-3-small`).
  final int dims;

  /// Whether the backend produces L2-normalised vectors. Memory
  /// uses the flag to decide between cosine and dot-product math
  /// without re-normalising.
  final bool normalize;

  const EmbeddingChoice({
    required this.providerId,
    required this.model,
    required this.dims,
    required this.normalize,
  });
}

/// Web-search subtree (spec § 9, § 8.1).
final class WebSearchConfig {
  /// Default provider id when `WebSearchOptions.provider` is null.
  /// Must be a key in [providers].
  final String defaultProvider;

  /// Provider catalogue. Each entry describes one concrete
  /// `WebSearchProvider` implementation the facade constructs at
  /// boot.
  final Map<String, WebSearchProviderConfig> providers;

  const WebSearchConfig({
    required this.defaultProvider,
    required this.providers,
  });
}

/// One row of `webSearch.providers` (spec § 9).
final class WebSearchProviderConfig {
  /// Discriminator picking the concrete `WebSearchProvider` impl.
  /// Known values for the prototype: `ddg_html`, `brave`. Other
  /// values are accepted at load time and surface as
  /// `UnknownWebSearchProvider` at facade boot (the loader does not
  /// own the registry of known kinds).
  final String kind;

  /// Auth profile. For most providers `none`; for Brave / paid
  /// providers `apiKey` with a secretRef.
  final ProviderAuthConfig auth;

  const WebSearchProviderConfig({
    required this.kind,
    this.auth = ProviderAuthConfig.none,
  });
}

/// Web-fetch subtree (spec § 9, § 8.2).
final class WebFetchConfig {
  /// Default byte budget for `WebFetch.fetch()` when
  /// `WebFetchOptions.budgetBytes` is null. Spec default: 262 144
  /// (256 KiB).
  final int defaultBudgetBytes;

  /// `User-Agent` header forced on every web-fetch call. The
  /// substrate does not let consumers override the UA (the
  /// `WebFetchOptions` surface deliberately excludes header
  /// overrides — robots-policy compliance lives at this layer).
  final String userAgent;

  const WebFetchConfig({
    this.defaultBudgetBytes = 262144,
    this.userAgent = 'TomBrain/0.1 (+https://tom-brain.local)',
  });
}

/// MCP-client subtree (spec § 9, § 3.2).
final class McpClientConfigBlock {
  /// Configured endpoints, keyed by endpoint id (the same id
  /// consumers pass to `mcpClient(McpEndpoint('memory'))`).
  final Map<String, McpEndpointConfig> endpoints;

  const McpClientConfigBlock({this.endpoints = const {}});
}

/// MCP transport kind. Mirrors policy override 2 (substrate-side
/// MCP is HTTP with optional bearer auth; stdio remains available
/// for local in-process deployments).
enum McpTransportKind {
  /// Stdio transport (`command:`). Auth must be `none`; stdio +
  /// bearer is rejected at load time and at the
  /// `McpAuthResolver.resolve()` boundary (B.34).
  stdio,

  /// Streamable-HTTP-JSON transport (`url:` + optional `auth:`).
  http,
}

/// One row of `mcpClient.endpoints` (spec § 9).
final class McpEndpointConfig {
  /// Transport discriminator.
  final McpTransportKind transport;

  /// Spawn command for [McpTransportKind.stdio]; `null` for HTTP.
  final String? command;

  /// Endpoint URL for [McpTransportKind.http]; `null` for stdio.
  final Uri? url;

  /// Auth profile. Stdio: must be `McpAuthConfig.none`. HTTP:
  /// `McpAuthConfig.none` or `McpAuthConfig.bearer(...)`.
  ///
  /// Reuses the B.34 `McpAuthConfig` type so the facade hands it
  /// straight to `McpAuthResolver.resolve()` without an adapter
  /// layer.
  final McpAuthConfig auth;

  const McpEndpointConfig({
    required this.transport,
    required this.auth,
    this.command,
    this.url,
  });
}

/// One row of `substrate.priceTable` (spec § 9).
///
/// Used by the router-side cost reporter (spec § 5.4 / B.32+) to
/// stamp `LlmCallReport.cost` on paid-provider responses. Local
/// providers (Ollama, stub) have no entry; the router treats absent
/// entries as `cost: null`.
final class PriceEntry {
  /// Cost per million input tokens, in USD.
  final double inputPerMTokens;

  /// Cost per million output tokens, in USD.
  final double outputPerMTokens;

  const PriceEntry({
    required this.inputPerMTokens,
    required this.outputPerMTokens,
  });
}

/// Thrown by [SubstrateConfig.validateRoleRegistry] (and friends)
/// when a cross-section invariant is violated. The loader surfaces
/// the same exception type for the YAML-parse-time cross-validation
/// checks so callers have one type to catch.
class SubstrateConfigException implements Exception {
  /// Dotted key path identifying the offending field, or a
  /// human-readable description when the failure straddles
  /// multiple keys.
  final String message;

  const SubstrateConfigException(this.message);

  @override
  String toString() => 'SubstrateConfigException: $message';
}

/// Configuration consumed by `TomBrainSubstrateClient.open` (and
/// by the in-process facade `InProcessTomBrainSubstrate` at B.40).
///
/// Loaded from `substrate:` YAML via [SubstrateConfigLoader.parse]
/// or [SubstrateConfigLoader.loadFromFile]; constructed directly
/// in tests for fine-grained scenarios.
final class SubstrateConfig {
  /// Provider catalogue. Keyed by `ProviderProfile.id`; the loader
  /// validates that every id is unique.
  final List<ProviderProfile> providers;

  /// Role → ordered chain of `RoleRouteEntryConfig`. The router
  /// walks each chain in order on every dispatch; missing roles
  /// surface as `RoleNotFound` at dispatch time. The loader
  /// validates that every `providerId` references a known provider
  /// and every `model` references a model the provider advertises.
  final Map<String, List<RoleRouteEntryConfig>> roleRoutes;

  /// Embedding-service choice. The facade constructs one
  /// `EmbeddingService` per process from this value.
  final EmbeddingChoice embedding;

  /// Router failover tunables (cooldowns / retry budget / overloaded
  /// backoff). Defaults to [RouterTunables.defaults] when the
  /// `router:` block is omitted.
  final RouterTunables router;

  /// Web-search subsystem configuration.
  final WebSearchConfig webSearch;

  /// Web-fetch subsystem configuration.
  final WebFetchConfig webFetch;

  /// MCP-client subsystem configuration.
  final McpClientConfigBlock mcpClient;

  /// Per-model price table. Sparse: providers without an entry
  /// surface `LlmCallReport.cost: null`.
  final Map<String, PriceEntry> priceTable;

  const SubstrateConfig({
    required this.providers,
    required this.roleRoutes,
    required this.embedding,
    required this.webSearch,
    required this.webFetch,
    required this.mcpClient,
    this.router = RouterTunables.defaults,
    this.priceTable = const {},
  });

  /// Returns the [ProviderProfile] with the matching [id], or
  /// `null` when no such provider exists.
  ProviderProfile? lookupProvider(String id) {
    for (final p in providers) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Returns the [PriceEntry] for `providerId/modelId`, or `null`
  /// when the pair is not priced (the router treats this as
  /// "cost: null on the report").
  PriceEntry? lookupPrice(String providerId, String modelId) {
    return priceTable['$providerId/$modelId'];
  }

  /// Constructs a [RouterPolicy] from `providers` + `roleRoutes`.
  ///
  /// Spec § 5.1 / § 5.3: the policy's `roleRoutes` map carries
  /// runtime [RouteEntry] rows in declaration order; ordering IS
  /// the tier policy. The cooldown schedule, retry budget, and
  /// overloaded-backoff window come from the [router] tunables
  /// (spec § 9 `substrate.router`, Q-B.36.2). When [router] is
  /// [RouterTunables.defaults] (the `router:` block was omitted),
  /// `cooldownByClass` is `null`, so [RouterPolicy] supplies its
  /// own [RouterPolicy.defaultCooldowns] — `RouterPolicy` stays the
  /// single source of truth for the default schedule.
  ///
  /// Pure value-to-value transform — no provider construction, no
  /// network access. The facade composes this with its provider
  /// instances when building the `LlmRouter`.
  RouterPolicy buildRouterPolicy() {
    final routes = <String, List<RouteEntry>>{};
    for (final entry in roleRoutes.entries) {
      routes[entry.key] = entry.value
          .map(
            (e) => RouteEntry(
              providerId: e.providerId,
              model: e.model,
              conditions: _toRouteConditions(e.conditions),
            ),
          )
          .toList(growable: false);
    }
    return RouterPolicy(
      roleRoutes: routes,
      cooldownByClass: router.cooldownByClass,
      retriesPerClass: router.retriesPerClass,
      overloadedBackoff: router.overloadedBackoff,
    );
  }

  /// Cross-validates that every role id in [roleRoutes] is
  /// registered in [registry].
  ///
  /// Throws [SubstrateConfigException] (wrapping the registry's
  /// [RoleTemplateNotFound] for the first miss) when an
  /// unregistered role id is found in the routes. Per Q-B.22.4
  /// this is the canonical cross-validation step the spec calls
  /// for ("every routed role has a registered template").
  ///
  /// Idempotent — safe to call multiple times. The registry is
  /// not mutated.
  ///
  /// Symmetric check (every registered template has a route) is
  /// **not** enforced. A registered role with no route is
  /// legitimate: tests / future procedures may use the template
  /// without dispatching through the router. The asymmetric
  /// failure mode the spec calls out is "route references missing
  /// template" — that one is fatal.
  void validateRoleRegistry(RoleRegistry registry) {
    for (final roleId in roleRoutes.keys) {
      if (!registry.contains(roleId)) {
        throw SubstrateConfigException(
          'substrate.roleRoutes references role id "$roleId" which is '
          'not registered in the role registry (known ids: '
          '${registry.ids.toList()}).',
        );
      }
    }
  }

  static RouteConditions _toRouteConditions(RouteConditionsConfig? config) {
    if (config == null) return RouteConditions.empty;
    return RouteConditions(maxInputTokens: config.maxInputTokens);
  }
}
