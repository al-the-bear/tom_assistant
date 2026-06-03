// Barrel for the `procedure_store/` module (Plan step C.8).
//
// Owns procedure storage, loading, and version resolution
// (`tom_brain_procedure_prototype_specification.md` § 6, Plan steps
// C.23–C.26):
//
//   - `ProcedureStore` — two backends behind one interface:
//     (a) **disk** for `scripts/system/` (well-known) + `scripts/user/`,
//     (b) **memory** for brain-authored procedures stored as
//     `Procedure` nodes via the memory client.
//   - Procedure loader — parses the structured header (procedure id,
//     version, summary, success criterion, budget caps).
//   - Procedure resolver — fallback chain `[v_latest, …, v1]`. For the
//     prototype only `v1` exists; the chain machinery is still present.
//
// Wiring across later Phase C steps:
//
//   - C.23 ✅ — `ProcedureStore` interface + disk + memory backends
//     (+ a composite that presents both as one).
//   - C.24 ✅ — header-parsing loader (`ProcedureLoader`, `ProcedureHeader`,
//     `ProcedureHeaderInvalid`, `LoadedProcedure`).
//   - C.25 ✅ — version resolver with fallback chain (`ProcedureResolver`,
//     `ProcedureNotFound`).
//   - C.26 ✅ — backend-equivalence + malformed-header + resolver
//     acceptance suite (`test/procedure_store_acceptance_test.dart`); no
//     production code, raises the three pillars to the integrated
//     `store → loader → resolver` pipeline.

export 'composite_procedure_store.dart';
export 'disk_procedure_store.dart';
export 'memory_procedure_store.dart';
export 'procedure_header.dart';
export 'procedure_header_invalid.dart';
export 'procedure_loader.dart';
export 'procedure_not_found.dart';
export 'procedure_origin.dart';
export 'procedure_ref.dart';
export 'procedure_resolver.dart';
export 'procedure_source.dart';
export 'procedure_store_interface.dart';
