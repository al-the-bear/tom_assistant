// EngineConfig — the engine's YAML-loadable configuration (Plan step
// C.42; `tom_brain_procedure_specification.md` § 13).
//
// ── What it carries ─────────────────────────────────────────────────
//
// Spec § 13 names exactly four engine knobs:
//
//   • the `scripts/system/` path (well-known, shipped procedures — the
//     permanent safety net, PE-6),
//   • the `scripts/user/` path (user-authored procedures; optional),
//   • the sandbox switches (`SandboxConfig` from C.17 — the two opt-in
//     effect surfaces, both off by default, § 6 / § 13),
//   • the deadline defaults (the hard per-step wall-clock cap the engine
//     and `StepDeadline` use — definition § 7.1: "configurable; default
//     60 s wall clock").
//
// `EngineConfig` is the value object that bundles those four; its YAML
// loader turns an operator-supplied document into the object the
// dispatcher feeds the `DiskProcedureStore` (the two paths), the
// `D4rtDcliHost` (the sandbox switches), and the `ProcedureEngine` (the
// step deadline).
//
// ── YAML shape ──────────────────────────────────────────────────────
//
//   scripts:
//     system: scripts/system     # required-by-default; defaults below
//     user: scripts/user         # optional — omit when no user scripts
//   sandbox:
//     enableUnixCommands: false
//     enableVsCodeIntegration: false
//   deadline:
//     stepMs: 60000              # hard per-step wall-clock cap
//
// Every section is optional: an empty or absent document yields the
// all-defaults configuration (`scripts/system`, no user dir, locked
// sandbox, 60 s deadline). Only *present* sections with the wrong shape
// are rejected — a missing section is "use the default", never an error.
//
// ── Why the `yaml` package, not a `tom_build_base` loader ───────────
//
// Spec § 13 says "via `tom_build_base` YAML loaders". The prototype does
// not depend on `tom_build_base` (it is not in the C.7 dependency set,
// and the dependency-surface test locks that set), and it already parses
// every other YAML it reads — the procedure header (C.24) — with the
// canonical `yaml` package directly. For consistency and to keep the
// dependency surface narrow, the engine config uses the same `yaml`
// package and the same "funnel every structural problem through one
// typed error" discipline (`EngineConfigInvalid`, mirroring
// `ProcedureHeaderInvalid`). The divergence from the spec wording is
// logged as Q-C.42.1; the loader contract (paths + switches + deadline
// from YAML) is identical either way.

library;

import 'dart:io';

import 'package:yaml/yaml.dart';

import '../preemption/step_deadline.dart' show defaultStepDeadline;
import 'engine_config_invalid.dart';
import 'sandbox_config.dart';
import 'yaml_field_readers.dart';

/// The default directory of shipped, well-known procedures
/// (`scripts/system/`) — the permanent safety net (PE-6). Relative to the
/// engine's working directory unless the config overrides it absolutely.
const String defaultSystemScriptsPath = 'scripts/system';

/// The conventional directory of user-authored procedures
/// (`scripts/user/`). Not a default *value* on [EngineConfig] (the user
/// dir is optional and defaults to absent); named here so an operator and
/// the loader agree on the conventional location.
const String defaultUserScriptsPath = 'scripts/user';

/// The engine's loadable configuration: the two procedure-script paths,
/// the sandbox switches, and the hard per-step deadline.
///
/// Immutable value object. Build one directly for tests/defaults, or load
/// one from YAML with [EngineConfig.fromYamlString] /
/// [EngineConfig.loadFromFile]. Round-trips through [toYamlString].
final class EngineConfig {
  /// Directory of shipped, well-known procedures. Defaults to
  /// [defaultSystemScriptsPath].
  final String systemScriptsPath;

  /// Directory of user-authored procedures, or `null` when the
  /// deployment ships none. Defaults to `null` (absent) — a missing
  /// `scripts/user/` is normal, not an error (matches
  /// `DiskProcedureStore`'s optional `userDir`).
  final String? userScriptsPath;

  /// The host sandbox switches (the two opt-in effect surfaces). Defaults
  /// to [SandboxConfig.locked] — neither surface registered.
  final SandboxConfig sandbox;

  /// The hard per-step wall-clock cap the engine arms for every step.
  /// Defaults to [defaultStepDeadline] (60 s).
  final Duration stepDeadline;

  /// Builds an engine configuration. Every field defaults to the
  /// prototype baseline, so `const EngineConfig()` is the all-defaults
  /// configuration.
  ///
  /// Throws [ArgumentError] when [stepDeadline] is not strictly positive —
  /// a zero-or-negative cap would force-yield every step before it could
  /// run (the same guard [StepDeadline] enforces).
  EngineConfig({
    this.systemScriptsPath = defaultSystemScriptsPath,
    this.userScriptsPath,
    this.sandbox = const SandboxConfig.locked(),
    this.stepDeadline = defaultStepDeadline,
  }) {
    if (stepDeadline <= Duration.zero) {
      throw ArgumentError.value(
        stepDeadline,
        'stepDeadline',
        'a step deadline must be strictly positive',
      );
    }
  }

