// RetrievalEvalEnvironment — the seam the retrieval eval harness drives its
// five phases through (Plan-2 extension step #33; spec § 23.8).
//
// The harness owns the *logic* — strategy-set → `MemoryRetrievalConfig`
// resolution, metric scoring, the metric × strategy-set matrix. The
// environment owns the *substrate* — where a throwaway profile is created,
// seeded, queried, and dropped. Splitting them is what lets the harness's
// scoring be exercised by a deterministic double while a production
// environment (`ProcedureEngineEvalEnvironment`) drives the same phases over a
// real `ProcedureEngine` + memory store.
//
// The seam is deliberately store-agnostic: the corpus is handed over as
// [EvalSeedDoc]s carrying the *logical* `evalId` label (not a store node id),
// and [query] returns the ranked logical ids — so a scored result never
// depends on store-assigned identities and an eval re-runs identically on a
// fresh profile.

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart'
    show MemoryRetrievalConfig;

/// One fixture document the harness asks the environment to seed.
///
/// Carries the logical [evalId] the query expectations reference; the
/// environment is responsible for storing it such that [RetrievalEvalEnvironment.query]
/// can recover that same [evalId] from a ranked hit.
final class EvalSeedDoc {
  const EvalSeedDoc({
    required this.evalId,
    required this.kind,
    required this.text,
    this.at,
    this.about = const <String>[],
  });

  /// The logical label scored against (`mustInclude` / `mustRankTop`).
  final String evalId;

  /// The node kind (`event`, `claim`, `concept`, …) to seed under.
  final String kind;

  /// The document text — what gets embedded / indexed on seed.
  final String text;

  /// Optional ISO-8601 event timestamp carried into the node values.
  final String? at;

  /// Optional Concept names this item is about.
  final List<String> about;
}

/// The phase seam the [RetrievalEvalHarness] drives.
///
/// Lifecycle per harness run: [provision] → [seed] → many [query] → [drop].
/// [drop] is the reset-to-zero — the harness always calls it (in a `finally`)
/// so no live store is left mutated.
abstract interface class RetrievalEvalEnvironment {
  /// Creates the throwaway [profile]. A second call for an existing profile is
  /// the environment's concern (the harness provisions once per run).
  Future<void> provision(String profile);

  /// Ingests the labelled [docs] into [profile] through the normal write path.
  Future<void> seed(String profile, List<EvalSeedDoc> docs);

  /// Runs [prompt] against [profile] under [config] and returns the ranked
  /// logical `evalId`s, best-first. Ids that were not seeded must not appear.
  Future<List<String>> query(
    String profile,
    String prompt,
    MemoryRetrievalConfig config,
  );

  /// Deletes [profile] (whole-store reset-to-zero). Always called by the
  /// harness, even when a phase threw.
  Future<void> drop(String profile);
}
