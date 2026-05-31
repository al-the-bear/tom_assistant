// B.36 — `lib/src/config/` barrel.
//
// The substrate's configuration surface lives here (mirroring
// `tom_brain_memory/lib/src/config/`). The top-level package barrel
// re-exports this barrel so consumers see the typed config root
// (`SubstrateConfig`) and the YAML loader (`SubstrateConfigLoader`)
// under the package's public import path.
//
// What lives behind this barrel:
//
//   * `SubstrateConfig` — root of the spec § 9 typed model.
//     Replaces the B.9 opaque placeholder; the api/ surface routes
//     `TomBrainSubstrateClient.open(SubstrateConfig)` through the
//     concrete type produced here.
//   * Provider / route / embedding / web / MCP / price-table
//     value types (`ProviderProfile`, `ProviderKind`,
//     `ProviderAuthConfig`, `RoleRouteEntryConfig`,
//     `RouteConditionsConfig`, `EmbeddingChoice`, `WebSearchConfig`,
//     `WebSearchProviderConfig`, `WebFetchConfig`,
//     `McpClientConfigBlock`, `McpTransportKind`,
//     `McpEndpointConfig`, `PriceEntry`).
//   * `SubstrateConfigException` — typed load-time failure.
//   * `SubstrateConfigLoader` — `parse` / `loadFromFile` entry
//     points that turn a YAML document into the typed model and
//     enforce every cross-section invariant the spec calls out.
//
// What does NOT live behind this barrel:
//
//   * Secret resolution. `secretRef:` strings are carried through
//     verbatim; the facade (B.40) resolves them via the runtime
//     resolver layer (the same posture as B.34's `McpAuthResolver`).
//   * Runtime object construction. `buildRouterPolicy()` returns a
//     pure value (`RouterPolicy`) — no `LlmProvider` instances are
//     wired here; the facade composes those.
//   * Role-registry validation against a registered set. The
//     loader exposes `SubstrateConfig.validateRoleRegistry` for
//     the facade to call once the registry is known; the loader
//     itself does not depend on a registry.
//
// Adding a new field to the YAML schema:
//
//   1. Extend the typed model in `substrate_config.dart`.
//   2. Extend the parser in `substrate_config_loader.dart` (with
//      the dotted-key-path error message).
//   3. Add a round-trip test in `test/b36_substrate_config_loader_test.dart`.
//   4. Update `substrate_specification.md` § 9 (the spec is the
//      authoritative source — code follows).

export 'substrate_config.dart';
export 'substrate_config_loader.dart';
