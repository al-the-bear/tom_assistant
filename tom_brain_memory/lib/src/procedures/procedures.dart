// Barrel for the `procedures/` module — the Todo-7 typed procedure queries
// (`procedure_specification.md` § 7.3, § 9.2, § 10.3, G-PR4).
//
// `CandidateProceduresFor`, `ProcedureRunsOf`, and `ProcedureRevisionChain`
// compose the `TomBrainMemoryClient` read primitives into the three named reads
// the procedure subsystem needs. The shapes they return (`ProcedureView`,
// `ProcedureRunView`) live in `tom_brain_shared`; the scoring they apply
// (`scoreProcedureCandidate`) lives in `tom_core_agentic`.

export 'procedure_metrics_writer.dart' show ProcedureMetricsWriter;
export 'procedure_queries.dart'
    show
        CandidateProceduresFor,
        ProcedureRevisionChain,
        ProcedureRunsOf,
        RankedProcedure;
