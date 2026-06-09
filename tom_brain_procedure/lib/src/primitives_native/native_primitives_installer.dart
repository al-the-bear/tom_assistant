// Native-primitive installer — wires the engine-native primitives into a
// D4rt interpreter through the host's `installNativePrimitives` seam
// (Plan step C.19; the seam is the C.16 `NativePrimitiveInstaller`).
//
// C.19 wired the first primitive: the top-level `runProcedure`. C.20 added
// `note`; C.21 adds `yield_if_foreground_waiting`; C.40 adds the sugar
// aliases (`think` / `plan` / `create` / `critique` / `decide`) as fixed-id
// projections of the same `runProcedure` primitive. The installer is the
// d4rt-facing half of the native primitives; the recursion-capped logic
// lives in [RunProcedurePrimitive], the note logic in [NotePrimitive], the
// cooperative-checkpoint logic in [YieldPrimitive] (which reads the shared
// `PreemptionState`), and the sugar-verb wiring in `sugar_aliases.dart`.
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
// ── `ProcedureInputs`: pass-through then read-surface bridge ─────────
//
// At C.19 a procedure only ever *forwarded* the `inputs` it was handed to
// `runProcedure(id, inputs)`; it never read a field and never constructed
// one, so `ProcedureInputs` crossed the d4rt boundary as an opaque host
// object that needed no bridging. D.37 is the first body step that *reads*
// an input (`recall(text: …)` needs the inbound prompt), so the installer
// now also registers `ProcedureInputs`'s read surface
// ([registerProcedureInputsBridge]) — a script that imports
// [procedureInputsLibrary] and declares `run(ProcedureInputs inputs)` can
// then do `inputs.get('text')`. `ProcedureResult` is still not bridged
// (Q-C.38.2): the entry point returns a `Map` the engine coerces.
//
// `note`'s payload, by contrast, is an ordinary d4rt map literal the
// script builds in-place (`note('automation_candidate', {'why': …})`).
// The installer coerces that `Map` into a `Map<String, Object?>` at the
// boundary, validating that every key is a String.

import 'package:tom_d4rt/d4rt.dart';

import '../api/procedure_inputs.dart';
import '../api/procedure_result.dart';
import 'emit_primitive.dart';
import 'note_primitive.dart';
import 'procedure_inputs_bridge.dart';
import 'procedure_result_bridge.dart';
import 'run_procedure_primitive.dart';
import 'scripted_llm_sugar.dart';
import 'sugar_aliases.dart';
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
    'package:tom_brain_procedure/src/primitives_native/primitives_native.dart';

/// The d4rt global name the `runProcedure` primitive is bound to.
const String runProcedureName = 'runProcedure';

/// The d4rt global name the `note` primitive is bound to.
const String noteName = 'note';

/// The d4rt global name the `emit` outbound-delta primitive is bound to.
///
/// A procedure reaches it as a bare `await emit(textDelta)` call after
/// importing [engineNativeLibrary]; it streams one increment of the answer
/// back to the originating channel (P1.3 #8, § 11 step 2).
const String emitName = 'emit';

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
  required EmitPrimitive emitPrimitive,
}) {
  return (D4rt interpreter) {
    // The read surface of `ProcedureInputs`, so a body can call
    // `inputs.get('text')` (D.37). Registered alongside the engine-native
    // primitives because the engine always installs both on the same host.
    registerProcedureInputsBridge(interpreter);

    // The read surface of `ProcedureResult`, so a conductor body can inspect
    // a sub-procedure outcome (`result.isSuccess`, `result.output('seeds')`)
    // returned by `runProcedure(...)` — first needed by the
    // `retrieve_for_prompt_v1` conductor (Extension-H step #30, hub § 23.2).
    registerProcedureResultBridge(interpreter);

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

    interpreter.registertopLevelFunction(
      emitName,
      (
        InterpreterVisitor visitor,
        List<Object?> arguments,
        Map<String, Object?> namedArguments,
        List<RuntimeType>? typeArguments,
      ) =>
          _invokeEmit(emitPrimitive, arguments),
      engineNativeLibrary,
      signature: 'Future<void> emit(String textDelta)',
    );

    // The convenience sugar (`think` / `plan` / `create` / `critique` /
    // `decide`) — fixed-id aliases over the same `runProcedure` primitive
    // (C.40, § 5.2). Registered after the primitives so they share the
    // engine-native library and the one `RunProcedurePrimitive`.
    registerSugarAliases(interpreter, runProcedurePrimitive);

    // The high-level scripted-LLM sugar `subLlm` — an implicit nested
    // `runProcedure(procedure ?? 'call_llm_v1', {...}, depthDelta: 1)` call
    // (Extension F step 9, § 21.1). Shares the same `RunProcedurePrimitive`,
    // so the depth cap (PE-3), run recording (PE-4), and effort roll-up are
    // inherited unchanged.
    registerScriptedLlmSugar(interpreter, runProcedurePrimitive);
  };
}

/// Validates and reads the optional `version` / `depthDelta` named arguments
/// shared by `runProcedure` and the five sugar verbs (E.2: both call sites
/// marshalled these identically, differing only in the message [label]).
///
/// `version` must be an `int` when present (else `null`); `depthDelta` must be
/// an `int` when present and defaults to `1`. [label] names the calling verb
/// (`runProcedure`, `think`, …) so the rejection message points at the d4rt
/// call the script actually wrote.
({int? version, int depthDelta}) readRunProcedureModifiers(
  Map<String, Object?> namedArguments,
  String label,
) {
  final version = namedArguments['version'];
  if (version != null && version is! int) {
    throw ArgumentError.value(
      version,
      'version',
      '$label version must be an int when supplied',
    );
  }

  final depthDeltaArg = namedArguments['depthDelta'];
  if (depthDeltaArg != null && depthDeltaArg is! int) {
    throw ArgumentError.value(
      depthDeltaArg,
      'depthDelta',
      '$label depthDelta must be an int when supplied',
    );
  }

  return (version: version as int?, depthDelta: (depthDeltaArg as int?) ?? 1);
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

  final (:version, :depthDelta) =
      readRunProcedureModifiers(namedArguments, 'runProcedure');

  return primitive.runProcedure(
    id,
    inputs,
    version: version,
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

/// Marshals a d4rt `emit(...)` call onto [primitive].
///
/// Positional args: `[0]` the text delta (String). Returns the primitive's
/// `Future<void>`, which the script awaits so the downstream channel's
/// backpressure reaches the body (P1.3 #8). On an internal / free-time run the
/// primitive has no bound sink and the future resolves immediately (a no-op).
Future<void> _invokeEmit(
  EmitPrimitive primitive,
  List<Object?> arguments,
) {
  if (arguments.isEmpty) {
    throw ArgumentError(
      'emit expects (String textDelta); got 0 positional arguments',
    );
  }

  final textDelta = arguments[0];
  if (textDelta is! String) {
    throw ArgumentError.value(
      textDelta,
      'textDelta',
      'emit textDelta must be a String',
    );
  }

  return primitive.emit(textDelta);
}
