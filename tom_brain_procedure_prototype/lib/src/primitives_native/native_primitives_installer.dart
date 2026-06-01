// Native-primitive installer — wires the engine-native primitives into a
// D4rt interpreter through the host's `installNativePrimitives` seam
// (Plan step C.19; the seam is the C.16 `NativePrimitiveInstaller`).
//
// C.19 wires exactly one primitive: the top-level `runProcedure`. `note`
// (C.20) and `yield_if_foreground_waiting` (C.21) register here too as
// they land. The installer is the d4rt-facing half of C.19; the
// recursion-capped logic lives in [RunProcedurePrimitive].
//
// ── Why a top-level function, not a bridge method ───────────────────
//
// The spec writes the engine-native primitives as bare calls —
// `runProcedure(...)`, `note(...)`, `yield_if_foreground_waiting()`
// (§ 5.1) — not as methods on a bridge object (those are the memory /
// substrate re-exports `mem.` / `sub.`). d4rt exposes a native Dart
// function as a bare global via `registertopLevelFunction`; a script
// reaches it by importing [engineNativeLibrary].
//
// ── Opaque pass-through of `ProcedureInputs` / `ProcedureResult` ─────
//
// A procedure forwards the `inputs` it was handed straight to
// `runProcedure(id, inputs)`; it never *constructs* a `ProcedureInputs`
// in-script. So the two types cross the d4rt boundary as opaque host
// objects (passed in by the host, returned back to the host) and need no
// bridging at C.19. The richer engine surface that does construct them
// (`ProcedureEngine`, the sugar aliases) arrives at C.38–C.41.

import 'package:tom_d4rt/d4rt.dart';

import '../api/procedure_inputs.dart';
import '../api/procedure_result.dart';
import 'run_procedure_primitive.dart';

/// The library URI a procedure script imports to reach the engine-native
/// primitives (`runProcedure`, and later `note` /
/// `yield_if_foreground_waiting`).
///
/// Must be a canonical `package:` URI for the same reason the bridge
/// libraries are (`BrainBridges.memoryLibrary`): d4rt's `ModuleLoader`
/// resolves `package:` imports directly against the registered-library
/// map, whereas a relative import needs a filesystem base URI the
/// interpreter does not have at script-execute time.
const String engineNativeLibrary =
    'package:tom_brain_procedure_prototype/src/primitives_native/primitives_native.dart';

/// The d4rt global name the `runProcedure` primitive is bound to.
const String runProcedureName = 'runProcedure';

/// Builds an installer that registers the engine-native primitives backed
/// by [runProcedurePrimitive] onto a D4rt interpreter.
///
/// Returned as a `void Function(D4rt)` so it slots directly into the
/// host's `installNativePrimitives` constructor parameter (C.16). Run once
/// at host boot, after the bridges register.
void Function(D4rt) nativePrimitivesInstaller(
  RunProcedurePrimitive runProcedurePrimitive,
) {
  return (D4rt interpreter) {
    interpreter.registertopLevelFunction(
      runProcedureName,
      (
        InterpreterVisitor visitor,
        List<Object?> arguments,
        Map<String, Object?> namedArguments,
        List<RuntimeType>? typeArguments,
      ) =>
          _invokeRunProcedure(runProcedurePrimitive, arguments, namedArguments),
      engineNativeLibrary,
      signature:
          'Future<ProcedureResult> runProcedure(String id, ProcedureInputs '
          'inputs, {int? version, int depthDelta})',
    );
  };
}

/// Marshals a d4rt `runProcedure(...)` call onto [primitive].
///
/// Positional args: `[0]` the procedure id (String), `[1]` the inputs
/// (opaque [ProcedureInputs]). Named args: `version` (int?), `depthDelta`
/// (int, default 1). Returns the primitive's `Future<ProcedureResult>`,
/// which the script awaits.
Future<ProcedureResult> _invokeRunProcedure(
  RunProcedurePrimitive primitive,
  List<Object?> arguments,
  Map<String, Object?> namedArguments,
) {
  if (arguments.length < 2) {
    throw ArgumentError(
      'runProcedure expects (String id, ProcedureInputs inputs); '
      'got ${arguments.length} positional argument(s)',
    );
  }

  final id = arguments[0];
  if (id is! String) {
    throw ArgumentError.value(
      id,
      'id',
      'runProcedure id must be a String',
    );
  }

  final inputs = arguments[1];
  if (inputs is! ProcedureInputs) {
    throw ArgumentError.value(
      inputs,
      'inputs',
      'runProcedure inputs must be a ProcedureInputs',
    );
  }

  final version = namedArguments['version'];
  if (version != null && version is! int) {
    throw ArgumentError.value(
      version,
      'version',
      'runProcedure version must be an int when supplied',
    );
  }

  final depthDeltaArg = namedArguments['depthDelta'];
  if (depthDeltaArg != null && depthDeltaArg is! int) {
    throw ArgumentError.value(
      depthDeltaArg,
      'depthDelta',
      'runProcedure depthDelta must be an int when supplied',
    );
  }
  final depthDelta = (depthDeltaArg as int?) ?? 1;

  return primitive.runProcedure(
    id,
    inputs,
    version: version as int?,
    depthDelta: depthDelta,
  );
}
