// Scripted-LLM sugar — the high-level `sub.llm` call (Extension F step 9;
// `tom_brain_procedure_specification.md` § 21.1, § 5.1).
//
// ── What `sub.llm` is ───────────────────────────────────────────────
//
// § 21.1 defines `sub.llm(prompt, {role, procedure, tools, mcpServers,
// model, budget})` as **exactly**
//
//     runProcedure(procedure ?? 'call_llm_v1',
//                  {prompt, role, tools, mcpServers, model, budget},
//                  depthDelta: 1)
//
// — an implicit nested procedure call. It re-implements nothing: by
// delegating to the shared [RunProcedurePrimitive] it inherits the hard
// depth cap (PE-3), run recording (PE-4), and effort roll-up for free. The
// only work here is marshalling the d4rt call into a [ProcedureInputs] bag
// and selecting the target procedure id.
//
// ── Why the script spells it `subLlm`, not `sub.llm` ────────────────
//
// `sub` is the substrate-bridge global (`D4rtDcliHost.substrateGlobal`), so
// `sub.llm(...)` parses as a *method call on the substrate bridge* — today's
// low-level completion. The high-level sugar therefore needs a distinct
// identifier, and d4rt binds engine-native primitives as bare top-level
// functions. So the sugar is the camelCase token [scriptedLlmSugarName]
// (`subLlm`) — which is exactly the dotted→camel call-token the catalog
// derives for the canonical `requires` name `sub.llm`
// (`callTokensFor('sub.llm') == {'sub.llm', 'subLlm'}`). The validator
// accepts either spelling as a call to the one primitive; the runtime routes
// `subLlm(...)` here and `sub.llm(...)` to the bridge method. The full
// rename (making `sub.llm` route here while the low-level moves to a bare
// `llm`) is steps 10–11; step 9 only adds the sugar, its catalog entry, and
// the validator wiring.

import 'package:tom_d4rt/d4rt.dart';

import '../api/procedure_inputs.dart';
import '../api/procedure_result.dart';
import 'native_primitives_installer.dart' show engineNativeLibrary;
import 'run_procedure_primitive.dart';

/// The d4rt global name the scripted-LLM sugar is bound to — the
/// dotted→camel call-token of the canonical `requires` name `sub.llm`.
const String scriptedLlmSugarName = 'subLlm';

/// The default procedure the sugar forwards to when the caller supplies no
/// `procedure:` argument (§ 21.1).
const String defaultScriptedLlmProcedureId = 'call_llm_v1';

/// The default role threaded into the merged inputs when the caller supplies
/// no `role:` argument (§ 21.1, § 10).
const String defaultScriptedLlmRole = 'assistant_to_user';

/// Registers the `subLlm` scripted-LLM sugar onto [interpreter], delegating
/// to [primitive].
///
/// Run from the engine-native installer (after the primitives and the C.40
/// sugar aliases are bound) so a script reaches `subLlm` as a bare global
/// after importing [engineNativeLibrary]. The sugar shares the one
/// [RunProcedurePrimitive], so the depth cap (PE-3), run recording (PE-4),
/// and effort roll-up are identical — it adds only the merged-inputs
/// marshalling and the default procedure id.
void registerScriptedLlmSugar(
  D4rt interpreter,
  RunProcedurePrimitive primitive,
) {
  interpreter.registertopLevelFunction(
    scriptedLlmSugarName,
    (
      InterpreterVisitor visitor,
      List<Object?> arguments,
      Map<String, Object?> namedArguments,
      List<RuntimeType>? typeArguments,
    ) =>
        _invokeScriptedLlm(primitive, arguments, namedArguments),
    engineNativeLibrary,
    signature: 'Future<ProcedureResult> $scriptedLlmSugarName(String prompt, '
        '{String role, String procedure, List<String> tools, '
        'List<String> mcpServers, String model, Map<String, Object?> budget})',
  );
}

