// MemoryProfileRegistry — the profile-administration surface
// (memory_specification.md § 2.5).
//
// A profile is an isolated `<memory-root>/profiles/<name>/` tenant:
// its own `memory.db`, `vectors.db`, `trails/`, `tombstones/`, and
// `checkpoints/`. Two profiles never cross-talk — a recall in one sees
// nothing of the other.
//
// This registry is the admin surface for that tier: `list` / `exists`
// to introspect, `createProfile` / `seedProfile` to materialise, and
// `dropProfile` to reset a whole profile to zero. `dropProfile` is a
// whole-store delete — distinct from the per-event `forget` on the
// data plane — and is deliberately **not** exposed on the read-only
// MCP server (memory § 3.2): an inspector can read a profile but can
// never create, seed, or wipe one.
//
// The concrete filesystem-backed implementation
// (`SqliteMemoryProfileRegistry`) lives in `tom_brain_memory`, where
// `dart:io` and the SQLite store are available. This abstract surface
// lives in `tom_brain_shared` so consumers (Tom Assistant's admin
// pane, an eval harness) can depend on the contract without taking a
// runtime dependency on the concrete store.

import '../api/scope.dart' show Scope;
import '../nodes/node.dart' show NodeDraft;

/// Administration surface for the `<memory-root>/profiles/<name>/`
/// tier (memory § 2.5).
///
/// Obtained from the concrete store's `profiles` getter once the store
/// is open. All methods are asynchronous because materialising or
/// wiping a profile touches the filesystem and (for create / seed) a
/// short-lived child store handle.
abstract interface class MemoryProfileRegistry {
  /// The names of every profile that currently exists under the memory
  /// root, in unspecified order. Empty when no profile has been
  /// created.
  Future<List<String>> list();

  /// Whether a profile named [name] currently exists.
  Future<bool> exists(String name);

  /// Creates an empty profile named [name], materialising its
  /// `<memory-root>/profiles/<name>/` layout and bootstrap catalogue.
  ///
  /// Idempotent: creating a profile that already exists is a no-op that
  /// does not re-emit. A [name] containing a path separator, or equal
  /// to `.` / `..`, or empty, is rejected with an [ArgumentError] —
  /// profile names must never escape the profiles directory. Emits a
  /// `ProfileCreated` event on first creation (memory § 16).
  Future<void> createProfile(String name);

  /// Seeds [drafts] into the profile named [name], persisting each
  /// under [scope].
  ///
  /// The profile is materialised if absent. Each draft becomes a fresh
  /// node — re-seeding after a [dropProfile] mints brand-new ids
  /// (reset-to-zero). [name] is validated exactly as in
  /// [createProfile].
  Future<void> seedProfile(
    String name,
    List<NodeDraft> drafts, {
    required Scope scope,
  });

  /// Drops the profile named [name] — a whole-store delete that resets
  /// the profile to zero (memory § 2.5).
  ///
  /// Distinct from the per-event `forget` on the data plane: this
  /// removes the entire `<memory-root>/profiles/<name>/` directory.
  /// Dropping a profile that does not exist is a no-op. [name] is
  /// validated exactly as in [createProfile]. Emits a `ProfileDropped`
  /// event when a profile was actually removed (memory § 16).
  Future<void> dropProfile(String name);
}
