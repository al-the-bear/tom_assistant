/// @procedure
/// id: plan_v1
/// version: 1
/// summary: Clear-error stub for the planning loop — the callable target the
///   `plan(…)` sugar verb and the `procedure.plan` tool resolve to until the
///   real planning loop ships (Todo 8/9).
/// successCriterion: throws ProcedureNotImplemented naming the planning loop;
///   it resolves, lists, and validates, but never produces a plan.
/// budget: { wallClockMs: 1000 }
/// inputs:
///   - { name: goal, type: String, required: false }
/// requires: [ notImplemented ]
//
// plan_v1 — a clear-error stub
// (`tom_brain_procedure_prototype_specification.md` § 5.2.1; Todo 4 / G-PR6).
//
// Unlike the no-op `think_v1` stub (a machinery fixture that returns a Map and
// touches nothing), this stub is a *deliberate loud failure*: the planning loop
// it stands for has not landed yet, so invoking `plan()` — or the explicit
// `procedure.plan` tool — fails with the typed `ProcedureNotImplemented`
// (never the bare `ProcedureNotFound`: the procedure resolved and ran). The one
// engine-native `notImplemented` primitive is the single build site for the
// fixed § 5.2.1 message, so this body is one expression. It declares exactly
// that primitive in `requires`, so it passes the strict ContractValidator
// (which the Map-returning `think_v1` cannot). Replaced by the real planning
// loop in Todo 8/9.
import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure/src/api/procedure_result.dart';
import 'package:tom_brain_procedure/src/primitives_native/primitives_native.dart';

Future<ProcedureResult> run(ProcedureInputs inputs) async =>
    notImplemented('plan');
