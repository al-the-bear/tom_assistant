// TomBrainMemory — the in-process Dart API for the brain's
// property-graph memory (memory_specification.md § 3.1).
//
// Since A.78, the consumer-facing surface has been hoisted into
// [TomBrainMemoryClient]: every method documented in spec § 3.1
// is declared there, and consumers (dispatcher, procedure engine,
// MCP server, cognitive agents) target the client interface
// rather than this class. `TomBrainMemory` extends
// `TomBrainMemoryClient` and adds no new abstract members for v1.
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
// The MCP server (§ 3.2) wraps a strict read-only slice of the
// client surface for cross-process callers. The procedure-engine
// bridge (§ 3.3) re-exports the methods as the primitive set
// d4rt scripts call.

import 'tom_brain_memory_client.dart';

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
  // A.78: no in-process-only abstract members yet. Added on
  // demand as concrete in-process implementations need them.
}
