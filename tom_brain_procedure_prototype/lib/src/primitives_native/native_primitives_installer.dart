// Native-primitive installer — wires the engine-native primitives into a
// D4rt interpreter through the host's `installNativePrimitives` seam
// (Plan step C.19; the seam is the C.16 `NativePrimitiveInstaller`).
//
// C.19 wired the first primitive: the top-level `runProcedure`. C.20 added
// `note`; C.21 adds `yield_if_foreground_waiting`. The installer is the
// d4rt-facing half of the native primitives; the recursion-capped logic
// lives in [RunProcedurePrimitive], the note logic in [NotePrimitive], and
// the cooperative-checkpoint logic in [YieldPrimitive] (which reads the
// shared `PreemptionState`).
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
//
// `note`'s payload, by contrast, is an ordinary d4rt map literal the
// script builds in-place (`note('automation_candidate', {'why': …})`).
// The installer coerces that `Map` into a `Map<String, Object?>` at the
// boundary, validating that every key is a String.

import 'package:tom_d4rt/d4rt.dart';

import '../api/procedure_inputs.dart';
import '../api/procedure_result.dart';
import 'note_primitive.dart';
import 'run_procedure_primitive.dart';
import 'yield_primitive.dart';

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

/// The d4rt global name the `note` primitive is bound to.
const String noteName = 'note';

/// The d4rt global name the cooperative-preemption checkpoint is bound to.
///
/// Spec-cased `snake_case` (`yield_if_foreground_waiting`) per § 5.1; a
/// background script reaches it as a bare call after importing
/// [engineNativeLibrary].
const String yieldIfForegroundWaitingName = 'yield_if_foreground_waiting';

/// Builds an installer that registers the engine-native primitives backed
/// by [runProcedurePrimitive], [notePrimitive], and [yieldPrimitive] onto a
/// D4rt interpreter.
///
/// Returned as a `void Function(D4rt)` so it slots directly into the
/// host's `installNativePrimitives` constructor parameter (C.16). Run once
/// at host boot, after the bridges register.
void Function(D4rt) nativePrimitivesInstaller({
  required RunProcedurePrimitive runProcedurePrimitive,
  required NotePrimitive notePrimitive,
  required YieldPrimitive yieldPrimitive,
}) {
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

    interpreter.registertopLevelFunction(
      noteName,
      (
        InterpreterVisitor visitor,
        List<Object?> arguments,
        Map<String, Object?> namedArguments,
        List<RuntimeType>? typeArguments,
      ) =>
          _invokeNote(notePrimitive, arguments),
      engineNativeLibrary,
      signature: 'void note(String category, Map<String, Object?> payload)',
    );

    interpreter.registertopLevelFunction(
      yieldIfForegroundWaitingName,
      (
        InterpreterVisitor visitor,
        List<Object?> arguments,
        Map<String, Object?> namedArguments,
        List<RuntimeType>? typeArguments,
      ) =>
          yieldPrimitive.yieldIfForegroundWaiting(),
      engineNativeLibrary,
      signature: 'Future<void> yield_if_foreground_waiting()',
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

/// Marshals a d4rt `note(...)` call onto [primitive].
///
/// Positional args: `[0]` the category (String), `[1]` the payload (a
/// d4rt map literal). The payload is coerced into a `Map<String, Object?>`
/// — every key must be a String. Returns `null`: `note` is fire-and-forget
/// from the script's point of view (it appends to the trail and yields no
/// value the script consumes).
Object? _invokeNote(
  NotePrimitive primitive,
  List<Object?> arguments,
) {
  if (arguments.length < 2) {
    throw ArgumentError(
      'note expects (String category, Map<String, Object?> payload); '
      'got ${arguments.length} positional argument(s)',
    );
  }

  final category = arguments[0];
  if (category is! String) {
    throw ArgumentError.value(
      category,
      'category',
      'note category must be a String',
    );
  }

  final payloadArg = arguments[1];
  if (payloadArg is! Map) {
    throw ArgumentError.value(
      payloadArg,
      'payload',
      'note payload must be a Map',
    );
  }

  final payload = <String, Object?>{};
  payloadArg.forEach((Object? key, Object? value) {
    if (key is! String) {
      throw ArgumentError.value(
        key,
        'payload key',
        'note payload keys must be Strings',
      );
    }
    payload[key] = value;
  });

  primitive.note(category, payload);
  return null;
}