/// Marshals a d4rt `subLlm(prompt, {role, procedure, tools, mcpServers,
/// model, budget})` call onto [primitive].
///
/// Positional args: `[0]` the prompt (String). Named args: `role` (String,
/// default [defaultScriptedLlmRole]), `procedure` (String, selecting the
/// target id — default [defaultScriptedLlmProcedureId] — and *not* itself an
/// input), and the optional pass-throughs `tools` / `mcpServers` (lists of
/// Strings), `model` (String), `budget` (a String-keyed map). Only the
/// arguments the caller actually supplied land in the merged inputs, so the
/// target procedure's own defaults win for everything omitted.
Future<ProcedureResult> _invokeScriptedLlm(
  RunProcedurePrimitive primitive,
  List<Object?> arguments,
  Map<String, Object?> namedArguments,
) {
  if (arguments.isEmpty) {
    throw ArgumentError(
      '$scriptedLlmSugarName expects (String prompt); got no positional '
      'argument',
    );
  }

  final prompt = arguments[0];
  if (prompt is! String) {
    throw ArgumentError.value(
      prompt,
      'prompt',
      '$scriptedLlmSugarName prompt must be a String',
    );
  }

  final role = _stringArg(namedArguments, 'role') ?? defaultScriptedLlmRole;
  final procedure =
      _stringArg(namedArguments, 'procedure') ?? defaultScriptedLlmProcedureId;

  // The merged inputs always carry the prompt + (defaulted) role; the
  // optional pass-throughs appear only when the caller supplied them, so the
  // target procedure's downstream defaults win for everything omitted.
  final inputs = <String, Object?>{
    'prompt': prompt,
    'role': role,
  };

  final tools = _stringListArg(namedArguments, 'tools');
  if (tools != null) inputs['tools'] = tools;

  final mcpServers = _stringListArg(namedArguments, 'mcpServers');
  if (mcpServers != null) inputs['mcpServers'] = mcpServers;

  final model = _stringArg(namedArguments, 'model');
  if (model != null) inputs['model'] = model;

  final budget = _stringKeyedMapArg(namedArguments, 'budget');
  if (budget != null) inputs['budget'] = budget;

  return primitive.runProcedure(
    procedure,
    ProcedureInputs(inputs),
    depthDelta: 1,
  );
}

/// Reads optional named String [name], rejecting a non-String supplied value.
String? _stringArg(Map<String, Object?> namedArguments, String name) {
  final value = namedArguments[name];
  if (value == null) return null;
  if (value is! String) {
    throw ArgumentError.value(
      value,
      name,
      '$scriptedLlmSugarName $name must be a String when supplied',
    );
  }
  return value;
}

/// Reads optional named `List<String>` [name], coercing the d4rt list
/// literal and rejecting a non-list or non-String element.
List<String>? _stringListArg(Map<String, Object?> namedArguments, String name) {
  final value = namedArguments[name];
  if (value == null) return null;
  if (value is! List) {
    throw ArgumentError.value(
      value,
      name,
      '$scriptedLlmSugarName $name must be a List when supplied',
    );
  }
  return value.map((Object? element) {
    if (element is! String) {
      throw ArgumentError.value(
        element,
        '$name element',
        '$scriptedLlmSugarName $name elements must be Strings',
      );
    }
    return element;
  }).toList(growable: false);
}

/// Reads optional named `Map<String, Object?>` [name], coercing the d4rt map
/// literal and rejecting a non-map or non-String key.
Map<String, Object?>? _stringKeyedMapArg(
  Map<String, Object?> namedArguments,
  String name,
) {
  final value = namedArguments[name];
  if (value == null) return null;
  if (value is! Map) {
    throw ArgumentError.value(
      value,
      name,
      '$scriptedLlmSugarName $name must be a Map when supplied',
    );
  }
  final coerced = <String, Object?>{};
  value.forEach((Object? key, Object? element) {
    if (key is! String) {
      throw ArgumentError.value(
        key,
        '$name key',
        '$scriptedLlmSugarName $name keys must be Strings',
      );
    }
    coerced[key] = element;
  });
  return coerced;
}
