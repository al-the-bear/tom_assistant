// Profile — the raw, config-side Profile aggregate (session_configuration.md
// § 3.1, plan step 3).
//
// This is the parsed-from-`profiles:` value object, *before* boot resolution.
// The boot-resolved bundle the engine reads off `Access` is the separate
// `ResolvedProfile` (in `tom_brain_shared`); `ProfileRegistry.resolve` turns a
// `Profile` + the boot context (global-exposed MCP ids, budget/rate-limit
// ceilings) into a `ResolvedProfile`.
//
// Placement (SCP-6): this aggregate lives in `tom_brain_run`, not
// `tom_brain_shared`, because it composes `List<McpServerConfig>` — a
// `tom_brain_procedure` type that `tom_brain_shared`'s dependency discipline
// forbids. The value sub-types it carries (`ProfileMode`, `ProfileBudget`,
// `ProfileRateLimits`) and `ResolvedProfile` itself stay in shared.

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show McpServerConfig;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show ProfileBudget, ProfileMode, ProfileRateLimits;

/// One configured profile, parsed from a `profiles.<id>:` map. Immutable.
final class Profile {
  /// The configured name (the `profiles:` map key), e.g. `research`.
  final String id;

  /// The processing shape; defaults to [ProfileMode.cognitive] (today's
  /// behaviour, SC-5).
  final ProfileMode mode;

  /// An explicit entry-procedure override of [mode]'s default; `null` ⇒ use
  /// [ProfileMode.defaultEntryProcedure]. Setting this to a procedure that
  /// disagrees with an explicit [mode] is a parse-time config error
  /// (`profile.mode_entry_conflict`).
  final String? entryProcedure;

  /// A pinned substrate-role id; `null` ⇒ derive the role from the model-id
  /// persona. An unknown role id is a boot-time error (`profile.unknown_role`).
  final String? role;

  /// Whether the assistant-dedication anchor is injected for this profile's
  /// prompts (default `true`; § 3.4 / SC-2).
  final bool anchored;

  /// The template-overlay directory name under `<cognition.root>/overlays/`, or
  /// `null` for the base registry. A missing dir is a boot-time error
  /// (`profile.overlay_missing`).
  final String? templateOverlay;

  /// The allowlist of global `mcpServers` ids this profile may use, intersected
  /// with the global `exposeToLlms` set at resolve time (§ 3.6). An empty list
  /// means "all globally-exposed servers". Unmodifiable.
  final List<String> mcpServers;

  /// Per-profile MCP server definitions (the same `McpServerConfig` shape as the
  /// global block), connected for this profile only and registered under a
  /// profile-namespaced id (`<id>/<serverName>`). Unmodifiable.
  final List<McpServerConfig> defineMcpServers;

  /// The per-profile budget override (composed with the global ceiling at boot,
  /// SC-8), or `null` to use the entry procedure's header.
  final ProfileBudget? budget;

  /// The per-profile rate-limits (composed with the per-principal quota,
  /// tightens only), or `null` to use the global values.
  final ProfileRateLimits? rateLimits;

  /// Advisory default session selector, applied only when the request carries no
  /// explicit session marker (§ 3.7 / SC-1); `null` ⇒ no default.
  final String? defaultSession;

  /// Advisory default memory selector, applied only when the request carries no
  /// explicit memory marker (§ 3.7 / SC-1); `null` ⇒ no default.
  final String? defaultMemory;

  /// Builds a profile. Only [id] is required; every behavioural field is
  /// optional and defaults to today's behaviour (cognitive, anchored, no
  /// overlay, no allowlist, no defines, global budget/limits, no cross-axis
  /// defaults).
  Profile({
    required this.id,
    this.mode = ProfileMode.cognitive,
    this.entryProcedure,
    this.role,
    this.anchored = true,
    this.templateOverlay,
    List<String> mcpServers = const <String>[],
    List<McpServerConfig> defineMcpServers = const <McpServerConfig>[],
    this.budget,
    this.rateLimits,
    this.defaultSession,
    this.defaultMemory,
  })  : mcpServers = List<String>.unmodifiable(mcpServers),
        defineMcpServers =
            List<McpServerConfig>.unmodifiable(defineMcpServers);

  /// The concrete entry procedure this profile runs — the explicit
  /// [entryProcedure] if set, else [mode]'s default (§ 3.2).
  String get effectiveEntryProcedure =>
      entryProcedure ?? mode.defaultEntryProcedure;
}
