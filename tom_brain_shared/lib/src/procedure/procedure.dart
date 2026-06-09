// Barrel for the `procedure/` module — the cross-component procedure error
// vocabulary. At Todo 4 it carries exactly one type: `ProcedureNotImplemented`,
// the clear error a stub verb (`plan_v1` / `create_v1` / `critique_v1` /
// `decide_v1`) throws when invoked before its real loop ships
// (`tom_brain_procedure_prototype_specification.md` § 5.2.1).
//
// Why this lives in shared rather than in `tom_brain_procedure`: the typed
// error must be referenceable by every layer that observes a run outcome —
// the engine maps it onto `outcome.error`, the access edge and a Forge
// inspector read it back, and the substrate-side trail render names it — none
// of which should take a runtime dependency on the procedure package to do so.
// `ProcedureNotFound` stays in `tom_brain_procedure` because only the resolver
// raises it; `ProcedureNotImplemented` is raised from inside a running
// procedure (via the `notImplemented` engine-native primitive) and surfaces
// across component boundaries, so it belongs to the shared vocabulary.

export 'procedure_not_implemented.dart'
    show ProcedureNotImplemented, procedureNotImplementedCode;

// Todo 7 — the procedure lifecycle vocabulary. `ProcedureStatus` is the closed
// stage alphabet (authored → draft → active → preferred → demoted) with the
// forward-only + demotion transition rule; `CapabilitySet` is the `requires`-
// name set with the overlap measure the selector re-rank scores on. Both are
// cross-component (memory stores them, the selector ranks on them, the
// authoring loop stamps them), so they live in shared (spec § 14).
export 'capability_set.dart' show CapabilitySet;
export 'procedure_status.dart' show ProcedureStatus;

// Todo 7 — typed read-projections over the `Procedure` / `ProcedureRun` nodes.
// `ProcedureView` / `ProcedureRunView` decode the untyped node `values` map once,
// at the node boundary, so memory's typed queries, the selector re-rank, and a
// Forge inspector all read the same shape (procedure spec § 7.1, § 9.2).
export 'procedure_view.dart'
    show
        ProcedureView,
        ProcedureRunView,
        procedureNodeTypeName,
        procedureRunNodeTypeName;
