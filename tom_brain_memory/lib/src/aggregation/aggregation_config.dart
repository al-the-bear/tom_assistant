// AggregationConfig — the cross-profile global-aggregation tier's
// configuration (memory_specification.md § 2.6, GA-3 / GA-5 / GA-11).
//
// Off by default (GA-11): a brain that never opts in never aggregates.
// `enabled: false` makes `ProfileAggregator.runPass` a no-op that scans
// nothing and writes nothing.

import 'aggregation_provenance.dart';

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
