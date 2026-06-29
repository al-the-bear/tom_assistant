// Barrel for the `aggregation/` module — the cross-profile
// global-aggregation tier (memory_specification.md § 2.6, GA-1…GA-11).
//
// The engine (`ProfileAggregator`) reads durable, semantic knowledge out of
// every source profile and re-derives it, with provenance, into the
// reserved read-only `global` profile. GA-INV (no flow back into a source;
// `global` written only here) is enforced by construction via the
// registry's read/write seams — see `profile_aggregator.dart`.
//
// This is the engine + Phase-2 surface. `AggregationConfig` and the default
// allowlist now live in `tom_brain_shared` (config that crosses the memory
// isolate boundary); they are re-exported here for source compatibility.

export 'package:tom_brain_shared/tom_brain_shared.dart'
    show AggregationConfig, defaultAggregationNodeTypes;

export 'aggregating_memory.dart' show AggregatingMemory;
export 'aggregation_provenance.dart'
    show
        aggregationAtKey,
        aggregationProvenanceKeys,
        aggregationSourceNodeIdKey,
        aggregationSourceProfileKey;
export 'aggregator_registration.dart'
    show GlobalProfileWriteForbidden, aggregatorRegistration;
export 'profile_aggregator.dart'
    show
        AggregationPassResult,
        ProfileAggregator,
        aggregatorAgentName,
        aggregatorProducer;
