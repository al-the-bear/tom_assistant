// DispatcherConfig — the dispatcher's YAML-loadable configuration (Plan step
// D.47; `tom_brain_procedure_prototype_specification.md` § 13).
//
// ── What it carries ─────────────────────────────────────────────────
//
// Spec § 13 names exactly four dispatcher knobs:
//
//   • the foreground queue depth (the FIFO the `RunCoordinator` admits
//     behind a busy foreground slot, D.19),
//   • the hard step deadline (the coordinator-level cross-check of the
//     engine's per-step deadline, D.21),
//   • the scheduler enabled/disabled flag (whether the free-time scheduler,
//     D.33, runs background work when the foreground is idle),
//   • the scripts paths (`scripts/system/` + `scripts/user/` — the same two
//     the `DiskProcedureStore` reads; the dispatcher owns the boot that
//     wires the store, so the paths live on its config too).
//
// `DispatcherConfig` is the value object that bundles those four; its YAML
// loader turns an operator-supplied document into the object boot feeds the
// `RunCoordinator` (queue depth + hard step deadline), the
// `DiskProcedureStore` (the two paths), and the free-time scheduler wiring
// (the enabled flag).
//
// ── YAML shape ──────────────────────────────────────────────────────
//
//   scripts:
//     system: scripts/system     # defaults below
//     user: scripts/user         # optional — omit when no user scripts
//   queue:
//     foregroundDepth: 4         # FIFO depth behind a busy foreground slot
//   deadline:
//     hardStepMs: 65000          # coordinator hard step deadline
//   scheduler:
//     enabled: false             # free-time scheduler on/off
//
// Every section is optional: an empty or absent document yields the
// all-defaults configuration (`scripts/system`, no user dir, queue depth 4,
// 65 s hard step deadline, scheduler off). Only *present* sections with the
// wrong shape are rejected — a missing section is "use the default", never an
// error.
//
// ── Why the `yaml` package, not a `tom_build_base` loader ───────────
//
// Spec § 13 says "via `tom_build_base` YAML loaders". The prototype does not
// depend on `tom_build_base` (it is not in the C.7 dependency set, and the
// dependency-surface test locks that set), and it already parses every other
// YAML it reads — the procedure header (C.24), the engine config (C.42) —
// with the canonical `yaml` package directly. `DispatcherConfig` uses the
// same package and the same "funnel every structural problem through one
// typed error" discipline (`DispatcherConfigInvalid`, mirroring
// `EngineConfigInvalid`). The divergence from the spec wording is the same
// one C.42 logged (Q-C.42.1); the loader contract is identical either way.

library;

import 'dart:io';

import 'package:yaml/yaml.dart';

import 'dispatcher_config_invalid.dart';
import 'engine_config.dart' show defaultSystemScriptsPath;
import 'yaml_field_readers.dart';

export 'engine_config.dart' show defaultSystemScriptsPath, defaultUserScriptsPath;

/// The default foreground FIFO queue depth the [DispatcherConfig] applies
/// when the `queue.foregroundDepth` field is absent.
///
/// Matches `RunCoordinator`'s own constructor default (4): the maximum number
/// of foreground runs that may *wait* behind the running one. A depth of 0
/// disables queueing (a busy slot overflows immediately).
const int defaultForegroundQueueDepth = 4;

/// The default coordinator hard step deadline the [DispatcherConfig] applies
/// when the `deadline.hardStepMs` field is absent.
///
/// The engine's own per-step deadline (`defaultStepDeadline`, 60 s) plus the
/// coordinator's grace (`defaultCoordinatorDeadlineGrace`, 5 s) = 65 s, so the
/// engine's in-band truncation wins under normal operation and the
/// coordinator's harder abort is a backstop. Mirrors `RunCoordinator`'s own
/// `hardStepDeadline` default.
///
/// Hardcoded here because `defaultStepDeadline + defaultCoordinatorDeadlineGrace`
/// is not a const expression (`Duration.operator +` is not a const
/// constructor), and a default value must be const. The dispatcher-config test
/// guards this constant against drift by asserting it equals the sum of the two
/// source constants.
const Duration defaultDispatcherHardStepDeadline = Duration(seconds: 65);

/// The default for the free-time scheduler's enabled flag.
///
/// Off by default: the prototype's free-time scheduler (D.33) is intentionally
/// weak (no dream cycles yet), so a prototype boot stays quiet — no surprise
/// background runs — unless an operator opts in. See Q-D.47.1.
const bool defaultSchedulerEnabled = false;

