// ObservatoryBanner — the startup banner pointing at the Tom Brain Observatory
// (`prompt_tracing.md` § 8.5; the read-only trail viewer in
// `tom_brain_observatory`).
//
// The Observatory is a *separate* loopback process the operator launches by
// hand (`tom_brain_observatory/bin/observatory.dart <trail-root>`), so the
// brain process cannot know its live port. What it can do — and what this
// banner exists for — is tell the operator, at boot, the URL to open and the
// trail root to point the Observatory at. The text is a pure function so it is
// unit-testable without a logger; `bin/brain_serve.dart` emits the result
// through `tomLog.status`, exactly like the sibling [TrailBanner].
//
// The default host/port mirror `observatory.dart`'s `_defaultHost` /
// `_defaultPort` (127.0.0.1 : 8787). The two packages are deliberately
// independent (neither depends on the other), so the constants are duplicated
// here rather than imported; keep them in step if the Observatory's defaults
// move.

import 'trail_config.dart';

/// Builds the startup banner announcing the Observatory URL and how to launch
/// it against this run's trail tree.
abstract final class ObservatoryBanner {
  ObservatoryBanner._();

  /// The Observatory's default loopback bind address (mirrors
  /// `observatory.dart`'s `_defaultHost`).
  static const String defaultHost = '127.0.0.1';

  /// The Observatory's default loopback port (mirrors `observatory.dart`'s
  /// `_defaultPort`).
  static const int defaultPort = 8787;

  /// The banner text pointing at the Observatory.
  ///
  /// When [config] is non-null (full trailing), the banner names the URL
  /// (`http://[host]:[port]/`) and the exact launch command pointed at
  /// [config]'s `root`. When [config] is null (unconfigured), it still shows
  /// the URL but explains there is no trail tree to inspect yet and points at
  /// the `trail.root` hint.
  ///
  /// The returned string carries the `[tom_brain.observatory]` category prefix;
  /// the caller passes it to `tomLog.status`, which renders the `STATUS ` level.
  static String forStartup(
    TrailConfig? config, {
    String host = defaultHost,
    int port = defaultPort,
  }) {
    final String url = 'http://$host:$port/';
    if (config == null) {
      return '[tom_brain.observatory] Trail Observatory → $url\n'
          '        Trailing is NOT CONFIGURED, so there is no trail tree to '
          'inspect yet.\n'
          '        Set `trail.root` to record a trail the Observatory can read.';
    }
    return '[tom_brain.observatory] Trail Observatory → $url\n'
        '        Open that URL after launching the Observatory with:\n'
        '          dart run tom_brain_observatory/bin/observatory.dart '
        '${config.root}\n'
        '        (loopback-only; reads the trail tree at ${config.root}).';
  }
}
