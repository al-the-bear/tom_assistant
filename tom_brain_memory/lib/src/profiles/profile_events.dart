// Profile `MemoryEvent` leaves — `ProfileCreated` / `ProfileDropped`.
//
// Spec memory § 16 names the profile-administration events memory fans
// out over the single observability stream. The `MemoryProfileRegistry`
// emits `ProfileCreated` when a profile is first materialised and
// `ProfileDropped` when one is wiped (reset-to-zero). Both ride the
// parent store's event bus, so a subscriber on `events()` sees profile
// lifecycle alongside the data-plane events.
//
// Emission discipline mirrors the rest of the § 16 family: one event
// per *effective* mutation. `createProfile` on an already-existing
// profile is idempotent and does not re-emit; `dropProfile` of an
// absent profile is a no-op and does not emit.
//
// The discriminators (`memory.profile-created` /
// `memory.profile-dropped`) follow the per-component kebab convention
// documented on `MemoryEvent`. Profile lifecycle happens outside any
// procedure run, so `runId` is null.

import 'package:tom_brain_shared/tom_brain_shared.dart' show MemoryEvent;

/// Emitted when the profile registry first materialises a profile
/// (memory § 2.5 / § 16).
final class ProfileCreated extends MemoryEvent {
  /// Name of the profile that was created.
  final String profileName;

  const ProfileCreated({
    required this.profileName,
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'memory.profile-created';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'profileName': profileName,
      };
}

/// Emitted when the profile registry drops a profile — a whole-store
/// delete that resets the profile to zero (memory § 2.5 / § 16).
final class ProfileDropped extends MemoryEvent {
  /// Name of the profile that was dropped.
  final String profileName;

  const ProfileDropped({
    required this.profileName,
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'memory.profile-dropped';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'profileName': profileName,
      };
}
