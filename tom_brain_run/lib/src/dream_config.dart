// DreamConfig — the typed `dream:` section of the whole-process config: whether
// the scheduled dream cadence runs at boot, the daily windows it runs in, and an
// optional heartbeat override (item b).
//
// The block is optional. Its absence (a `null` on `BrainRunConfig`) means the
// run assembly stands up *no* dream loop — the prototype's many deterministic
// live tests never spin a background cadence. A present block carries:
//
//   * `enabled`         — whether to start the dream loop at boot (default
//                         `false`, so a `dream:` block can be authored and left
//                         dormant). A bootable but disabled block is well-formed.
//   * `windows`         — the "several time-slots in a day" dreaming is allowed
//                         in (`DreamWindowSchedule`). An empty / absent list is
//                         "always active" — dream whenever otherwise idle.
//   * `heartbeatSeconds`— an optional override for how often the loop polls its
//                         window/mode gate (default the loop's one-minute beat).
//
// This value type is read-only — parsed once at boot by `DreamConfigLoader` and
// never re-serialised.

import 'dream_window_schedule.dart';

/// Thrown when a `dream:` block is structurally invalid (an unknown key, a
/// malformed window bound, a non-positive heartbeat, …).
///
/// Messages carry the dotted key path (e.g. `dream.windows[0].end`) so the
/// offending field is obvious — the same located-error discipline the sibling
/// section loaders use.
class DreamConfigException implements Exception {
  /// Builds the exception with a [message].
  const DreamConfigException(this.message);

  /// Human-readable, located explanation.
  final String message;

  @override
  String toString() => 'DreamConfigException: $message';
}

/// The parsed `dream:` section — the boot-time dream-cadence policy (item b).
///
/// Present ⇒ the run assembly may stand up a `DreamController` gated on
/// [schedule] (only when [enabled]); its absence (a `null` on `BrainRunConfig`)
/// ⇒ no dream loop at all.
final class DreamConfig {
  /// Assembles a dream config.
  ///
  /// [enabled] defaults to `false` (a dormant but well-formed block); [schedule]
  /// defaults to an empty (always-active) schedule; [heartbeat] is `null` unless
  /// overridden.
  const DreamConfig({
    required this.enabled,
    required this.schedule,
    this.heartbeat,
  });

  /// Whether the run assembly starts the dream loop at boot. A `false` here
  /// leaves the cadence dormant even though the block is present and valid.
  final bool enabled;

  /// The daily windows dreaming is allowed in. Empty ⇒ always active.
  final DreamWindowSchedule schedule;

  /// The optional heartbeat override — how often the gated loop polls its
  /// window/mode gate. `null` ⇒ the loop's one-minute default.
  final Duration? heartbeat;
}
