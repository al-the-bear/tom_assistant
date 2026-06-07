// Barrel for the `profiles/` module (H.27; spec memory § 2.5 + § 16).
//
// Exports:
//
//   - `MemoryProfileRegistry` — the abstract profile-administration
//     surface, re-exported from `tom_brain_shared` so the barrel keeps
//     a complete surface (the concrete impl + events live here).
//   - `SqliteMemoryProfileRegistry` — the filesystem-backed concrete
//     registry over `<memory-root>/profiles/`, returned by
//     `SqliteTomBrainMemory.profiles`.
//   - `ProfileCreated` / `ProfileDropped` — the § 16 event leaves the
//     registry emits on the parent store's bus.
//
// `dropProfile` (whole-store delete / reset-to-zero) is intentionally
// not on the read-only MCP server (memory § 3.2): the registry is an
// in-process admin surface, never exposed over the wire.

export 'package:tom_brain_shared/tom_brain_shared.dart'
    show MemoryProfileRegistry;
export 'profile_events.dart' show ProfileCreated, ProfileDropped;
export 'sqlite_memory_profile_registry.dart'
    show SqliteMemoryProfileRegistry;
