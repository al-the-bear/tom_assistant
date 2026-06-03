// Barrel for the `d4rt_host/` module (Plan step C.8).
//
// Owns the sandboxed d4rt-DCli host described in
// `tom_brain_procedure_prototype_specification.md` § 4 and Plan steps
// C.16–C.18:
//
//   - `D4rtDcliHost` — composes `tom_d4rt_dcli`'s `D4rtCliApi` with the
//     two generated bridges (`bridges/`) and the engine-native
//     primitives (`primitives_native/`).
//   - Sandbox configuration: Unix-style commands and VS Code
//     integration are opt-in only; both are disabled for the
//     prototype's `answer_with_memory_v1` script (PE-1: the bridged
//     primitive API is the only surface a procedure can touch).
//
// Wiring across later Phase C steps:
//
//   - C.16 ✅ — `D4rtDcliHost` composition (`d4rt_dcli_host.dart`):
//     one interpreter + the two bridges + a `D4rtCliApi` surface + the
//     engine-native-primitive seam. Bridges reach scripts as the `mem`
//     / `sub` named globals (Q-C.15.1 resolved → named globals).
//   - C.17 ✅ — sandbox switch wiring (`SandboxConfig` + two installer
//     seams). Both switches off under `SandboxConfig.locked` (the
//     prototype default); enabling one without its installer throws.
//   - C.18 — host-boot + bridge-resolution tests.

export 'd4rt_dcli_host.dart';
export 'procedure_parse_exception.dart' show ProcedureSourceParseException;
