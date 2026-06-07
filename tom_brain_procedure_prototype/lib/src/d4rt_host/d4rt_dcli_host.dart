// D4rtDcliHost — the sandboxed d4rt-DCli host the engine runs procedure
// scripts on (Plan step C.16;
// `tom_brain_procedure_prototype_specification.md` § 4, § 6).
//
// ── What this composes ──────────────────────────────────────────────
//
// The host owns **one** `D4rt` interpreter and layers three things on
// top of it, exactly as the plan's C.16 phrasing requires ("composes
// `tom_d4rt_dcli`'s `D4rtCliApi` with our two bridges + the
// engine-native primitives"):
//
//   1. The two generated bridges (`MemoryBridge`, `SubstrateBridge`),
//      registered via `BrainBridges.register` (C.14). This is the only
//      effect surface a procedure script can touch (PE-1).
//   2. A `D4rtCliApi` (`D4rtCliController`) over the same interpreter.
//      The CLI surface is what the *final* engine will use for the
//      Unix-style commands + VS Code integration described in § 4.1;
//      for the prototype those extras stay disabled (C.17), so the
//      controller is composed but no dcli/unix/vscode bridges are
//      registered — the locked-down default. The controller still gives
//      the host programmatic introspection (`classes()`,
//      `registeredClasses()`, …) and is the seam C.17 flips on.
//   3. The **engine-native primitives** (`runProcedure`, `note`,
//      `yield_if_foreground_waiting`; C.19–C.22). Those do not exist at
//      C.16, so the host exposes an [installNativePrimitives] seam that
//      runs against the interpreter right after the bridges register.
//      C.19 supplies the callback; until then the prototype passes none.
//
// ── How a procedure reaches the bridges (Q-C.15.1 resolved) ─────────
//
// The procedure entry point the spec mandates is
// `run(ProcedureInputs inputs)` (§ 4.3) — a single typed argument with
// no room for the bridges. So the bridges are injected as **named
// globals** (`mem`, `sub`) via `D4rt.registerGlobalVariable`, keyed to
// the two bridge library URIs (`BrainBridges.memoryLibrary` /
// `…substrateLibrary`). A script that `import`s a bridge library sees
// the matching global and can call `mem.recall(...)` / `sub.llm(...)`
// directly, leaving the entry point free to carry only `inputs`. This
// is the host-wiring convention C.15's round-trip test deliberately
// left open (it injected the bridges positionally to stay
// convention-agnostic); C.16 picks named globals because it is the only
// option compatible with the `run(ProcedureInputs)` signature.
//
// The stack surface (Q-C.12.2) stays flat: `mem.stackList()`,
// `mem.stackPush(...)`, etc. A dotted `stack.` namespace would need a
// nested bridge object the generator does not emit; flat method names
// are what the generated `MemoryBridge` bridge exposes, so flat is the
// host-facing surface.
//
// ── Sandbox posture (C.16 baseline + C.17 opt-in) ───────────────────
//
// Registering *only* `BrainBridges` (no dcli/unix/vscode bridge) means
// a procedure script has no filesystem, process, or network reach
// except through the bridged primitives — the prototype's locked
// default. C.16 establishes that baseline.
//
// C.17 adds the **opt-in switch**. The host takes a [SandboxConfig] with
// two independent flags (`enableUnixCommands`, `enableVsCodeIntegration`)
// and, for each flag that is on, runs the matching surface installer
// against the interpreter at boot. Both flags are off in
// [SandboxConfig.locked] — the only configuration the prototype's
// `answer_with_memory_v1` script ever runs under (§ 6). The concrete
// surface installers (which `tom_d4rt_dcli` bridges to register) are a
// higher-level wiring decision the engine config (C.42) supplies; the
// host only owns the *switch*, not the choice of bridges, so it never
// pulls the dcli process/network/filesystem surface into the prototype
// binary it does not use.
//
// Enabling a flag without supplying its installer is a misconfiguration:
// the host throws at construction rather than booting a switch that is
// "on" but silently grants nothing.
//
// The validator's source-level sandbox check (a script importing an SDK
// library is rejected regardless of host configuration) is C.27–C.30;
// both layers must agree before any effect is permitted (PE-1).

