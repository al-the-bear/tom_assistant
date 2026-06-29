// Global-aggregation provenance keys + the default semantic allowlist
// (memory_specification.md § 2.6, GA-3 / GA-4).
//
// The aggregator copies a source node's semantic values into a derived
// `global` node and stamps three provenance fields so a `global` read can
// always name where each aggregated node came from. Provenance is recorded
// as node **values** (not a cross-store edge): the `global` store is a
// separate SQLite tenant, so an edge into a source profile would cross the
// store-isolation boundary GA-INV forbids. These three keys are declared as
// optional, non-indexed string fields on every allowlisted type's schema
// (`bootstrap_node_types.yaml`), so the unknown-field write guard accepts
// them.

/// The source profile a `global` node was aggregated from (GA-4).
const String aggregationSourceProfileKey = '_sourceProfile';

/// The source node's `NodeId.value` a `global` node was aggregated from
/// (GA-4).
const String aggregationSourceNodeIdKey = '_sourceNodeId';

/// The UTC ISO-8601 instant a `global` node was (re-)derived (GA-4).
const String aggregationAtKey = '_aggregatedAt';

/// All three provenance keys — used to strip any inbound provenance from a
/// source node before re-stamping (defence in depth; a source node should
/// never carry these, but re-aggregating must never compound them).
const Set<String> aggregationProvenanceKeys = <String>{
  aggregationSourceProfileKey,
  aggregationSourceNodeIdKey,
  aggregationAtKey,
};

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
