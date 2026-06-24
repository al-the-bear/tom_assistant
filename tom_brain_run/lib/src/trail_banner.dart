// TrailBanner — the startup banner announcing the active trail mode
// (`tom_brain_logging.md` §4.1; §10 step #1).
//
// §4.1 requires a banner emitted early (before the first turn) stating which
// of the two modes is active. The text is produced here as a pure function so
// it is unit-testable without a logger; `tom_brain serve` emits the
// result through `tomLog.status`, which prepends the `STATUS ` level the §4.1
// example shows. The `[tom_brain.trail]` category prefix is part of the body
// (the same convention `MemoryLog`/`SubstrateLog` use via their `_tag`).

import 'trail_config.dart';

/// Builds the §4.1 startup banner announcing the active [TrailMode].
abstract final class TrailBanner {
  TrailBanner._();

  /// The full-tree surfaces a configured trail writes (§4.2), named in the
  /// enabled banner.
  static const List<String> _surfaces = <String>[
    'llm',
    'incoming',
    'procedures',
    'memory',
    'sessions',
    'summary',
  ];

  /// The banner text for the active mode: an enabled banner naming [config]'s
  /// `root` + the full-tree surfaces when [config] is non-null, or an
  /// unconfigured banner naming the [cwd], the disabled surfaces, and the
  /// "set `trail.root`" hint when it is null.
  ///
  /// The returned string carries the `[tom_brain.trail]` category prefix; the
  /// caller passes it to `tomLog.status`, which renders the `STATUS ` level.
  static String forStartup(TrailConfig? config, {required String cwd}) {
    if (config == null) {
      return '[tom_brain.trail] trailing NOT CONFIGURED — component logs only\n'
          '        (brain.log + components/*.log in CWD: $cwd).\n'
          '        Raw dumps, summaries, sessions & memory trails are '
          'DISABLED.\n'
          '        Set `trail.root` to enable full trailing.';
    }
    return '[tom_brain.trail] trailing ENABLED → ${config.root}\n'
        '        (surfaces: ${_surfaces.join(', ')})';
  }
}
