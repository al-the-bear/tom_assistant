// C.7 dependency-surface contract test.
//
// Locks the seven runtime dependencies named in the plan (C.7) and the
// specific identifiers from each that the procedure prototype will lean
// on. For each, the act of compiling the import and referencing one
// symbol is the assertion — if a dependency disappears from
// `pubspec.yaml` or a referenced identifier is renamed away from us,
// this test fails to load before the rest of the suite runs.
//
// All seven are import-locked. The manifest-level group below covers what
// an import cannot express: that a dependency is *direct* rather than
// transitive, that a version floor holds, and that a package is absent.
// Two packages are asserted absent, for different reasons — one is out of
// scope, the other no longer exists.
//
// The C.7 dependencies (in plan order):
//
//   1. tom_brain_shared    — cross-component vocabulary (`NodeId`,
//                            `Vec`, `Budget`, `ProcedureId`, and the
//                            `AssistantDedicationAnchor` constants).
//   2. tom_brain_memory    — INTERFACE BOUNDARY ONLY (PE-10): the
//                            engine consumes `TomBrainMemoryClient`,
//                            never the concrete store or `lib/src/`.
//   3. tom_brain_substrate — INTERFACE BOUNDARY ONLY (PE-10): the
//                            engine consumes `TomBrainSubstrateClient`,
//                            never the concrete facade or `lib/src/`.
//   4. tom_basics          — `TomLogger` / `tomLog` (the only log
//                            surface permitted at this layer).
//   5. tom_core_kernel     — `TomBean` (the bean-locator surface).
//   6. tom_d4rt            — the sandboxed interpreter `D4rt` the host
//                            (C.16) runs procedure scripts on. The
//                            package's own generated bridge barrel
//                            registers against it; no separate
//                            bridge-registration package is involved.
//   7. tom_d4rt_dcli       — `D4rtCliApi`, the REPL/CLI base the host
//                            (C.16) composes.
//
// What this test does NOT do:
//
//   - It does not construct any of these types. The bridges (C.12–C.13)
//     and the host (C.16) are the first code that instantiates them.
//   - It does not import tom_brain_memory's / tom_brain_substrate's
//     concrete implementations — only the client interfaces, proving
//     the PE-10 interface boundary at the type level.
//
// The contract is narrow on purpose: it asserts the dependency surface
// is intact, nothing more. Later C-phase steps add behavioural tests.

import 'dart:io';

// ignore: unused_import
import 'package:tom_brain_procedure/tom_brain_procedure.dart';

import 'package:tom_brain_shared/tom_brain_shared.dart' as shared;
import 'package:tom_brain_memory/tom_brain_memory.dart' as memory;
import 'package:tom_brain_substrate/tom_brain_substrate.dart' as substrate;
import 'package:tom_basics/tom_basics.dart' as basics;
import 'package:tom_core_kernel/tom_core_kernel.dart' as kernel;
import 'package:tom_d4rt/tom_d4rt.dart' as d4rt;
import 'package:tom_d4rt_dcli/tom_d4rt_cli_api.dart' as dcli;

import 'package:test/test.dart';

