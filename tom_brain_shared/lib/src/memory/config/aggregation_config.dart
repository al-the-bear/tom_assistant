// AggregationConfig — the cross-profile global-aggregation tier's
// configuration (memory_specification.md § 2.6, GA-3 / GA-5 / GA-11).
//
// Off by default (GA-11): a brain that never opts in never aggregates.
// `enabled: false` makes `ProfileAggregator.runPass` a no-op that scans
// nothing and writes nothing.
//
// This value type lives in `tom_brain_shared` (no `dart:io`) so it can be
// embedded in `MemoryConfig` and travel across the memory isolate boundary
// via `open(config)`: the in-isolate `SqliteTomBrainMemory` reads its
// `aggregation` field to drive the engine. The engine itself, its
// provenance keys, and the `ProfileAggregator` stay in `tom_brain_memory`.

/// Configuration for the cross-profile aggregation pass.
final class AggregationConfig {
  /// Whether aggregation runs at all (GA-11). Off by default — the tier
  /// is opt-in, so an unconfigured brain never materialises `global`.
  final bool enabled;

  /// The semantic node types that are aggregated (GA-3). Defaults to the
  /// v1 allowlist (`Concept` / `Claim` / `Conclusion` / `Pattern` /
  /// `InterestItem`). Episodic types are never included.
  final Set<String> nodeTypes;

  /// Source profiles to skip in addition to the always-skipped reserved
  /// `global` profile (e.g. an eval or scratch profile that should not
  /// contribute to the shared tier).
  final Set<String> excludeProfiles;

  const AggregationConfig({
    this.enabled = false,
    this.nodeTypes = defaultAggregationNodeTypes,
    this.excludeProfiles = const <String>{},
  });
}

/// The v1 default semantic-type allowlist (GA-3): only durable, semantic
/// knowledge is aggregated. Episodic types (`Event`, `Session`, `Trail`,
/// `ProcedureRun`, …) are never aggregated — they are local lived history,
/// not shareable knowledge.
const Set<String> defaultAggregationNodeTypes = <String>{
  'Concept',
  'Claim',
  'Conclusion',
  'Pattern',
  'InterestItem',
};
