// Barrel for the `aggregation/` module — the cross-profile
// global-aggregation tier (memory_specification.md § 2.6, GA-1…GA-11).
//
// The engine (`ProfileAggregator`) reads durable, semantic knowledge out of
// every source profile and re-derives it, with provenance, into the
// reserved read-only `global` profile. GA-INV (no flow back into a source;
// `global` written only here) is enforced by construction via the
// registry's read/write seams — see `profile_aggregator.dart`.
//
// This is the Phase-1 Dart engine. The d4rt `dream_aggregate_v1` procedure,
// the `aggregator` agent registration, and the off-by-default `aggregate`
// cadence lane are the deferred Phase-2 remainder.

export 'aggregation_config.dart' show AggregationConfig;
export 'aggregation_provenance.dart'
    show
        aggregationAtKey,
        aggregationProvenanceKeys,
        aggregationSourceNodeIdKey,
        aggregationSourceProfileKey,
        defaultAggregationNodeTypes;
export 'profile_aggregator.dart'
    show
        AggregationPassResult,
        ProfileAggregator,
        aggregatorAgentName,
        aggregatorProducer;