/// The dispatcher's loadable configuration: the two procedure-script paths,
/// the foreground queue depth, the coordinator hard step deadline, and the
/// free-time-scheduler enabled flag.
///
/// Immutable value object. Build one directly for tests/defaults, or load one
/// from YAML with [DispatcherConfig.fromYamlString] /
/// [DispatcherConfig.loadFromFile]. Round-trips through [toYamlString].
final class DispatcherConfig {
  /// Directory of shipped, well-known procedures. Defaults to
  /// [defaultSystemScriptsPath] (`scripts/system`).
  final String systemScriptsPath;

  /// Directory of user-authored procedures, or `null` when the deployment
  /// ships none. Defaults to `null` (absent) — a missing `scripts/user/` is
  /// normal, not an error (matches `DiskProcedureStore`'s optional `userDir`).
  final String? userScriptsPath;

  /// The foreground FIFO queue depth the `RunCoordinator` admits behind a busy
  /// foreground slot. Defaults to [defaultForegroundQueueDepth] (4). Zero
  /// disables queueing; negative is rejected.
  final int foregroundQueueDepth;

  /// The coordinator's hard step deadline — the wall-clock cross-check of the
  /// engine's per-step deadline. Defaults to [defaultDispatcherHardStepDeadline]
  /// (65 s). Must be strictly positive.
  final Duration hardStepDeadline;

  /// Whether the free-time scheduler runs background work when the foreground
  /// is idle (D.33). Defaults to [defaultSchedulerEnabled] (off).
  final bool schedulerEnabled;

  /// Builds a dispatcher configuration. Every field defaults to the prototype
  /// baseline, so `DispatcherConfig()` is the all-defaults configuration.
  ///
  /// Throws [ArgumentError] when [foregroundQueueDepth] is negative (the same
  /// guard `RunCoordinator` enforces) or when [hardStepDeadline] is not
  /// strictly positive (a zero-or-negative deadline would force-yield every
  /// run before it could run).
  DispatcherConfig({
    this.systemScriptsPath = defaultSystemScriptsPath,
    this.userScriptsPath,
    this.foregroundQueueDepth = defaultForegroundQueueDepth,
    this.hardStepDeadline = defaultDispatcherHardStepDeadline,
    this.schedulerEnabled = defaultSchedulerEnabled,
  }) {
    if (foregroundQueueDepth < 0) {
      throw ArgumentError.value(
        foregroundQueueDepth,
        'foregroundQueueDepth',
        'must be zero or greater',
      );
    }
    if (hardStepDeadline <= Duration.zero) {
      throw ArgumentError.value(
        hardStepDeadline,
        'hardStepDeadline',
        'a hard step deadline must be strictly positive',
      );
    }
  }

  /// Parses a dispatcher configuration from a YAML [yamlText].
  ///
  /// An empty/whitespace document — or one with all sections omitted — yields
  /// the all-defaults configuration. Present sections are parsed strictly: a
  /// section or value of the wrong shape (a negative `queue.foregroundDepth`,
  /// a non-positive `deadline.hardStepMs`, a non-boolean `scheduler.enabled`)
  /// throws [DispatcherConfigInvalid].
  static DispatcherConfig fromYamlString(String yamlText) {
    if (yamlText.trim().isEmpty) {
      return DispatcherConfig();
    }
    final Object? doc;
    try {
      doc = loadYaml(yamlText);
    } on YamlException catch (e) {
      throw DispatcherConfigInvalid('config is not valid YAML: ${e.message}');
    }
    if (doc == null) {
      return DispatcherConfig();
    }
    if (doc is! YamlMap) {
      throw const DispatcherConfigInvalid(
        'config must be a mapping of sections',
      );
    }
    return fromYamlMap(doc);
  }

