// E.7 dependency-surface contract test.
//
// Locks the runtime dependencies named in the plan (E.7) and the access
// spec (`tom_brain_access_specification.md`) and the specific
// identifiers from each that this package will lean on. The act of
// compiling the imports and referencing one symbol from each library is
// the assertion — if any dependency disappears from `pubspec.yaml` or
// any referenced identifier is renamed away from us, this test fails to
// load before the rest of the suite runs.
//
// The E.7 dependencies (in plan order):
//
//   1. tom_brain_shared    — cross-component vocabulary. The access layer
//                            *produces* the `Access` object (and the
//                            field types it references — `InboundRequest`,
//                            `OutboundChunk`, `DeliverCallback`,
//                            `ResolvedIdentity`, `Session`, `Persona`) the
//                            dispatcher consumes, plus the `InboundKinds`
//                            vocabulary the kind-hint classifier (E.33)
//                            writes. The general vocabulary (`NodeId`,
//                            `Vec`, `Budget`, `BrainEvent`) is also locked.
//   2. tom_brain_procedure
//                          — INTERFACE BOUNDARY ONLY. The access layer
//                            hands every inbound request to the
//                            dispatcher's single entry point
//                            `Dispatcher.accept(Access)` (D.14). Locking
//                            `Dispatcher` here is the load-bearing
//                            assertion: it is the *only* surface the edge
//                            touches on the procedure package. The engine,
//                            memory bridge, and substrate bridge are never
//                            imported directly.
//   3. tom_basics          — `TomLogger` / `tomLog`. The plan's E.7
//                            parenthetical does not name a logger; the
//                            workspace baseline supplies the only one
//                            permitted at this layer.
//   4. tom_core_kernel     — `TomBean` (the workspace's bean-locator
//                            surface; the plan calls it `BeanLocator`) and
//                            `TomBearerAuthentication`. The plan's E.7
//                            parenthetical attributes
//                            `TomBearerAuthentication` to `tom_core_server`
//                            but the class actually lives here (same
//                            finding as substrate's Q-B.7.3; logged
//                            Q-E.7.2). The `HttpClient` retry / circuit
//                            breaker surface is also consumed from here
//                            (the E.53/E.58 conformance client) but is not
//                            exhaustively locked at E.7 — E.53 will lock
//                            the precise surface its call sites depend on.
//   5. tom_core_server     — the inbound HTTP surface. The plan's E.7
//                            parenthetical names `Endpoint` /
//                            `EndpointPipeline`; the real symbols are
//                            `Tom`-prefixed (`TomEndpointBase`,
//                            `TomEndpointHandler`), logged Q-E.7.2. The
//                            OpenAI adapter (E.11) mounts `/v1/` against
//                            this surface (shelf + router confirmed at
//                            E.3). `TomBearerAuthentication` is re-exported
//                            through this barrel from `tom_core_kernel`.
//   6. tom_chattools       — the Telegram adapter (E.19–E.23): `ChatApi`
//                            (the abstract surface; the plan's `ChatAPI`
//                            casing is corrected to `ChatApi` per Q-E.4.1)
//                            and `TelegramChatConfig` (long-polling). The
//                            E.4 pin `^1.0.2` is adopted verbatim.
//
// What this test does NOT do:
//
//   - It does not start any HTTP server, open any socket, or connect to
//     Telegram. The first adapter behaviour is E.11 (OpenAI) / E.19
//     (Telegram); the first real-wire conformance client is E.53.
//   - It does not instantiate `Dispatcher`, `TomEndpointHandler`,
//     `ChatApi`, or `TomBearerAuthentication` (each needs a wired-up
//     environment that later steps supply).
//   - It does not assert the absence of forbidden deps at the import
//     level (Dart has no clean compile-time "this package is NOT in
//     pubspec.yaml" check); the forbidden-surface policy is documented in
//     the second group below and enforced by `pubspec.yaml` review until
//     `lib/src/` fills up at E.8+ and a real import-audit test replaces
//     the placeholder.
//
// The contract is narrow on purpose: it asserts the *dependency surface*
// is intact, nothing more. Later steps in Phase E add their own
// behavioural tests.

