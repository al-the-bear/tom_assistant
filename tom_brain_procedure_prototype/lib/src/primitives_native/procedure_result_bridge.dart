// ProcedureResultBridge — bridges the procedure *result* type into d4rt
// (Plan Extension-H step #30; `tom_brain_procedure_prototype_specification.md`
// § 4.3, § 5.3, § 23.2).
//
// ── Why this exists ─────────────────────────────────────────────────
//
// `runProcedure(id, inputs)` resolves to a `ProcedureResult` (§ 5.3). Until
// step #30 every in-script caller only ever *forwarded* a result (e.g. the
// answer pipeline returned the engine's coercion directly), so the type
// crossed the d4rt boundary as an opaque host object — no body inspected it.
//
// The `retrieve_for_prompt_v1` conductor (hub § 23.2) is the first body that
// dispatches several `recall_*` sub-procedures and then *reads* each
// outcome: it keeps the seeds from successful runs and skips the failed ones
// (PE-6 graceful degrade). For that it needs `result.isSuccess` and
// `result.output('seeds')` to dispatch in-script — so this bridges
// `ProcedureResult`'s **read surface**.
//
// Only the read surface is bridged: a procedure never *constructs* a
// `ProcedureResult` in-script — the body returns a plain `Map` the engine
// coerces (§ 5.3). `output<T>` is exposed as its `Object?` projection
// (d4rt call sites pass no type argument), mirroring `ProcedureInputs.get`.

import 'package:tom_d4rt/d4rt.dart';
import 'package:tom_d4rt/tom_d4rt.dart';

import '../api/procedure_result.dart';

/// The library URI a procedure script imports to name [ProcedureResult] and
/// dispatch its accessors.
///
/// Canonical `package:` URI of the source file — required for the same
/// reason [procedureInputsLibrary] is: d4rt's `ModuleLoader` resolves
/// `package:` imports directly against the registered-library map, whereas a
/// relative import needs a filesystem base URI the interpreter does not have
/// at script-execute time.
const String procedureResultLibrary =
    'package:tom_brain_procedure_prototype/src/api/procedure_result.dart';

/// Builds the [BridgedClass] exposing [ProcedureResult]'s read surface
/// (`output`, `isSuccess`, `status`, `outputs`).
BridgedClass procedureResultBridgedClass() {
  return BridgedClass(
    nativeType: ProcedureResult,
    name: 'ProcedureResult',
    isAssignable: (v) => v is ProcedureResult,
    methods: {
      'output': (visitor, target, positional, named, typeArgs) {
        final t =
            D4.validateTarget<ProcedureResult>(target, 'ProcedureResult');
        D4.requireMinArgs(positional, 1, 'output');
        final name =
            D4.getRequiredArg<String>(positional, 0, 'name', 'output');
        return t.output<Object?>(name);
      },
    },
    getters: {
      'isSuccess': (visitor, target) =>
          D4.validateTarget<ProcedureResult>(target, 'ProcedureResult')
              .isSuccess,
      'status': (visitor, target) =>
          D4.validateTarget<ProcedureResult>(target, 'ProcedureResult')
              .status
              .name,
      'outputs': (visitor, target) =>
          D4.validateTarget<ProcedureResult>(target, 'ProcedureResult')
              .outputs,
    },
    methodSignatures: {
      'output': 'Object? output(String name)',
    },
    getterSignatures: {
      'isSuccess': 'bool get isSuccess',
      'status': 'String get status',
      'outputs': 'Map<String, Object?> get outputs',
    },
  );
}

/// Registers [procedureResultBridgedClass] with [interpreter] under
/// [procedureResultLibrary], so a procedure script importing that library
/// can inspect a result returned by `runProcedure(...)`.
void registerProcedureResultBridge(D4rt interpreter) {
  interpreter.registerBridgedClass(
    procedureResultBridgedClass(),
    procedureResultLibrary,
  );
}
