// SandboxConfig — the host's sandbox switches (Plan step C.17;
// `tom_brain_procedure_prototype_specification.md` § 6, § 13).
//
// ── What this controls ──────────────────────────────────────────────
//
// `D4rtDcliHost` (C.16) boots with exactly one effect surface registered:
// the two brain bridges (`MemoryBridge`, `SubstrateBridge`). That is the
// locked-down default — a procedure has no filesystem, process, or
// network reach except through the bridged primitive API (PE-1).
//
// The final engine, however, will need the two *extra* surfaces
// `tom_d4rt_dcli` makes available (§ 4.1):
//
//   • **Unix-style commands** — the `dcli`/`path` command surface
//     (`cd`, `ls`, process execution, …).
//   • **VS Code integration** — the `tom_vscode_scripting_api` bridge,
//     available only when the engine is colocated with a VS Code host.
//
// Per the spec these are **opt-in only**, flipped on by the dispatcher
// (via the engine config, C.42) when a caller explicitly asks for them.
// For the prototype's one real script (`answer_with_memory_v1`) **both
// stay disabled** — it needs neither (§ 6). `SandboxConfig` is the value
// object that carries the two switches; `SandboxConfig.locked()` is the
// prototype default.
//
// ── Why two independent switches, not a single bool ─────────────────
//
// The two surfaces are independently sensitive: Unix commands grant
// process + filesystem reach; the VS Code bridge grants editor-host
// reach that is only meaningful (and only present) when colocated with
// VS Code. A deployment may legitimately want one without the other, so
// they are modelled as two flags rather than one "unrestricted" bit.

library;

/// The host's sandbox switches — which optional effect surfaces a
/// procedure script may reach beyond the locked-down bridged primitive
/// API.
///
/// Both switches default to **off**. The prototype runs every procedure
/// under [SandboxConfig.locked]; the opt-in path exists so the final
/// engine (and its YAML config, C.42) can grant the Unix or VS Code
/// surface to callers that explicitly ask for it.
///
/// A [D4rtDcliHost] that is given an enabled switch must also be given
/// the matching surface installer; see the host's constructor.
class SandboxConfig {
  /// Creates a sandbox configuration. Both surfaces default to disabled.
  const SandboxConfig({
    this.enableUnixCommands = false,
    this.enableVsCodeIntegration = false,
  });

  /// The locked-down default: neither extra surface is registered. This
  /// is the only configuration the prototype's `answer_with_memory_v1`
  /// script ever runs under (§ 6).
  const SandboxConfig.locked()
      : enableUnixCommands = false,
        enableVsCodeIntegration = false;

  /// Whether the Unix-style command surface (the `dcli`/`path` command
  /// bridges — `cd`, `ls`, process execution, …) is registered on the
  /// host interpreter.
  final bool enableUnixCommands;

  /// Whether the VS Code integration surface
  /// (`tom_vscode_scripting_api`) is registered on the host interpreter.
  /// Only meaningful when the engine is colocated with a VS Code host.
  final bool enableVsCodeIntegration;

  /// Whether any optional surface is enabled. `false` for
  /// [SandboxConfig.locked].
  bool get isLocked => !enableUnixCommands && !enableVsCodeIntegration;

  /// Returns a copy with the given switches overridden.
  SandboxConfig copyWith({
    bool? enableUnixCommands,
    bool? enableVsCodeIntegration,
  }) =>
      SandboxConfig(
        enableUnixCommands: enableUnixCommands ?? this.enableUnixCommands,
        enableVsCodeIntegration:
            enableVsCodeIntegration ?? this.enableVsCodeIntegration,
      );

  @override
  bool operator ==(Object other) =>
      other is SandboxConfig &&
      other.enableUnixCommands == enableUnixCommands &&
      other.enableVsCodeIntegration == enableVsCodeIntegration;

  @override
  int get hashCode => Object.hash(enableUnixCommands, enableVsCodeIntegration);

  @override
  String toString() => 'SandboxConfig('
      'enableUnixCommands: $enableUnixCommands, '
      'enableVsCodeIntegration: $enableVsCodeIntegration)';
}