import 'package:tom_d4rt/d4rt.dart';
import 'package:tom_d4rt_dcli/tom_d4rt_cli_api.dart';

import '../bridges/brain_bridges_registrar.dart';
import '../bridges/mcp_bridge.dart';
import '../bridges/memory_bridge.dart';
import '../bridges/substrate_bridge.dart';
import '../bridges/tool_bridge.dart';
import '../config/sandbox_config.dart';
import 'procedure_parse_exception.dart';

/// Signature for the engine-native-primitive installer (C.19–C.22).
///
/// Invoked once at host boot, after the bridges are registered, with the
/// host's [D4rt] interpreter. C.19 will register `runProcedure`, `note`,
/// and `yield_if_foreground_waiting` here; at C.16 the prototype passes
/// `null` (no native primitives exist yet).
typedef NativePrimitiveInstaller = void Function(D4rt interpreter);

/// Signature for an optional sandbox-surface installer (C.17).
///
/// Invoked once at host boot — only when the matching [SandboxConfig]
/// switch is on — with the host's [D4rt] interpreter, to register the
/// extra effect surface (`tom_d4rt_dcli`'s Unix-command bridges, or the
/// `tom_vscode_scripting_api` bridge). The choice of which bridges
/// constitute each surface is the caller's (engine config, C.42); the
/// host only decides *whether* to run the installer based on the switch.
typedef SandboxSurfaceInstaller = void Function(D4rt interpreter);

/// The sandboxed d4rt-DCli host a procedure script runs on.
///
/// Composes a single [D4rt] interpreter with the two brain bridges, a
/// [D4rtCliApi] surface, and the engine-native-primitive seam. Boots
/// eagerly in the constructor: bridge registration and global injection
/// are synchronous, so a constructed host is immediately runnable.
///
/// The host is the C.16 deliverable; the engine (`ProcedureEngine`,
/// C.38–C.41) drives it, the validator (C.27–C.30) gates what reaches
/// it, and the recorder (C.31–C.33) observes the bridged calls it makes.
final class D4rtDcliHost {
  /// Boots a host over [memoryBridge] and [substrateBridge].
  ///
  /// [dataDirectory] is the CLI surface's data/working directory. The
  /// prototype's procedure run never touches the filesystem (it executes
  /// from a source string and the FS bridges are not registered), so the
  /// value only labels the composed [D4rtCliApi]; it defaults to a
  /// neutral placeholder and can be overridden by callers that enable
  /// the Unix surface at C.17.
  ///
  /// [installNativePrimitives], when supplied, runs against the
  /// interpreter immediately after the bridges register — the C.19 seam.
  ///
  /// [sandbox] selects which optional effect surfaces a procedure may
  /// reach (C.17). It defaults to [SandboxConfig.locked] — neither the
  /// Unix-command surface nor the VS Code surface is registered, which is
  /// the only configuration the prototype's `answer_with_memory_v1`
  /// script runs under (§ 6). When [sandbox] enables a surface, the
  /// matching installer ([installUnixCommands] /
  /// [installVsCodeIntegration]) **must** be supplied; otherwise the host
  /// throws a [StateError] at construction rather than booting a switch
  /// that is on but grants nothing.
  D4rtDcliHost({
    required this.memoryBridge,
    required this.substrateBridge,
    this.toolBridge,
    this.mcpBridge,
    String dataDirectory = _defaultDataDirectory,
    NativePrimitiveInstaller? installNativePrimitives,
    this.sandbox = const SandboxConfig.locked(),
    SandboxSurfaceInstaller? installUnixCommands,
    SandboxSurfaceInstaller? installVsCodeIntegration,
  })  : _interpreter = D4rt(),
        _toolName = _hostToolName {
    _boot(
      dataDirectory,
      installNativePrimitives,
      installUnixCommands,
      installVsCodeIntegration,
    );
  }

