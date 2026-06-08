// FanoutLogOutput — the console+file teeing log sink (`tom_brain_logging.md`
// §5.1; §10 build-order step #3).
//
// ── What it is ───────────────────────────────────────────────────────
//
// A [TomLogOutput] that *fans one log line out* to:
//
//   1. the console (a delegate [TomConsoleLogOutput] by default) — so the
//      existing stdout/stderr behaviour every component already relies on is
//      preserved untouched; and
//   2. on-disk log files under a single root directory, routed by the
//      `[<namespace>.<component>.<area>]` tag that `MemoryLog` / `SubstrateLog`
//      prepend to every message:
//
//        * every **headline** line (status / warn / error / severe / fatal) →
//          `<root>/<mainLogName>.log` (default `brain.log`) — the high-level
//          "see the brain thinking" view (§5.1);
//        * every **detail** line down to `debug` that carries a recognised
//          `<namespace>.<component>.*` tag → `<root>/components/<component>.log`
//          — the full per-component detail (§4.2).
//
// `<root>` is the current working directory in *unconfigured* mode and
// `trail.root` in *full* mode (§4.1); this class is indifferent to which —
// it writes wherever [logRoot] points.
//
// ── Why it lives in `tom_brain_memory` ───────────────────────────────
//
// §9's hook table sites this sink as "NEW in `tom_brain_shared` *or*
// `tom_basics`", but neither fits:
//
//   * `tom_brain_shared` is contractually I/O-free (its pubspec and
//     `dependency_discipline_test` forbid any storage / logging side effect),
//     and this sink does file I/O.
//   * `tom_basics` is the fleet-wide published baseline consumed as a hosted
//     `^1.0.0` constraint; pushing a brain-trail-shaped sink there would force
//     a publish+bump cycle through a package far outside the brain prototype.
//
// `tom_brain_memory` is the lowest brain package reachable from **both** of
// the two install sites — the host boot (`brain_serve.dart`, via
// `tom_brain_run → tom_brain_memory`) and the memory isolate worker (which
// lives here). The class itself carries no memory-specific logic; it only
// physically resides here. Routing is generic (a `[a.b.c]` tag → component
// `b`, gated by an expected [namespace]).
//
// ── Discipline ───────────────────────────────────────────────────────
//
// Best-effort and non-blocking: every file operation is wrapped so a failure
// (a read-only root, a path collision, a races rotation) is swallowed — a
// trail write must *never* fail a turn. Writes are synchronous single-line
// appends so lines never interleave mid-line, even when the host isolate and
// the memory isolate append to the same `brain.log` concurrently.

import 'dart:io';

import 'package:tom_basics/tom_basics.dart';

/// A [TomLogOutput] that tees every line to a console delegate and to
/// size-rotated on-disk files, routed by the `[<namespace>.<component>.<area>]`
/// tag (`tom_brain_logging.md` §5.1).
///
/// Construct with the directory the files live under ([logRoot]); install it
/// as `tomLog.logOutput` at boot, in the host process and the memory isolate.
final class FanoutLogOutput extends TomLogOutput {
  /// Builds the sink.
  ///
  /// [logRoot] is the directory `<mainLogName>.log` and `components/` are
  /// written under (CWD when unconfigured, `trail.root` in full mode — §4.1).
  /// [console] is the tee target for stdout/stderr (a [TomConsoleLogOutput] by
  /// default, preserving the current behaviour). [namespace] is the leading
  /// tag segment a line must carry to be routed to a component file
  /// (`tom_brain`). [rotateBytes] / [rotateKeep] are the §8 size-rotation caps
  /// (10 MB × 5 by default).
  FanoutLogOutput({
    required this.logRoot,
    TomLogOutput? console,
    this.namespace = 'tom_brain',
    this.mainLogName = 'brain',
    this.rotateBytes = 10 * 1024 * 1024,
    this.rotateKeep = 5,
  }) : _console = console ?? TomConsoleLogOutput();

  /// The directory the log files live under.
  final Directory logRoot;

  /// The leading tag segment that routes a line to a component file.
  final String namespace;

  /// The headline log's base name (without extension) — `brain` ⇒ `brain.log`.
  final String mainLogName;

  /// Size cap (bytes) at which a file is rotated (`tom_brain_logging.md` §8).
  final int rotateBytes;

