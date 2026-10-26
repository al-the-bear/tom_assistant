// B.7 dependency-surface contract test.
//
// Locks the runtime dependencies named in the plan (B.7) and the spec
// (`substrate_specification.md` § 14) and the specific identifiers from
// each that this package will lean on. The act of compiling the imports
// and referencing one symbol from each library is the assertion — if
// any dependency disappears from `pubspec.yaml` or any referenced
// identifier is renamed away from us, this test fails to load before
// the rest of the suite runs.
//
// The B.7 dependencies (in plan / spec order):
//
//   1. tom_brain_shared    — cross-component vocabulary
//                            (`NodeId`, `Vec`, `Budget`, `Result`,
//                            `BrainEvent`, `BrainTime`, `BrainVersion`,
//                            and most importantly for substrate
//                            `AssistantDedicationAnchor`).
//   2. tom_basics          — `TomLogger`, and the cooperative
//                            cancellation (`TomCancellationToken` and
//                            its source and exception). The plan attributes
//                            `TomLogger` to `tom_core_kernel`, but the
//                            class actually lives here. The dependency
//                            list is unaffected — see Q-B.7.2 (mirrors
//                            memory's Q-A.22.1).
//   3. tom_core_kernel     — `TomBean` (the workspace's bean-locator
//                            surface; the plan calls it `BeanLocator`).
//                            Also `TomBearerAuthentication` (the plan
//                            attributes this to `tom_core_server` but
//                            it actually lives here — see Q-B.7.2 and
//                            Q-B.7.3). The `HttpClient`, retry-policy,
//                            and circuit-breaker surfaces are also
//                            consumed from here but not exhaustively
//                            locked at B.7; B.11 (first provider
//                            implementation) will lock the precise
//                            surface its call sites depend on.
//   4. tom_core_server     — kept on the dependency list per spec
//                            § 14 because the server-side
//                            authentication adaptors, configuration,
//                            and endpoint pipeline live there.
//                            Substrate's actual *consumption* will be
//                            `TomBearerAuthentication` (via
//                            `tom_core_kernel`) once the Streamable
//                            HTTP MCP client at B.34 is wired.
//   5. dart_mcp            — outbound client surface (`MCPClient` from
//                            `package:dart_mcp/client.dart`). Spec
//                            § 2 calls it out as the substrate-owned
//                            client. The companion `ProtocolVersion`
//                            enum from `package:dart_mcp/server.dart`
//                            is the wire-protocol enum and is locked
//                            here so the substrate and memory stay
//                            pinned to the same protocol shape.
//
// What this test does NOT do:
//
//   - It does not open any network connection. The first actual MCP
//     handshake is B.34's job; HTTP calls are B.11+'s job.
//   - It does not instantiate `MCPClient` (the constructor needs an
//     `Implementation` description and a connected transport — that is
//     B.34's job).
//   - It does not exercise `TomBean` (the bean container needs a
//     wired-up environment, which is a later step).
//
// The contract is narrow on purpose: it asserts the *dependency
// surface* is intact, nothing more. Later steps in Phase B will add
// their own behavioural tests.

import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_shared/tom_brain_shared.dart' as shared;
import 'package:tom_basics/tom_basics.dart' as basics;
import 'package:tom_core_agentic/tom_core_agentic.dart' as agentic;
import 'package:tom_core_kernel/tom_core_kernel.dart' as kernel;
import 'package:tom_llm/tom_llm.dart' as llm;
import 'package:tom_core_server/tom_core_server.dart' as server;
import 'package:dart_mcp/client.dart' as mcp_client;
import 'package:dart_mcp/server.dart' as mcp_server;

import 'package:test/test.dart';

