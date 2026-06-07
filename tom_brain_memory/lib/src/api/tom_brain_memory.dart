// TomBrainMemory — the in-process Dart API for the brain's
// property-graph memory (memory_specification.md § 3.1).
//
// Since A.78, the consumer-facing surface has been hoisted into
// [TomBrainMemoryClient]: every method documented in spec § 3.1
// is declared there, and consumers (dispatcher, procedure engine,
// MCP server, cognitive agents) target the client interface
// rather than this class. `TomBrainMemory` extends
// `TomBrainMemoryClient`.
//
// Step H.28 (Extension H) adds the first in-process-only abstract
// members — the surfaces the MCP server reaches for through the
// in-process marker that the isolate adapter does not carry:
//
//   * `recallMulti` (memory § 6.5) — multi-seed weighted-RRF recall.
//   * `profiles` (memory § 2.5) — the profile-administration surface.
//     `dropProfile` is a whole-store reset, so this never crosses to
//     the read-only MCP server's write path; the read tools call only
//     `profiles.list`.
//   * `currentProfile` (memory § 3.1, reconciled at H.28) — the
//     profile name this handle is bound to, or `null` for the
//     unbound single-tenant layout. A synchronous introspection of
//     the value captured at `open`, so it lands here on the in-process
//     marker rather than the async client surface.
//
// Why this class still exists as its own type:
//
//   * It is the *in-process marker* — a concrete `SqliteTomBrainMemory`
//     (A.28+) is a `TomBrainMemory`, while the future
//     `TomBrainMemoryIsolateClient` (A.80) is only a
//     `TomBrainMemoryClient`. Composition-root code that needs to
//     assert "I have the in-process implementation" (for example,
//     test fixtures that want to introspect the SQLite handle
//     directly) targets `TomBrainMemory`.
//   * It reserves the seam where in-process-only fast paths can
//     land without crossing the isolate boundary — synchronous
//     introspection, direct DB-handle exposure for tests,
//     non-serialisable callbacks. Any method added here is
//     unavailable through the isolate adapter by construction.
//
// The MCP server (§ 3.2) wraps a narrow slice of the client surface
// for cross-process callers — six read tools plus the single
// closed-set `memory.persistNote` write. The procedure-engine
// bridge (§ 3.3) re-exports the methods as the primitive set
// d4rt scripts call.

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show MemoryProfileRegistry, MultiRecallQuery, RecallResult, TomBrainMemoryClient;

/// The in-process Dart base class for the brain's property-graph
/// memory.
///
/// Inherits the full consumer-facing surface from
/// [TomBrainMemoryClient]; see that interface for the
/// method-by-method contracts (`memory_specification.md` § 3.1).
///
/// **Implementation rule:** the only concrete implementation that
/// exists for v1 is `SqliteTomBrainMemory` (lands at A.28). Tests
/// that need an in-process fake implement this class directly —
/// there is no second production implementation. Tests that want
/// to assert behaviour at the client-interface boundary instead
/// implement [TomBrainMemoryClient] (lighter, isolate-adapter-
/// compatible).
abstract class TomBrainMemory implements TomBrainMemoryClient {
  /// Multi-seed weighted-RRF recall (memory § 6.5, Extension H).
  ///
  /// Runs each [MultiRecallQuery.seeds] entry through the § 6.1 mode
  /// implementations, fuses the per-seed ranked lists with RRF
  /// honouring each seed's weight, diversifies with MMR, and returns
  /// one [RecallResult] whose `provenance` records which seeds
  /// surfaced each node and its fused score. Instantiates no LLM —
  /// text seeds are embedded by the storage-stack embedder, exactly as
  /// single-seed `recall` already does.
  Future<RecallResult> recallMulti(MultiRecallQuery query);

  /// The profile-administration surface over the
  /// `<memory-root>/profiles/` tier (memory § 2.5).
  ///
  /// `list` / `exists` / `createProfile` / `seedProfile` /
  /// `dropProfile`. The read-only MCP server exposes only
  /// `profiles.list` (memory § 3.2); `dropProfile` is a whole-store
  /// reset and never crosses that boundary.
  MemoryProfileRegistry get profiles;

  /// The profile name this handle is bound to, or `null` for the
  /// profile-unbound single-tenant layout (memory § 3.1, reconciled at
  /// H.28). Captured from `MemoryConfig.profile` at `open`; reset to
  /// `null` on `close`.
  String? get currentProfile;
}