// ignore: unused_import
import 'package:tom_brain_access/tom_brain_access.dart';

import 'package:tom_brain_shared/tom_brain_shared.dart' as shared;
import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    as procedure;
import 'package:tom_basics/tom_basics.dart' as basics;
import 'package:tom_core_kernel/tom_core_kernel.dart' as kernel;
import 'package:tom_core_server/tom_core_server.dart' as server;
import 'package:tom_chattools/tom_chattools.dart' as chattools;
// Added at E.9: the CLI tool framework the running process is built on.
import 'package:tom_build_base/tom_build_base_v2.dart' as buildbase;
// Added at E.11 (Q-E.3.2 strategy 2): the OpenAI `/v1/` adapter is mounted
// as a raw `shelf_router.Router`, so shelf + shelf_router are now DIRECT
// deps (Q-E.3.1 / Q-E.7.1).
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart' as shelf_router;
// Added at E.44: the whole-process YAML config loader parses its `access:`
// section via `package:yaml` (the way every other Tom Brain loader, and
// `tom_build_base` itself, parses YAML — AC-11). Now a DIRECT dep.
import 'package:yaml/yaml.dart' as yaml;

import 'package:test/test.dart';

void main() {
  group('E.7 dependency surface', () {
    test('tom_brain_shared exposes the cross-component vocabulary', () {
      // General vocabulary — type-references are compile-time-only.
      expect(shared.NodeId, isNotNull);
      expect(shared.Vec, isNotNull);
      expect(shared.Budget, isNotNull);
      expect(shared.BrainEvent, isNotNull);

      // The access-specific shape the edge *produces* and the dispatcher
      // consumes. `Access` is the single most important symbol the access
      // layer binds against in shared — if it is renamed or removed, the
      // edge cannot hand work to the dispatcher and the prototype is
      // wrong. The field types and the inbound-kind vocabulary are locked
      // alongside it.
      expect(shared.Access, isNotNull);
      expect(shared.InboundRequest, isNotNull);
      expect(shared.OutboundChunk, isNotNull);
      expect(shared.ResolvedIdentity, isNotNull);
      expect(shared.Session, isNotNull);
      expect(shared.Persona, isNotNull);
      expect(shared.InboundKinds, isNotNull);
    });

    test('tom_brain_procedure exposes the Dispatcher entry', () {
      // The ONLY surface the access layer touches on the procedure
      // package: `Dispatcher.accept(Access)` (D.14). Locking it here is
      // the interface-boundary assertion — the edge never imports the
      // engine, the memory bridge, or the substrate bridge directly.
      expect(procedure.Dispatcher, isNotNull);
    });

    test('tom_basics exposes TomLogger (the only log surface)', () {
      expect(basics.TomLogger, isNotNull);
      expect(basics.tomLog, isA<basics.TomLogger>());
    });

    test('tom_core_kernel exposes TomBean and TomBearerAuthentication', () {
      // TomBean is the workspace's bean-locator surface; the plan calls
      // it `BeanLocator`. Q-E.7.2 captures the naming gap.
      expect(kernel.TomBean, isNotNull);

      // TomBearerAuthentication is attributed to `tom_core_server` in the
      // plan's E.7 parenthetical but actually lives in `tom_core_kernel`
      // (re-exported through the server barrel). Q-E.7.2 captures the
      // attribution gap — same as substrate's Q-B.7.3.
      expect(kernel.TomBearerAuthentication, isNotNull);
    });

    test('tom_core_server exposes the endpoint pipeline surface', () {
      // The plan's E.7 parenthetical names `Endpoint` / `EndpointPipeline`;
      // the real symbols are `Tom`-prefixed. `TomEndpointBase` is the
      // endpoint contract; `TomEndpointHandler` is the pipeline. The
      // OpenAI adapter (E.11) mounts `/v1/` against this surface. Q-E.7.2
      // captures the naming gap.
      expect(server.TomEndpointBase, isNotNull);
      expect(server.TomEndpointHandler, isNotNull);

      // TomBearerAuthentication is re-exported through this barrel from
      // tom_core_kernel — the access layer can reach it either way.
      expect(server.TomBearerAuthentication, isNotNull);
    });

    test('tom_chattools exposes ChatApi + TelegramChatConfig', () {
      // The Telegram adapter (E.19–E.23) binds against the abstract
      // `ChatApi` surface (the plan's `ChatAPI` casing corrected to
      // `ChatApi`, Q-E.4.1) and `TelegramChatConfig` (long-polling). The
      // E.23/E.54 loopback `implements ChatApi` (E.5 decision).
      expect(chattools.ChatApi, isNotNull);
      expect(chattools.TelegramChatConfig, isNotNull);
    });

    test('tom_build_base exposes the v2 tool framework (added at E.9)', () {
      // The workspace rule: every CLI tool is built on `tom_build_base`'s
      // `ToolDefinition` + `ToolRunner`. The access prototype is the
      // running process, so its `bin/` entry point consumes the v2 tool
      // framework. Locking these symbols guards the entry point against an
      // upstream rename.
      expect(buildbase.ToolDefinition, isNotNull);
      expect(buildbase.ToolRunner, isNotNull);
      expect(buildbase.CommandExecutor, isNotNull);
      expect(buildbase.ToolResult, isNotNull);
    });

    test('yaml exposes the config-loader surface (added at E.44)', () {
      // The whole-process YAML config loader (`AccessConfigLoader`, E.44)
      // parses its `access:` section via `loadYaml` / `YamlMap` — the same
      // plumbing substrate / memory / engine / dispatcher loaders use, and
      // the way `tom_build_base` itself parses YAML (AC-11). Locking these
      // guards the loader against an upstream rename.
      expect(yaml.loadYaml, isNotNull);
      expect(yaml.YamlMap, isNotNull);
    });

    test('shelf + shelf_router expose the routing surface (added at E.11)',
        () {
      // The OpenAI `/v1/` adapter (E.11) is mounted as a raw
      // `shelf_router.Router` (Q-E.3.2 strategy 2), so these are now DIRECT
      // deps rather than transitive-via-`tom_core_server` (Q-E.3.1 /
      // Q-E.7.1). Locking `Handler` (the mount contract), `Request` /
      // `Response` (the wire types the adapter speaks), and `Router` (the
      // route table) guards the adapter against an upstream rename.
      expect(shelf.Handler, isNotNull);
      expect(shelf.Request, isNotNull);
      expect(shelf.Response, isNotNull);
      expect(shelf_router.Router, isNotNull);
    });
  });

  group('E.7 forbidden surface', () {
    // Scope discipline (pubspec comment block) forbids: a direct second
    // HTTP client (`http` / `dio` — `tom_core_kernel.HttpClient` is the
    // only outbound path), a second logger (`tomLog` only), a direct
    // `tom_brain_memory` / `tom_brain_substrate` dep (everything flows
    // through the dispatcher), and a direct `dart_mcp` dep (the edge
    // speaks OpenAI + Telegram only). `shelf` / `shelf_router` WERE held
    // out at E.7 and added as direct deps at E.11 once the mounting
    // strategy (Q-E.3.2 strategy 2) was decided.
    //
    // We do not assert non-existence at the import level (Dart has no
    // clean compile-time check for "this package is NOT in pubspec.yaml").
    // At E.7 the package has no `lib/` content yet, so an import audit is
    // trivially green; this test documents the policy until `lib/src/`
    // starts filling up at E.8+, at which point a real import-audit test
    // replaces this placeholder.
    test('policy is documented (no enforcement target at E.7 yet)', () {
      // No-op assertion: the comment block above and the pubspec
      // discipline block are the contract.
      expect(true, isTrue);
    });
  });
}
