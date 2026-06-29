// AggregatingMemory — the single capability seam the bridged
// `mem.aggregateProfilesIntoGlobal` primitive type-checks against
// (memory_specification.md § 2.6, Phase 2).
//
// Production memory is isolate-hosted: the dream loop holds a
// `TomBrainMemoryClient`, which in production is a
// `TomBrainMemoryIsolateClient` (RPC) — NOT the in-process
// `TomBrainMemory` that owns the profile registry. So the bridge cannot
// reach `ProfileAggregator` directly; it would have to cross the isolate
// boundary by hand.
//
// Rather than widen the ~54-implementer `TomBrainMemoryClient` wire
// interface with a method only two classes can honour, this narrow marker
// interface names exactly the one capability "run the cross-profile
// aggregation pass and tell me what changed." Exactly two production
// classes implement it:
//
//   * `SqliteTomBrainMemory` — runs the `ProfileAggregator` in-process
//     against its own profile registry.
//   * `TomBrainMemoryIsolateClient` — forwards one RPC envelope to the
//     in-isolate `SqliteTomBrainMemory`, which does the same.
//
// The bridge does `client is AggregatingMemory` and calls the one method;
// everything else about the aggregation tier stays inside memory.

/// The cross-profile global-aggregation capability (memory § 2.6).
///
/// Implemented by the two memory handles that can actually drive a pass —
/// the in-process store and the isolate client. The single coarse method
/// runs one whole pass and returns a primitive, SendPort-serialisable
/// summary so the result crosses the isolate boundary unchanged.
abstract interface class AggregatingMemory {
  /// Runs one cross-profile aggregation pass (memory § 2.6): reads the
  /// allowlisted semantic nodes out of every source profile and
  /// (re-)derives them, with provenance, into the reserved read-only
  /// `global` profile under the `aggregator` agent.
  ///
  /// Returns a primitive summary map with keys `ran` (bool),
  /// `sourceProfiles` (`List<String>`), `nodesScanned` (int), and
  /// `nodesDerived` (int) — every value SendPort-serialisable so the
  /// isolate client can return it verbatim. A no-op pass (`enabled:
  /// false`, GA-11) returns `ran: false` with zero counts.
  Future<Map<String, Object?>> aggregateProfilesIntoGlobal();
}
