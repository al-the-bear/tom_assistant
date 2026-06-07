// vsCodeScriptingInstaller — the `installVsCodeIntegration` surface installer
// for the `vscode.call` bridge (`prototype_tools_mcp_extension_plan.md`
// step 14; `tom_brain_procedure_prototype_specification.md` § 21.9, § 6).
//
// The two-switch installer-seam model (§ 6) splits ownership: the host
// (`D4rtDcliHost`) owns the `enableVsCodeIntegration` *switch* and refuses an
// on-switch with no installer; the *installer* — which bridges constitute the
// VS Code surface — is supplied externally (the engine config, C.42). This
// factory is that installer for the step-14 surface: it registers a
// caller-built [VsCodeScriptingBridge] under the host's `vscode` global so an
// importing procedure script reaches it (§ 21.9).
//
// ── Why the factory lives in `d4rt_host/`, not `bridges/` ───────────
//
// The installer references both the bridge (`bridges/`) and the host's
// `vsCodeScriptingGlobal` + library URI (`d4rt_host/` already imports
// `bridges/`). Putting it in `bridges/` would make `bridges/` import
// `d4rt_host/`, inverting the existing host→bridges dependency arrow into a
// cycle. It belongs on the host side of that arrow — the side that already
// knows both the bridge and the global it binds to.

import 'package:tom_d4rt/d4rt.dart';

import '../bridges/brain_bridges_registrar.dart';
import '../bridges/vscode_scripting_bridge.dart';
import 'd4rt_dcli_host.dart';

/// Builds the `installVsCodeIntegration` installer that registers [bridge] as
/// the host's `vscode` global (§ 21.9).
///
/// Pass the result to `D4rtDcliHost(installVsCodeIntegration: …)` together with
/// `SandboxConfig(enableVsCodeIntegration: true)`. The host runs it once at
/// boot, binding `vscode` under [BrainBridges.vscodeScriptingLibrary] so a
/// procedure that imports that library can call
/// `vscode.call(api, method, args)`. With the switch off (the locked default)
/// the installer is never built or run and the global stays absent.
SandboxSurfaceInstaller vsCodeScriptingInstaller(VsCodeScriptingBridge bridge) =>
    (D4rt interpreter) => interpreter.registerGlobalVariable(
          D4rtDcliHost.vsCodeScriptingGlobal,
          bridge,
          BrainBridges.vscodeScriptingLibrary,
        );