  /// The d4rt global name the [MemoryBridge] instance is bound to.
  static const String memoryGlobal = 'mem';

  /// The d4rt global name the [SubstrateBridge] instance is bound to.
  static const String substrateGlobal = 'sub';

  /// The d4rt global name the [ToolBridge] instance is bound to, when one is
  /// supplied (Extension F step 6).
  static const String toolGlobal = 'tool';

  /// The d4rt global name the [McpBridge] instance is bound to, when one is
  /// supplied (Extension F step 8).
  static const String mcpGlobal = 'mcp';

  /// Tool label the composed [D4rtCliApi] reports (`toolName`).
  static const String _hostToolName = 'TomBrainEngine';

  /// Neutral default for the CLI surface's data directory. The prototype
  /// never reads or writes it (the FS bridges are not registered); it is
  /// only a label on the composed controller.
  static const String _defaultDataDirectory = '/tom-brain-engine';

  /// The memory bridge injected as the [memoryGlobal] global.
  final MemoryBridge memoryBridge;

  /// The substrate bridge injected as the [substrateGlobal] global.
  final SubstrateBridge substrateBridge;

  /// The tool bridge injected as the [toolGlobal] global, or `null` when the
  /// host runs without the `tool.list` / `tool.invoke` surface (Extension F
  /// step 6). Optional because the prototype's `answer_with_memory_v1`
  /// reaches memory + substrate only; a host that runs the scripted LLM loop
  /// supplies one.
  final ToolBridge? toolBridge;

  /// The MCP bridge injected as the [mcpGlobal] global, or `null` when the
  /// host runs without the `mcp.servers` / `mcp.list` / `mcp.call` surface
  /// (Extension F step 8). Optional because the prototype's
  /// `answer_with_memory_v1` reaches memory + substrate only; a host whose
  /// procedures call out to MCP servers supplies one.
  final McpBridge? mcpBridge;

  /// The sandbox switches this host booted under (C.17). Defaults to
  /// [SandboxConfig.locked] — the prototype's only configuration.
  final SandboxConfig sandbox;

  final D4rt _interpreter;
  final String _toolName;
  late final D4rtCliApi _cli;

  /// The interpreter every bridged call and procedure run executes on.
  ///
  /// Exposed for the engine + recorder (C.31–C.33) and for tests; the
  /// validator gates source *before* it reaches here.
  D4rt get interpreter => _interpreter;

  /// The composed [D4rtCliApi] surface, used for host-side introspection
  /// (`classes()`, `registeredClasses()`, …). Whether the Unix-command
  /// and VS Code surfaces are *registered* on the interpreter is governed
  /// by [sandbox] (C.17); both are off under the prototype default.
  D4rtCliApi get cli => _cli;

