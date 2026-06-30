// Profile binding for the standalone memory MCP server
// (`bin/memory_mcp_server.dart`; `memory_specification.md` § 2.5 / § 3.2).
//
// Before the memory-profile work the brain opened its store directly at
// `<root>` (`memory.db`, `vectors.db`, …). § 8.1 retired that bare-root layout:
// every profile — the default included — now lives under
// `<root>/profiles/<name>/`, and the default profile is `defaultMemoryProfile`
// (`defaultmemory_default`). A bare-root-opened MCP server therefore reads a
// stale pre-profiles store and resolves *no* node id the live brain wrote,
// which surfaced in the Observatory as `No node '<id>'` on every node
// deep-link. This pure helper is the binding decision the bin makes before it
// opens the store: select the profile the server reads.

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show defaultMemoryProfile, MemoryConfig, validateMemoryProfileName;

/// Resolves the profile-bound [MemoryConfig] the MCP server opens.
///
/// [base] is the whole-process run config (its `memory:` section, profile
/// unbound). With no [profile] override — or a `null`/empty one — the result is
/// bound to [defaultMemoryProfile], so the server reads the same default-profile
/// store the live brain writes (`<root>/profiles/defaultmemory_default/`),
/// never the legacy bare root. A non-default [profile] is validated as a safe
/// profile name (path-traversal guard, MSPP-25) and binds that profile instead.
///
/// Throws [ArgumentError] for a profile name carrying a path separator or a
/// `.`/`..` segment, before any store is opened.
MemoryConfig resolveMcpServerMemoryConfig(MemoryConfig base, {String? profile}) {
  if (profile == null || profile.isEmpty) {
    return base.withProfile(defaultMemoryProfile);
  }
  validateMemoryProfileName(profile);
  return base.withProfile(profile);
}