  /// How many rotated segments to keep (`.1` … `.rotateKeep`).
  final int rotateKeep;

  final TomLogOutput _console;

  /// Headline levels routed to `<mainLogName>.log`: status + warn + error +
  /// severe + fatal (exactly `TomLogLevel.still`). The §5.1 "every line →
  /// brain.log at status/warn/error" view.
  static final TomLogLevel _headlineLevels = TomLogLevel.still;

  /// Detail levels routed to `components/<component>.log`: everything from
  /// `debug` upward (exactly `TomLogLevel.extended` — all but `trace`). The
  /// §5.1 "full lines (down to debug)" view.
  static final TomLogLevel _componentLevels = TomLogLevel.extended;

  /// Matches a leading `[<ns>.<component>.<area…>]` tag, capturing the
  /// namespace (group 1) and the component (group 2).
  static final RegExp _tagPattern =
      RegExp(r'^\[([a-z0-9_]+)\.([a-z0-9_]+)(?:\.[a-z0-9_]+)*\]');

  @override
  void output(
    TomLogLevel loggerLevel,
    TomLogLevel logLevel,
    String level,
    Object message,
    String isolateName,
    DateTime timeStamp, [
    String? origin,
  ]) {
    // Stringify once — the message may be a lazy `() => String`, and we must
    // not evaluate it three times (console + tag-extraction + line-format).
    final String text = convertToString(message);

    // 1. Console tee. Pass the already-stringified text so the delegate's own
    //    level filter (`logLevel.matches(loggerLevel)`) and format apply
    //    unchanged, without re-evaluating a lazy message.
    try {
      _console.output(
        loggerLevel,
        logLevel,
        level,
        text,
        isolateName,
        timeStamp,
        origin,
      );
    } catch (_) {
      // The console is best-effort too — never let it fail a turn.
    }

    final bool headline = logLevel.matches(_headlineLevels);
    final bool detail = logLevel.matches(_componentLevels);
    if (!headline && !detail) return; // e.g. trace — files skip it entirely.

    final String line = _format(level, text, isolateName, timeStamp, origin);

    if (headline) {
      _appendLine(File('${logRoot.path}/$mainLogName.log'), line);
    }
    if (detail) {
      final String? component = _componentOf(text);
      if (component != null) {
        _appendLine(
          File('${logRoot.path}/components/$component.log'),
          line,
        );
      }
    }
  }

  /// Extracts the component segment of a recognised `[<namespace>.<component>.*]`
  /// tag, or `null` when the line is untagged or carries a foreign namespace.
  String? _componentOf(String text) {
    final Match? m = _tagPattern.firstMatch(text);
    if (m == null) return null;
    if (m.group(1) != namespace) return null;
    return m.group(2);
  }

  /// Renders one file line, mirroring the console format's field order.
  String _format(
    String level,
    String text,
    String isolateName,
    DateTime timeStamp,
    String? origin,
  ) {
    final String originPart =
        (origin != null && origin.isNotEmpty) ? ' [$origin]' : '';
    return '$timeStamp $isolateName $level $text$originPart';
  }

  /// Appends `line` (with a trailing newline) to [file], rotating it first if
  /// it would cross [rotateBytes]. Every step is best-effort: a failure is
  /// swallowed so a trail write never fails a turn.
  void _appendLine(File file, String line) {
    try {
      final Directory parent = file.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      if (file.existsSync() &&
          file.lengthSync() + line.length + 1 > rotateBytes) {
        _rotate(file);
      }
      file.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // Best-effort: a read-only root, a path collision, or a concurrent
      // rotation race must never propagate into the logging call site.
    }
  }

  /// Shifts `<base>.<k>` → `<base>.<k+1>` (dropping the oldest) and moves
  /// `<base>` → `<base>.1`, capping the kept segments at [rotateKeep].
  void _rotate(File base) {
    try {
      final String path = base.path;
      final File oldest = File('$path.$rotateKeep');
      if (oldest.existsSync()) oldest.deleteSync();
      for (int i = rotateKeep - 1; i >= 1; i--) {
        final File segment = File('$path.$i');
        if (segment.existsSync()) segment.renameSync('$path.${i + 1}');
      }
      if (base.existsSync()) base.renameSync('$path.1');
    } catch (_) {
      // A rotation race (two isolates rotating the same file) is harmless —
      // the worst case is a slightly oversize segment, never a crash.
    }
  }
}