  void _boot(
    String dataDirectory,
    NativePrimitiveInstaller? installNativePrimitives,
    SandboxSurfaceInstaller? installUnixCommands,
    SandboxSurfaceInstaller? installVsCodeIntegration,
  ) {
    // 1. Bridges: the only effect surface a procedure can touch by
    //    default (PE-1).
    BrainBridges.register(_interpreter);

    // 2. Inject the bridge instances as named globals under their bridge
    //    library URIs, so an importing script sees `mem` / `sub`.
    _interpreter.registerGlobalVariable(
      memoryGlobal,
      memoryBridge,
      BrainBridges.memoryLibrary,
    );
    _interpreter.registerGlobalVariable(
      substrateGlobal,
      substrateBridge,
      BrainBridges.substrateLibrary,
    );

    // 2b. The tool bridge, when the host runs the scripted LLM loop
    //     (Extension F step 6). Injected under its bridge library URI so an
    //     importing script sees the `tool` global. Optional — the
    //     prototype's `answer_with_memory_v1` runs without it.
    final tools = toolBridge;
    if (tools != null) {
      _interpreter.registerGlobalVariable(
        toolGlobal,
        tools,
        BrainBridges.toolLibrary,
      );
    }

    // 2c. The MCP bridge, when the host's procedures call out to MCP servers
    //     (Extension F step 8). Injected under its bridge library URI so an
    //     importing script sees the `mcp` global. Optional — the prototype's
    //     `answer_with_memory_v1` runs without it.
    final mcp = mcpBridge;
    if (mcp != null) {
      _interpreter.registerGlobalVariable(
        mcpGlobal,
        mcp,
        BrainBridges.mcpLibrary,
      );
    }

    // 3. Engine-native primitives (C.19–C.22 fill the seam).
    installNativePrimitives?.call(_interpreter);

    // 4. Opt-in sandbox surfaces (C.17). Each switch, when on, requires
    //    its installer; an enabled switch with no installer is a
    //    misconfiguration we refuse loudly. Both switches are off under
    //    `SandboxConfig.locked` — the prototype's default — so neither
    //    installer runs and only `BrainBridges` reaches a script.
    if (sandbox.enableUnixCommands) {
      _requireInstaller(
        installUnixCommands,
        switchName: 'enableUnixCommands',
        installerName: 'installUnixCommands',
      ).call(_interpreter);
    }
    if (sandbox.enableVsCodeIntegration) {
      _requireInstaller(
        installVsCodeIntegration,
        switchName: 'enableVsCodeIntegration',
        installerName: 'installVsCodeIntegration',
      ).call(_interpreter);
    }

    // 5. Compose the D4rtCliApi over the same interpreter for host-side
    //    introspection. The CLI controller does not itself register the
    //    Unix/VS Code bridges — those come (when enabled) from the
    //    installers above.
    _cli = D4rtCliController(
      d4rt: _interpreter,
      state: CliState(dataDirectory: dataDirectory),
      toolName: _toolName,
    );
  }

  /// Returns [installer] or throws a [StateError] naming the switch that
  /// was enabled without a matching surface installer.
  static SandboxSurfaceInstaller _requireInstaller(
    SandboxSurfaceInstaller? installer, {
    required String switchName,
    required String installerName,
  }) {
    if (installer == null) {
      throw StateError(
        'SandboxConfig.$switchName is enabled but no $installerName was '
        'supplied. Enabling a sandbox surface requires its installer.',
      );
    }
    return installer;
  }

  /// Runs a procedure [source] and returns the entry point's result.
  ///
  /// The bridges reach the script through the injected `mem` / `sub`
  /// globals; [inputs] are passed positionally to the [entryPoint]
  /// function (default `run`, the spec entry point — § 4.3). Every
  /// bridged call is async, so the entry point is awaited.
  ///
  /// This is the raw execution seam. Header parsing, sandbox validation,
  /// the `ProcedureInputs`/`ProcedureResult` contract, run recording,
  /// and preemption checkpoints are layered on by later Phase C steps
  /// (validator C.27–C.30, recorder C.31–C.33, engine API C.38–C.41);
  /// the host itself only boots the interpreter and runs source on it.
  ///
  /// A source that fails to parse surfaces as a [ProcedureSourceParseException]
  /// (`procedure.parse.failed`, § 10.4) rather than the interpreter's own
  /// exception type: the host is the authority on syntax (the static validator
  /// gates imports/identifiers only), and a parse failure must be
  /// distinguishable from a runtime crash so the engine records the right
  /// failure class and the version-chain fallback is not wrongly stepped
  /// (Q-C.46.1). This is the single seam that knows d4rt's concrete
  /// parse-error type.
  Future<Object?> run(
    String source, {
    String entryPoint = 'run',
    List<Object?> inputs = const <Object?>[],
  }) async {
    try {
      return await _interpreter.execute(
        source: source,
        name: entryPoint,
        positionalArgs: inputs,
      );
    } on SourceCodeD4rtException catch (error) {
      // The source did not parse: the procedure never ran. Re-raise as the
      // host-owned parse exception so callers classify it as
      // `procedure.parse.failed`, not a runtime crash.
      throw ProcedureSourceParseException(error.message);
    }
  }
}
