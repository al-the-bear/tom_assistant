// B.9 — `TomBrainSubstrate` in-process marker base class.
//
// `substrate_specification.md` § 3.1 shows the surface as:
//
//   abstract class TomBrainSubstrate implements TomBrainSubstrateClient {
//     // … same methods …
//   }
//
// — i.e., the in-process facade has the same surface as the
// consumer interface. Mirrors the memory-side pattern (A.78):
// `TomBrainMemory implements TomBrainMemoryClient`. The two-class
// split exists for the same reason it does on the memory side:
//
//   * `TomBrainSubstrateClient` is the substitutable contract.
//     Consumers (the dispatcher, the engine bridge, the access
//     layer) hold a `TomBrainSubstrateClient` reference. Tests bind
//     against it. The contract is what an isolate/remote adapter
//     must honour.
//   * `TomBrainSubstrate` is the in-process marker. A
//     composition root that needs to assert "I have the in-process
//     implementation" — for example, a test fixture that wants to
//     replace the LLM router mid-test, or a Tom Forge inspector
//     that reads in-memory route-decision counters — targets this
//     class. The concrete v1 implementation
//     (`InProcessTomBrainSubstrate`, lands B.40+) extends this.
//
// At B.9 there are no new abstract members on top of the client
// interface; the seam is reserved for in-process-only fast paths
// (synchronous route lookup, raw provider injection for tests) that
// later phases may want without crossing an isolate boundary.

import 'tom_brain_substrate_client.dart';

/// The in-process Dart base class for the Tom Brain substrate.
///
/// Inherits the full consumer-facing surface from
/// [TomBrainSubstrateClient]; see that interface for the
/// method-by-method contracts (`substrate_specification.md` § 3.1).
///
/// **Implementation rule.** The only concrete implementation that
/// exists for v1 is `InProcessTomBrainSubstrate` (lands at plan
/// step B.40+). Tests that need an in-process fake implement this
/// class directly — there is no second production implementation.
/// Tests that want to assert behaviour at the client-interface
/// boundary instead implement [TomBrainSubstrateClient] (lighter,
/// isolate-adapter-compatible).
///
/// **Anchor guarantee.** Inherited from
/// [TomBrainSubstrateClient]: every call path that produces an
/// `LlmCallReport` carries the assistant-dedication anchor and
/// stamps its hash on the report. Subclasses cannot weaken this —
/// the role-template assembly path is the only assembly path, and
/// it cannot drop the anchor (plan step B.46 conformance test).
abstract class TomBrainSubstrate implements TomBrainSubstrateClient {
  /// `const` constructor so test fakes can stay `const`.
  const TomBrainSubstrate();

  // B.9: no in-process-only abstract members yet. Added on demand
  // as concrete in-process implementations need them (B.40+).
}
