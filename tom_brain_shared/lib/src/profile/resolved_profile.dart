// ResolvedProfile — the boot-resolved Profile bundle stamped on `Access`
// (session_configuration.md § 4.2 / § 4.3, plan step 2).
//
// This is the resolved-not-selector behavioural knob the dispatcher and engine
// read — the analogue of `Session.memoryProfile`. The edge resolves a
// `profile-<name>` marker (or a Telegram default) to a `ResolvedProfile` and
// rides it onto `Access`; the marker itself never reaches the dispatcher
// (SC-4). A request that selects no profile resolves to
// [ResolvedProfile.cognitiveDefault], so `Access.profile` is never null (SC-5).
//
// Placement (SCP-6 / SCP-7): the *resolved* bundle lives in `tom_brain_shared`
// because `Access` reads it; the raw config-side `Profile` aggregate (with
// `List<McpServerConfig>`) lives in `tom_brain_run`, which may legally depend on
// `tom_brain_procedure`. The overlay is carried here by *name*, not as a bound
// `PromptResolver` handle (a live resolver is neither value-equal nor
// serialisable, and would re-break the dependency rule); the engine binds the
// actual `LayeredPromptResolver` from the name per run (step 8). The offered-MCP
// set is the *resolved* `(global-exposed ∩ allowlist) ∪ profile-defined-exposed`
// set as plain server-id strings (§ 3.6), so it carries no `McpServerConfig`
// dependency.

import 'package:tom_core_agentic/tom_core_agentic.dart' show listEquals;

import 'profile_budget.dart';
import 'profile_mode.dart';
import 'profile_rate_limits.dart';

/// The boot-resolved profile bundle the engine reads off `Access`. Immutable
/// value object.
final class ResolvedProfile {
  /// The configured profile id (e.g. `research`), stamped for trail/audit.
  final String id;

  /// The processing shape (drives behaviour + the trail's friendly label).
  final ProfileMode mode;

  /// The concrete entry procedure id this profile runs, already resolved from
  /// [mode] (or an explicit `entryProcedure`) at boot.
  final String entryProcedure;

  /// The pinned substrate role id; `null` ⇒ derive the role from the model-id
  /// persona (`PersonaResolver`). When set it is authoritative (spec § 3.3).
  final String? role;

  /// Whether the assistant-dedication anchor is injected for this profile's
  /// prompts (spec § 3.4 / SC-2). Default-on; `false` only for explicitly
  /// non-assistant relays.
  final bool anchored;

  /// The template-overlay *name* (`<cognition.root>/overlays/<name>/`), or
  /// `null` for the base registry. The engine binds the resolver from this
  /// name per run (step 8); the bundle carries the name, not a live resolver.
  final String? templateOverlay;

  /// The resolved offered-MCP server ids for this run
  /// (`(global-exposed ∩ allowlist) ∪ profile-defined-exposed`, § 3.6). An
  /// empty list is the "all globally-exposed servers" sentinel (today's
  /// behaviour). Unmodifiable.
  final List<String> offeredMcpServers;

  /// The effective per-profile budget override (already clamped to the global
  /// ceiling at boot, SC-8), or `null` to use the entry procedure's header.
  final ProfileBudget? budget;

  /// The effective per-profile rate-limits, or `null` to use the per-principal
  /// global values.
  final ProfileRateLimits? rateLimits;

  /// Advisory default session selector — applied only when the request carries
  /// no explicit session marker (spec § 3.7 / SC-1). `null` ⇒ no default.
  final String? defaultSession;

  /// Advisory default memory selector — applied only when the request carries
  /// no explicit memory marker (spec § 3.7 / SC-1). `null` ⇒ no default.
  final String? defaultMemory;

  ResolvedProfile({
    required this.id,
    required this.mode,
    required this.entryProcedure,
    this.role,
    this.anchored = true,
    this.templateOverlay,
    List<String> offeredMcpServers = const <String>[],
    this.budget,
    this.rateLimits,
    this.defaultSession,
    this.defaultMemory,
  }) : offeredMcpServers = List<String>.unmodifiable(offeredMcpServers);

  /// The reserved `default` profile — byte-compatible with today's behaviour
  /// (SC-5): the full cognitive process, model-id-derived role, anchored, no
  /// overlay, all globally-exposed servers (empty list sentinel), the global
  /// budget/rate-limit envelope, no cross-axis defaults. A `const` constructor
  /// so `Access.profile` can carry it as a compile-time default.
  const ResolvedProfile.cognitiveDefault()
      : id = 'default',
        mode = ProfileMode.cognitive,
        entryProcedure = 'prompt_analyzer_v1',
        role = null,
        anchored = true,
        templateOverlay = null,
        offeredMcpServers = const <String>[],
        budget = null,
        rateLimits = null,
        defaultSession = null,
        defaultMemory = null;

  factory ResolvedProfile.fromJson(Map<String, Object?> json) =>
      ResolvedProfile(
        id: json['id'] as String,
        mode: ProfileMode.fromWire(json['mode'] as String),
        entryProcedure: json['entryProcedure'] as String,
        role: json['role'] as String?,
        anchored: json['anchored'] as bool? ?? true,
        templateOverlay: json['templateOverlay'] as String?,
        offeredMcpServers:
            (json['offeredMcpServers'] as List?)?.cast<String>() ??
                const <String>[],
        budget: json['budget'] == null
            ? null
            : ProfileBudget.fromJson(
                (json['budget'] as Map).cast<String, Object?>()),
        rateLimits: json['rateLimits'] == null
            ? null
            : ProfileRateLimits.fromJson(
                (json['rateLimits'] as Map).cast<String, Object?>()),
        defaultSession: json['defaultSession'] as String?,
        defaultMemory: json['defaultMemory'] as String?,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'mode': mode.wireName,
        'entryProcedure': entryProcedure,
        'role': role,
        'anchored': anchored,
        'templateOverlay': templateOverlay,
        'offeredMcpServers': offeredMcpServers,
        'budget': budget?.toJson(),
        'rateLimits': rateLimits?.toJson(),
        'defaultSession': defaultSession,
        'defaultMemory': defaultMemory,
      };

  @override
  bool operator ==(Object other) =>
      other is ResolvedProfile &&
      other.id == id &&
      other.mode == mode &&
      other.entryProcedure == entryProcedure &&
      other.role == role &&
      other.anchored == anchored &&
      other.templateOverlay == templateOverlay &&
      listEquals(other.offeredMcpServers, offeredMcpServers) &&
      other.budget == budget &&
      other.rateLimits == rateLimits &&
      other.defaultSession == defaultSession &&
      other.defaultMemory == defaultMemory;

  @override
  int get hashCode => Object.hash(
        id,
        mode,
        entryProcedure,
        role,
        anchored,
        templateOverlay,
        Object.hashAll(offeredMcpServers),
        budget,
        rateLimits,
        defaultSession,
        defaultMemory,
      );

  @override
  String toString() => 'ResolvedProfile(id: $id, mode: ${mode.wireName}, '
      'entryProcedure: $entryProcedure, role: $role, anchored: $anchored, '
      'templateOverlay: $templateOverlay, '
      'offeredMcpServers: $offeredMcpServers, budget: $budget, '
      'rateLimits: $rateLimits, defaultSession: $defaultSession, '
      'defaultMemory: $defaultMemory)';
}