  /// Builds a dispatcher configuration from an already-parsed YAML [map].
  ///
  /// Used by [fromYamlString] and directly testable. Same strictness: present
  /// sections must have the right shape, otherwise [DispatcherConfigInvalid].
  static DispatcherConfig fromYamlMap(YamlMap map) {
    final scripts =
        optionalConfigMap(map, 'scripts', DispatcherConfigInvalid.new);
    final queue = optionalConfigMap(map, 'queue', DispatcherConfigInvalid.new);
    final deadline =
        optionalConfigMap(map, 'deadline', DispatcherConfigInvalid.new);
    final scheduler =
        optionalConfigMap(map, 'scheduler', DispatcherConfigInvalid.new);

    final systemPath = scripts == null
        ? defaultSystemScriptsPath
        : optionalConfigString(
              scripts,
              'system',
              'scripts.system',
              DispatcherConfigInvalid.new,
            ) ??
            defaultSystemScriptsPath;
    final userPath = scripts == null
        ? null
        : optionalConfigString(
            scripts,
            'user',
            'scripts.user',
            DispatcherConfigInvalid.new,
          );

    final depth = queue == null
        ? defaultForegroundQueueDepth
        : optionalConfigNonNegativeInt(
              queue,
              'foregroundDepth',
              'queue.foregroundDepth',
              DispatcherConfigInvalid.new,
            ) ??
            defaultForegroundQueueDepth;

    final hardStepMs = deadline == null
        ? defaultDispatcherHardStepDeadline.inMilliseconds
        : optionalConfigPositiveInt(
              deadline,
              'hardStepMs',
              'deadline.hardStepMs',
              DispatcherConfigInvalid.new,
            ) ??
            defaultDispatcherHardStepDeadline.inMilliseconds;

    final enabled = scheduler == null
        ? defaultSchedulerEnabled
        : optionalConfigBool(
              scheduler,
              'enabled',
              'scheduler.enabled',
              DispatcherConfigInvalid.new,
            ) ??
            defaultSchedulerEnabled;

    return DispatcherConfig(
      systemScriptsPath: systemPath,
      userScriptsPath: userPath,
      foregroundQueueDepth: depth,
      hardStepDeadline: Duration(milliseconds: hardStepMs),
      schedulerEnabled: enabled,
    );
  }

  /// Reads and parses the dispatcher configuration at [file].
  ///
  /// A non-existent file yields the all-defaults configuration — an absent
  /// config file means "use the defaults", never an error. Parse problems
  /// throw [DispatcherConfigInvalid].
  static Future<DispatcherConfig> loadFromFile(File file) async {
    if (!await file.exists()) {
      return DispatcherConfig();
    }
    return fromYamlString(await file.readAsString());
  }

  /// Emits this configuration as a YAML document that [fromYamlString] parses
  /// back into an equal [DispatcherConfig].
  ///
  /// Deterministic field order so the output is stable across runs. The
  /// optional `scripts.user` line is emitted only when [userScriptsPath] is
  /// set.
  String toYamlString() {
    final buffer = StringBuffer()
      ..writeln('scripts:')
      ..writeln('  system: ${yamlScalar(systemScriptsPath)}');
    if (userScriptsPath != null) {
      buffer.writeln('  user: ${yamlScalar(userScriptsPath!)}');
    }
    buffer
      ..writeln('queue:')
      ..writeln('  foregroundDepth: $foregroundQueueDepth')
      ..writeln('deadline:')
      ..writeln('  hardStepMs: ${hardStepDeadline.inMilliseconds}')
      ..writeln('scheduler:')
      ..writeln('  enabled: $schedulerEnabled');
    return buffer.toString();
  }

  /// Returns a copy with the given fields overridden.
  ///
  /// [userScriptsPath] cannot be cleared through this method (a `null`
  /// argument means "keep the current value", matching `EngineConfig.copyWith`).
  DispatcherConfig copyWith({
    String? systemScriptsPath,
    String? userScriptsPath,
    int? foregroundQueueDepth,
    Duration? hardStepDeadline,
    bool? schedulerEnabled,
  }) =>
      DispatcherConfig(
        systemScriptsPath: systemScriptsPath ?? this.systemScriptsPath,
        userScriptsPath: userScriptsPath ?? this.userScriptsPath,
        foregroundQueueDepth: foregroundQueueDepth ?? this.foregroundQueueDepth,
        hardStepDeadline: hardStepDeadline ?? this.hardStepDeadline,
        schedulerEnabled: schedulerEnabled ?? this.schedulerEnabled,
      );

  @override
  bool operator ==(Object other) =>
      other is DispatcherConfig &&
      other.systemScriptsPath == systemScriptsPath &&
      other.userScriptsPath == userScriptsPath &&
      other.foregroundQueueDepth == foregroundQueueDepth &&
      other.hardStepDeadline == hardStepDeadline &&
      other.schedulerEnabled == schedulerEnabled;

  @override
  int get hashCode => Object.hash(
        systemScriptsPath,
        userScriptsPath,
        foregroundQueueDepth,
        hardStepDeadline,
        schedulerEnabled,
      );

  @override
  String toString() => 'DispatcherConfig('
      'systemScriptsPath: $systemScriptsPath, '
      'userScriptsPath: $userScriptsPath, '
      'foregroundQueueDepth: $foregroundQueueDepth, '
      'hardStepDeadline: $hardStepDeadline, '
      'schedulerEnabled: $schedulerEnabled)';
}
