// ProcedureInputsBridge — bridges the entry-point input type into d4rt
// (Plan step D.37; `tom_brain_procedure_specification.md`
// § 4.3, § 5.3).
//
// ── Why this exists ─────────────────────────────────────────────────
//
// The spec mandates the entry point `Future<ProcedureResult> run(
// ProcedureInputs inputs)` (§ 4.3) and says the result/input wrappers are
// "bridged into d4rt" (§ 5.3). Until a body actually *reads* an input,
// `ProcedureInputs` crossed the d4rt boundary as an opaque host object —
// the script only ever forwarded it to `runProcedure(id, inputs)`
// (`native_primitives_installer.dart`, "Opaque pass-through"). D.37 is the
// first body step that reads an input (`recall(text: …)` needs the inbound
// prompt), so this step bridges `ProcedureInputs`'s **read surface** so a
// script can do `inputs.get('text')`.
//
// A script reaches the type by importing [procedureInputsLibrary] and
// declaring its entry point as `run(ProcedureInputs inputs)`; d4rt then
// dispatches the accessor methods below onto the native instance the engine
// hands in. (A bare `run(inputs)` cannot dispatch — d4rt needs the declared
// bridged type to resolve the method; this mirrors how the `mem` / `sub`
// bridges require an `import` to resolve.)
//
// Only the **read** surface is bridged: a procedure inspects its inputs, it
// never constructs a `ProcedureInputs` in-script (the engine/sugar build
// those, § 5.3). The generic `get<T>` / `getOrNull<T>` are exposed as their
// `Object?` projections — d4rt call sites pass no type argument, and the
// recall/llm bridges re-validate the value's concrete type at their own
// boundary (`getRequiredArg<String>`), so a wrong-typed input still fails
// loudly one call later.

import 'package:tom_d4rt/d4rt.dart';
import 'package:tom_d4rt/tom_d4rt.dart';

import '../api/procedure_inputs.dart';

/// The library URI a procedure script imports to name [ProcedureInputs] and
/// dispatch its accessors.
///
/// Canonical `package:` URI of the source file — required for the same
/// reason the bridge libraries are (`BrainBridges.memoryLibrary`): d4rt's
/// `ModuleLoader` resolves `package:` imports directly against the
/// registered-library map, whereas a relative import needs a filesystem
/// base URI the interpreter does not have at script-execute time.
const String procedureInputsLibrary =
    'package:tom_brain_procedure/src/api/procedure_inputs.dart';

/// Builds the [BridgedClass] exposing [ProcedureInputs]'s read surface
/// (`get`, `getOrNull`, `has`, `toMap`, `names`).
BridgedClass procedureInputsBridgedClass() {
  return BridgedClass(
    nativeType: ProcedureInputs,
    name: 'ProcedureInputs',
    isAssignable: (v) => v is ProcedureInputs,
    methods: {
      'get': (visitor, target, positional, named, typeArgs) {
        final t =
            D4.validateTarget<ProcedureInputs>(target, 'ProcedureInputs');
        D4.requireMinArgs(positional, 1, 'get');
        final name = D4.getRequiredArg<String>(positional, 0, 'name', 'get');
        return t.get<Object?>(name);
      },
      'getOrNull': (visitor, target, positional, named, typeArgs) {
        final t =
            D4.validateTarget<ProcedureInputs>(target, 'ProcedureInputs');
        D4.requireMinArgs(positional, 1, 'getOrNull');
        final name =
            D4.getRequiredArg<String>(positional, 0, 'name', 'getOrNull');
        return t.getOrNull<Object?>(name);
      },
      'has': (visitor, target, positional, named, typeArgs) {
        final t =
            D4.validateTarget<ProcedureInputs>(target, 'ProcedureInputs');
        D4.requireMinArgs(positional, 1, 'has');
        final name = D4.getRequiredArg<String>(positional, 0, 'name', 'has');
        return t.has(name);
      },
      'toMap': (visitor, target, positional, named, typeArgs) {
        final t =
            D4.validateTarget<ProcedureInputs>(target, 'ProcedureInputs');
        return t.toMap();
      },
    },
    getters: {
      'names': (visitor, target) =>
          D4.validateTarget<ProcedureInputs>(target, 'ProcedureInputs')
              .names
              .toList(),
    },
    methodSignatures: {
      'get': 'Object? get(String name)',
      'getOrNull': 'Object? getOrNull(String name)',
      'has': 'bool has(String name)',
      'toMap': 'Map<String, Object?> toMap()',
    },
    getterSignatures: {
      'names': 'List<String> get names',
    },
  );
}

/// Registers [procedureInputsBridgedClass] with [interpreter] under
/// [procedureInputsLibrary], so a procedure script importing that library
/// can read its inputs.
void registerProcedureInputsBridge(D4rt interpreter) {
  interpreter.registerBridgedClass(
    procedureInputsBridgedClass(),
    procedureInputsLibrary,
  );
}
