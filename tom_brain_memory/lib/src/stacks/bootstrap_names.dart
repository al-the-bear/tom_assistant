// Well-known bootstrap-schema names — the single source of truth for the
// six reserved bootstrap stack names and the run-record node type from
// `memory_specification.md` § 5.4.
//
// These identifiers are a cross-component contract: the memory bootstrap
// installer (A.43) creates stacks under these names, `SqliteStackApi`
// rejects `create` for them, and downstream components — notably the
// procedure engine's run recorder — push/peek/remove against them and
// persist run records as the `ProcedureRun` node type. They were previously
// duplicated as bare string literals in `sqlite_stack_api.dart`, the
// installer, and (across the package boundary) the procedure prototype's
// `run_records.dart`. Naming them once here, and having every site consume
// these constants, removes that drift risk: a rename lands in one place.

/// Reserved stack of open inquiries the brain pulls from for self-directed
/// work (§ 5.4, stack #1).
const String questionsOpenStackName = 'questions_open';

/// Reserved stack of candidate procedures the brain may author (§ 5.4,
/// stack #2).
const String automationIdeasStackName = 'automation_ideas';

/// Reserved stack of topics the brain is curious about (§ 5.4, stack #3).
const String interestsStackName = 'interests';

/// Reserved stack of procedure runs currently being executed (§ 5.4,
/// stack #4) — pushed at run start, removed at completion.
const String inflightStackName = 'inflight';

/// Reserved stack of just-completed procedure runs (§ 5.4, stack #5) — the
/// feed the dispatcher's harvester peeks.
const String recentRunsStackName = 'recent_runs';

/// Reserved stack of nodes flagged for restructuring by the dream cycles
/// (§ 5.4, stack #6).
const String restructureBacklogStackName = 'restructure_backlog';

/// The node type every procedure run record is persisted as (bootstrap node
/// type #13). Shared by the `inflight` / `recent_runs` stacks' entry-type
/// declarations and the procedure engine's run recorder.
const String procedureRunNodeType = 'ProcedureRun';

/// The six reserved bootstrap stack names from `memory_specification.md`
/// § 5.4. `SqliteStackApi.create` rejects these; the per-name installation
/// path lives in A.43. Built from the named constants above so the set and
/// the individual names cannot drift apart.
const Set<String> bootstrapStackNames = <String>{
  questionsOpenStackName,
  automationIdeasStackName,
  interestsStackName,
  inflightStackName,
  recentRunsStackName,
  restructureBacklogStackName,
};