void main() {
  group('C.7 dependency surface (import-locked)', () {
    test('tom_brain_shared exposes the cross-component vocabulary', () {
      // Type references are compile-time-only — no instances constructed.
      expect(shared.NodeId, isNotNull);
      expect(shared.Vec, isNotNull);
      expect(shared.Budget, isNotNull);
      expect(shared.ProcedureId, isNotNull);

      // The load-bearing safety symbol: every prompt the brain issues is
      // wrapped with the anchor. The engine carries `ProcedureId` and the
      // anchor through to the substrate bridge — locking the anchor here
      // keeps the safety contract visible at this layer.
      expect(shared.AssistantDedicationAnchor, isNotNull);
    });

    test('tom_brain_memory is consumed at the interface boundary only', () {
      // PE-10: the engine binds against the consumer-facing client
      // interface, never the concrete store. `TomBrainMemoryClient`
      // (A.78) is the shape MemoryBridge (C.12) wraps.
      expect(memory.TomBrainMemoryClient, isNotNull);
    });

    test('tom_brain_substrate is consumed at the interface boundary only', () {
      // PE-10: the engine binds against `TomBrainSubstrateClient`
      // (B.40), never `InProcessTomBrainSubstrate`. SubstrateBridge
      // (C.13) wraps this client.
      expect(substrate.TomBrainSubstrateClient, isNotNull);
    });

    test('tom_basics exposes TomLogger (the only log surface)', () {
      expect(basics.TomLogger, isNotNull);
      expect(basics.tomLog, isA<basics.TomLogger>());
    });

    test('tom_core_kernel exposes TomBean (bean-locator surface)', () {
      expect(kernel.TomBean, isNotNull);
    });

    test('tom_d4rt exposes the sandboxed interpreter D4rt', () {
      // The interpreter the host (C.16) runs procedure scripts on.
      expect(d4rt.D4rt, isNotNull);
    });

    test('tom_d4rt_dcli exposes D4rtCliApi (the REPL/CLI base)', () {
      // The surface `D4rtDcliHost` (C.16) composes. Locked through the
      // narrow `tom_d4rt_cli_api.dart` entry point rather than the full
      // barrel, so the test does not pull the dcli bridge stack.
      expect(dcli.D4rtCliApi, isNotNull);
    });
  });

  group('C.7 dependency surface (manifest-locked)', () {
    // Four facts an import cannot express. That a dependency is *direct*
    // rather than pulled in transitively — an import compiles either way,
    // so only the manifest proves it. That `tom_d4rt_dcli` clears its
    // version floor (>=1.15.0). And that `tom_core_server` and `tom_core_d4rt` are
    // absent: you cannot import a package to assert it is not there.
    late final String pubspec;

    setUpAll(() {
      // The test runs with CWD at the package root.
      pubspec = File('pubspec.yaml').readAsStringSync();
    });

    test('pubspec declares all seven C.7 runtime dependencies', () {
      const expected = <String>[
        'tom_brain_shared',
        'tom_brain_memory',
        'tom_brain_substrate',
        'tom_basics',
        'tom_core_kernel',
        'tom_d4rt',
        'tom_d4rt_dcli',
      ];
      for (final dep in expected) {
        expect(
          pubspec.contains(RegExp('^  $dep:', multiLine: true)),
          isTrue,
          reason: 'pubspec.yaml must declare runtime dependency "$dep" '
              '(C.7 plan list).',
        );
      }
    });

    test('tom_d4rt_dcli is pinned to the workspace constraint >=1.15.0', () {
      // The workspace floor for `D4rtCliApi`. Locked here so the host
      // (C.16) cannot silently resolve against an older CLI surface:
      // 1.15.0 bridges tom_todo_model 2.x (repeated todos) and the
      // scripting API 4 (and keeps ProjectInfo/WorkspaceInfo hidden, which
      // 1.1.6 introduced, so the bridge barrel re-exports do not collide).
      expect(
        pubspec.contains(RegExp(r'^  tom_d4rt_dcli:\s*">=1\.15\.0"', multiLine: true)),
        isTrue,
        reason: 'tom_d4rt_dcli must be pinned to >=1.15.0 (the repeated-todo '
            'bridges; a current tom_d4rt).',
      );
    });

    test('tom_core_server is NOT a dependency (scope discipline)', () {
      // The engine does no inbound HTTP and no MCP server, so
      // tom_core_server must not leak in as a direct dependency.
      expect(
        pubspec.contains(RegExp(r'^  tom_core_server:', multiLine: true)),
        isFalse,
        reason: 'tom_core_server is out of scope for the engine — memory '
            'owns the MCP server, access owns the inbound edge.',
      );
    });

    test('tom_core_d4rt is NOT a dependency (the package is gone)', () {
      // This one is not scope discipline — the package was deleted from
      // `tom_ai/core`, so a path dependency on it cannot resolve at all.
      // It was once the eighth entry of this surface, manifest-locked
      // rather than import-locked because no `lib/` source imported it,
      // and its disappearance is what this file caught. The positive
      // assertion could not survive the deletion, but the fact it was
      // guarding can: the host registers `BrainBridges` against
      // `tom_d4rt` directly (`dartscript.b.dart`, proven by
      // `generated_bridges_test.dart`), so there is no registry package
      // to re-adopt and re-adding one would be a regression rather than
      // a repair.
      expect(
        pubspec.contains(RegExp(r'^  tom_core_d4rt:', multiLine: true)),
        isFalse,
        reason: 'tom_core_d4rt was deleted from tom_ai/core — the generated '
            'bridge barrel registers against tom_d4rt directly, so nothing '
            'here needs a bridge-registration package.',
      );
    });
  });
}