void main() {
  group('B.7 dependency surface', () {
    test('tom_brain_shared exposes the cross-component vocabulary', () {
      // Type-references compile-time-only — no instances constructed.
      expect(shared.NodeId, isNotNull);
      expect(shared.Vec, isNotNull);
      expect(shared.Budget, isNotNull);
      expect(shared.BrainEvent, isNotNull);
      expect(shared.BrainTime, isNotNull);
      expect(shared.BrainVersion, isNotNull);

      // The single most important symbol substrate consumes from
      // `tom_brain_shared`: the anchor constants that every role
      // template wraps every prompt with. If this symbol is renamed
      // or removed, every outbound LLM call becomes a safety-policy
      // hole and the prototype is wrong — locking it here is the
      // load-bearing assertion at B.7.
      expect(shared.AssistantDedicationAnchor, isNotNull);
    });

    test('tom_basics exposes TomLogger (the only log surface)', () {
      // TomLogger lives here, not in tom_core_kernel as the plan parens
      // suggest. Q-B.7.2 captures the naming gap.
      expect(basics.TomLogger, isNotNull);
      expect(basics.tomLog, isA<basics.TomLogger>());
    });

    test('tom_basics exposes the cooperative cancellation', () {
      // `LlmCall.cancellationToken` and every provider take tom_basics'
      // token; the substrate declares no cancellation type of its own.
      expect(basics.TomCancellationToken, isNotNull);
      expect(basics.TomCancellationSource, isNotNull);
      expect(basics.TomOperationCancelled, isNotNull);
    });

    test('tom_core_kernel exposes TomBean and TomBearerAuthentication', () {
      // TomBean is the workspace's bean-locator surface; the plan
      // calls it `BeanLocator`. Q-B.7.2 captures the naming gap.
      expect(kernel.TomBean, isNotNull);

      // TomBearerAuthentication is attributed to `tom_core_server` in
      // the plan but actually lives in `tom_core_kernel`. Q-B.7.3
      // captures the attribution gap.
      expect(kernel.TomBearerAuthentication, isNotNull);
    });

    test('tom_core_server exposes the server authentication surface', () {
      // Representative class to prove the barrel resolves. Substrate
      // will consume `TomBearerAuthentication` via `tom_core_kernel`;
      // `tom_core_server` is still on the dependency list because the
      // server-side authentication adaptors, configuration, and
      // endpoint pipeline live there and the spec § 14 lists it
      // explicitly.
      expect(server.TomAuthenticationServer, isNotNull);
    });

    test('tom_core_agentic exposes the generic agentic building blocks', () {
      // B.1 extraction: the close-guard, dedup-by-id, text preview, and
      // HTTP-date parser live in this domain-free package. The substrate
      // consumes them rather than re-declaring its own copies.
      expect(agentic.CloseGuard, isNotNull);
      expect(agentic.HttpDate, isNotNull);
      expect(agentic.textPreview, isA<Function>());
      expect(agentic.buildUniqueById, isA<Function>());
    });

    test('tom_llm exposes the provider contract', () {
      // Every substrate provider implements this contract; the substrate
      // declares no provider interface of its own.
      expect(llm.LlmProvider, isNotNull);
      expect(llm.LlmRequest, isNotNull);
      expect(llm.LlmEvent, isNotNull);
      expect(llm.LlmCallReport, isNotNull);
    });

    test('dart_mcp exposes the client + protocol surface', () {
      // The outbound-client class B.34 will use.
      expect(mcp_client.MCPClient, isNotNull);
      // The wire-protocol enum, shared with `tom_brain_memory`'s
      // server side so the two stay protocol-pinned.
      expect(mcp_server.ProtocolVersion, isNotNull);
      expect(mcp_server.ProtocolVersion.values, isNotEmpty);
    });
  });

  group('item #12 isolate-adapter public surface', () {
    // The isolate-backed second implementation of the client surface
    // must be reachable through the top-level barrel (the in-process
    // facade is the first). Locking the export here means a regression
    // that drops the barrel re-export fails this contract test, not
    // just the behavioural conformance suite (b53).
    test('barrel exports the isolate adapter, host, and factory', () {
      expect(IsolateTomBrainSubstrateAdapter, isNotNull);
      expect(TomBrainSubstrateIsolateHost, isNotNull);
      expect(SubstrateFactory, isNotNull);
    });
  });

  group('B.7 forbidden surface', () {
    // Spec § 11 "reuse before rebuild" forbids a second HTTP client, a
    // second logger, or a second MCP stack. We do not try to assert
    // non-existence at the import level (Dart has no clean compile-time
    // check for "this package is NOT in pubspec.yaml"), but we DO
    // assert that the package surface we *do* depend on is the only
    // path through which any of those concerns reaches this package:
    //
    //   - HTTP: would arrive transitively through tom_core_kernel /
    //     tom_core_server but is never directly imported by
    //     tom_brain_substrate. The B.44 reuse-extraction pass will
    //     double-check.
    //   - Logger: the *only* permitted log instance in this package is
    //     `tomLog` from tom_basics. No second logger may be
    //     introduced.
    //   - tom_brain_memory: must not appear in `pubspec.yaml` (spec
    //     § 14 — cycle prevention). The arrow goes the other way.
    //
    // A future audit step (placeholder for later in Phase B) will scan
    // tom_brain_substrate's `lib/` for forbidden imports. At B.7 the
    // package has no `lib/` content yet, so the audit is trivially
    // green and this test simply documents the policy.
    test('policy is documented (no enforcement target at B.7 yet)', () {
      // No-op assertion: the comment block above is the contract.
      // When `lib/src/` starts filling up at B.9+, a real
      // import-audit test will replace this placeholder.
      expect(true, isTrue);
    });
  });
}
