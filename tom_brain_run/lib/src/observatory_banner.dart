// ObservatoryBanner — the startup banner pointing at the Tom Brain Observatory
// (`prompt_tracing.md` § 8.5; the read-only trail viewer in
// `tom_brain_observatory`).
//
// The Observatory is normally hosted *in-process*, in a second isolate the run
// assembly spawns (`observatory_isolate_host.dart`); [running] is the banner for
// that case — it names the bound URL the brain already knows. When the operator
// disables it (`--no-observatory`), it fails to start, or no trail tree is
// configured, [forStartup] is the fallback banner: it names the URL and the
// hand-launch command for the standalone `bin/observatory.dart`. Both are pure
// functions so they are unit-testable without a logger; `tom_brain serve`
// emits the result through `tomLog.status`, exactly like the sibling
// [TrailBanner].
//
// The default host/port mirror `ObservatoryOptions.defaultHost` / `defaultPort`
// (127.0.0.1 : 8787); they are duplicated here rather than imported to keep this
// banner a pure string helper. Keep them in step if the Observatory's defaults
// move.

import 'trail_config.dart';

/// Builds the startup banner announcing the Observatory URL and how to reach it.
abstract final class ObservatoryBanner {
  ObservatoryBanner._();

  /// The Observatory's default loopback bind address (mirrors
  /// `ObservatoryOptions.defaultHost`).
  static const String defaultHost = '127.0.0.1';

  /// The Observatory's default loopback port (mirrors
  /// `ObservatoryOptions.defaultPort`).
  static const int defaultPort = 8787;

  /// The banner for the in-process Observatory: it is already serving at [url]
  /// (the bound loopback address the spawned isolate reported), reading the
  /// trail tree at [trailRoot]. The operator only has to open the URL.
  ///
  /// The returned string carries the `[tom_brain.observatory]` category prefix;
  /// the caller passes it to `tomLog.status`, which renders the `STATUS ` level.
  static String running(Uri url, String trailRoot) =>
      '[tom_brain.observatory] Trail Observatory → $url\n'
      '        Serving in-process (second isolate); reads the trail tree at '
      '$trailRoot.\n'
      '        Open that URL to inspect runs, procedure trees, and LLM calls.';

  /// The fallback banner when the Observatory is NOT hosted in-process (disabled
  /// with `--no-observatory`, failed to start, or no trail tree is configured).
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