  /// Parses an engine configuration from a YAML [yamlText].
  ///
  /// An empty/whitespace document — or one with all sections omitted —
  /// yields the all-defaults configuration. Present sections are parsed
  /// strictly: a section or value of the wrong shape (or a non-positive
  /// `deadline.stepMs`) throws [EngineConfigInvalid].
  static EngineConfig fromYamlString(String yamlText) {
    if (yamlText.trim().isEmpty) {
      return EngineConfig();
    }
    final Object? doc;
    try {
      doc = loadYaml(yamlText);
    } on YamlException catch (e) {
      throw EngineConfigInvalid('config is not valid YAML: ${e.message}');
    }
    if (doc == null) {
      return EngineConfig();
    }
    if (doc is! YamlMap) {
      throw const EngineConfigInvalid('config must be a mapping of sections');
    }
    return fromYamlMap(doc);
  }

  /// Builds an engine configuration from an already-parsed YAML [map].
  ///
  /// Used by [fromYamlString] and directly testable. Same strictness:
  /// present sections must have the right shape, otherwise
  /// [EngineConfigInvalid].
  static EngineConfig fromYamlMap(YamlMap map) {
    final scripts = optionalConfigMap(map, 'scripts', EngineConfigInvalid.new);
    final sandbox = optionalConfigMap(map, 'sandbox', EngineConfigInvalid.new);
    final deadline =
        optionalConfigMap(map, 'deadline', EngineConfigInvalid.new);

    final systemPath = scripts == null
        ? defaultSystemScriptsPath
        : optionalConfigString(
              scripts,
              'system',
              'scripts.system',
              EngineConfigInvalid.new,
            ) ??
            defaultSystemScriptsPath;
    final userPath = scripts == null
        ? null
        : optionalConfigString(
            scripts,
            'user',
            'scripts.user',
            EngineConfigInvalid.new,
          );

    final sandboxConfig = sandbox == null
        ? const SandboxConfig.locked()
        : SandboxConfig(
            enableUnixCommands: optionalConfigBool(
                  sandbox,
                  'enableUnixCommands',
                  'sandbox.enableUnixCommands',
                  EngineConfigInvalid.new,
                ) ??
                false,
            enableVsCodeIntegration: optionalConfigBool(
                  sandbox,
                  'enableVsCodeIntegration',
                  'sandbox.enableVsCodeIntegration',
                  EngineConfigInvalid.new,
                ) ??
                false,
          );

    final stepMs = deadline == null
        ? defaultStepDeadline.inMilliseconds
        : optionalConfigPositiveInt(
              deadline,
              'stepMs',
              'deadline.stepMs',
              EngineConfigInvalid.new,
            ) ??
            defaultStepDeadline.inMilliseconds;

    return EngineConfig(
      systemScriptsPath: systemPath,
      userScriptsPath: userPath,
      sandbox: sandboxConfig,
      stepDeadline: Duration(milliseconds: stepMs),
    );
  }

  /// Reads and parses the engine configuration at [file].
  ///
  /// A non-existent file yields the all-defaults configuration — an
  /// absent config file means "use the defaults", never an error. Parse
  /// problems throw [EngineConfigInvalid].
  static Future<EngineConfig> loadFromFile(File file) async {
    if (!await file.exists()) {
      return EngineConfig();
    }
    return fromYamlString(await file.readAsString());
  }

  /// Emits this configuration as a YAML document that
  /// [fromYamlString] parses back into an equal [EngineConfig].
  ///
  /// Deterministic field order so the output is stable across runs. The
  /// optional `scripts.user` line is emitted only when [userScriptsPath]
  /// is set.
  String toYamlString() {
    final buffer = StringBuffer()
      ..writeln('scripts:')
      ..writeln('  system: ${yamlScalar(systemScriptsPath)}');
    if (userScriptsPath != null) {
      buffer.writeln('  user: ${yamlScalar(userScriptsPath!)}');
    }
    buffer
      ..writeln('sandbox:')
      ..writeln('  enableUnixCommands: ${sandbox.enableUnixCommands}')
      ..writeln('  enableVsCodeIntegration: ${sandbox.enableVsCodeIntegration}')
      ..writeln('deadline:')
      ..writeln('  stepMs: ${stepDeadline.inMilliseconds}');
    return buffer.toString();
  }

  /// Returns a copy with the given fields overridden.
  EngineConfig copyWith({
    String? systemScriptsPath,
    String? userScriptsPath,
    SandboxConfig? sandbox,
    Duration? stepDeadline,
  }) =>
      EngineConfig(
        systemScriptsPath: systemScriptsPath ?? this.systemScriptsPath,
        userScriptsPath: userScriptsPath ?? this.userScriptsPath,
        sandbox: sandbox ?? this.sandbox,
        stepDeadline: stepDeadline ?? this.stepDeadline,
      );

  @override
  bool operator ==(Object other) =>
      other is EngineConfig &&
      other.systemScriptsPath == systemScriptsPath &&
      other.userScriptsPath == userScriptsPath &&
      other.sandbox == sandbox &&
      other.stepDeadline == stepDeadline;

  @override
  int get hashCode =>
      Object.hash(systemScriptsPath, userScriptsPath, sandbox, stepDeadline);

  @override
  String toString() => 'EngineConfig('
      'systemScriptsPath: $systemScriptsPath, '
      'userScriptsPath: $userScriptsPath, '
      'sandbox: $sandbox, '
      'stepDeadline: $stepDeadline)';
}
