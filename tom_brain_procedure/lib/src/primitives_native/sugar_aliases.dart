// Sugar aliases — the convenience verbs `think` / `plan` / `create` /
// `critique` / `decide` over `runProcedure('<name>_v1', …)` (Plan step
// C.40; `tom_brain_procedure_specification.md` § 5.2).
//
// ── What the sugar is ───────────────────────────────────────────────
//
// § 5.2 is explicit that these five verbs are **not** primitives: they
// are convenience aliases. `think(inputs)` is exactly
// `runProcedure('think_v1', inputs)`; `plan(inputs)` is exactly
// `runProcedure('plan_v1', inputs)`; and so on. They take the same
// optional `version` / `depthDelta` named arguments as `runProcedure`
// and delegate to the very same [RunProcedurePrimitive] — so the hard
// depth cap (PE-3), the recursion bookkeeping, and the executor seam are
// shared verbatim. There is no separate machinery here; the verbs are a
// thin, fixed-id projection of one primitive.
//
// ── Why so few procedures resolve in the prototype ──────────────────
//
// The full system library (the 23-procedure bootstrap) lands with the
// final dispatcher (Phase D). In the prototype only `think_v1` exists —
// a no-op stub (`scripts/system/think_v1.dart`, Q-C.2.1) — so `think(…)`
// resolves and runs that stub, while `plan` / `create` / `critique` /
// `decide` resolve to a missing `<name>_v1` and surface
// [ProcedureNotFound] informatively (the resolver throws it the moment
// the sugar's `runProcedure` reaches resolution). The verbs are wired
// now regardless of whether their target procedures exist yet, exactly
// as § 1.4 / § 5.2 require, so the final library inherits a working sugar
// surface unchanged.

import 'package:tom_d4rt/d4rt.dart';

import '../api/procedure_inputs.dart';
import '../api/procedure_result.dart';
import 'native_primitives_installer.dart'
    show engineNativeLibrary, readRunProcedureModifiers;
import 'run_procedure_primitive.dart';

/// The sugar verbs mapped to the procedure id each resolves to (§ 5.2).
///
/// Keys are the bare d4rt globals a script calls (`think`, `plan`, …);
/// values are the `<name>_v1` procedure ids the alias forwards to through
/// `runProcedure`. In the prototype only `think_v1` is shipped (a no-op
/// stub); the rest resolve to a missing procedure and surface
/// `ProcedureNotFound`. Unmodifiable so the verb set is a fixed contract.
const Map<String, String> sugarAliasProcedureIds = <String, String>{
  'think': 'think_v1',
  'plan': 'plan_v1',
  'create': 'create_v1',
  'critique': 'critique_v1',
  'decide': 'decide_v1',
};

/// Registers the five sugar verbs onto [interpreter], each delegating to
/// [primitive] with its fixed `<name>_v1` procedure id.
///
/// Run from the engine-native installer (after `runProcedure` / `note` /
/// `yield_if_foreground_waiting` are bound) so a script reaches the verbs
/// as bare globals after importing [engineNativeLibrary]. Each verb shares
/// the same [RunProcedurePrimitive] as `runProcedure`, so the depth cap and
/// recursion bookkeeping are identical — the sugar adds only the fixed id.
void registerSugarAliases(
  D4rt interpreter,
  RunProcedurePrimitive primitive,
) {
  for (final entry in sugarAliasProcedureIds.entries) {
    final verb = entry.key;
    final procedureId = entry.value;
    interpreter.registertopLevelFunction(
      verb,
      (
        InterpreterVisitor visitor,
        List<Object?> arguments,
        Map<String, Object?> namedArguments,
        List<RuntimeType>? typeArguments,
      ) =>
          _invokeSugar(primitive, verb, procedureId, arguments, namedArguments),
      engineNativeLibrary,
      signature: 'Future<ProcedureResult> $verb(ProcedureInputs inputs, '
          '{int? version, int depthDelta})',
    );
  }
}

/// Marshals a d4rt `<verb>(inputs, {version, depthDelta})` call onto
/// [primitive], forwarding to [procedureId].
///
/// Positional args: `[0]` the inputs (opaque [ProcedureInputs]). Named
/// args: `version` (int?), `depthDelta` (int, default 1) — the same shape
/// `runProcedure` accepts, minus the id (the sugar fixes it). Returns the
/// primitive's `Future<ProcedureResult>`, which the script awaits.
Future<ProcedureResult> _invokeSugar(
  RunProcedurePrimitive primitive,
  String verb,
  String procedureId,
  List<Object?> arguments,
  Map<String, Object?> namedArguments,
) {
  if (arguments.isEmpty) {
    throw ArgumentError(
      '$verb expects (ProcedureInputs inputs); got no positional argument',
    );
  }

  final inputs = arguments[0];
  if (inputs is! ProcedureInputs) {
    throw ArgumentError.value(
      inputs,
      'inputs',
      '$verb inputs must be a ProcedureInputs',
    );
  }

  final (:version, :depthDelta) =
      readRunProcedureModifiers(namedArguments, verb);

  return primitive.runProcedure(
    procedureId,
    inputs,
    version: version,
    depthDelta: depthDelta,
  );
}
