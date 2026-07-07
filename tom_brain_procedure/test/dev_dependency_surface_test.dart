// C.9 dev-dependency-surface contract test.
//
// Locks the single D4rt bridge-generation dev-dependency the plan (C.9)
// adds, with the exact pin the C.5 record fixed as the single source of
// truth:
//
//   - tom_d4rt_generator: >=1.12.1 — the bridge generator. The build runs
//                                    its standalone `d4rtgen` CLI
//                                    (`dart run tom_d4rt_generator:d4rtgen`,
//                                    or the installed `d4rtgen` binary)
//                                    against the top-level `d4rtgen:` block
//                                    in `buildkit.yaml`. The CLI is faster
//                                    and more reliable than driving the
//                                    generator through `build_runner`, which
//                                    is therefore NOT a dev-dependency.
//                                    (Prototype-plan-2 item 1 re-pinned the
//                                    C.5 `^1.8.24` to `^1.9.0`; plan-2 item
//                                    #13a re-pinned it to `^1.9.1`, which
//                                    fixed the dartscript template so
//                                    `generateDartscript` could be re-enabled.)
//
// Two complementary locks:
//
//   1. Import-locked — `tom_d4rt_generator` is a dev-dependency, so a test
//      may import it. We import its public builder entry point and
//      reference `d4rtBridgeBuilder`, the same factory the CLI's
//      `BridgeConfig` path shares with the (now-retired) build_runner
//      builder. If the dependency vanishes or the factory is renamed, this
//      test fails to *load* before the rest of the suite runs. (Note: the
//      C.7 runtime test does the analogous thing for runtime deps; this
//      is the dev-dep analogue.)
//
//   2. Manifest-locked — parses `pubspec.yaml` and asserts the pin is
//      declared in the `dev_dependencies:` block (not the runtime
//      `dependencies:` block). This catches: a removed dev-dep, a drifted
//      pin, and — critically — the pin leaking into the runtime
//      dependency set (which would put a build-time-only toolchain into
//      the engine's shipped surface, violating C.7 scope discipline). It
//      also asserts `build_runner` is absent from the dev block: the
//      migration to the `d4rtgen` CLI dropped it, and a re-added
//      `build_runner` would signal a regression to the build_runner path.
//
// What this test does NOT do: it does not run the generator (that is
// C.14/C.15) and does not assert anything about the generated output.
// The contract is narrow on purpose — the dev-dependency *surface* is the
// code C.9 produces, and this file is its executable specification.

import 'dart:io';

import 'package:tom_d4rt_generator/builder.dart' show d4rtBridgeBuilder;

import 'package:test/test.dart';

void main() {
  group('C.9 dev-dependency surface (import-locked)', () {
    test('tom_d4rt_generator exposes the d4rtBridgeBuilder factory', () {
      // The factory the generator's `BridgeConfig` path shares between the
      // `d4rtgen` CLI and the (retired) build_runner builder. A tear-off
      // reference is compile-time-only — no Builder is constructed here.
      expect(d4rtBridgeBuilder, isNotNull);
      expect(d4rtBridgeBuilder, isA<Function>());
    });
  });

  group('C.9 dev-dependency surface (manifest-locked)', () {
    late final String pubspec;
    late final String runtimeBlock;
    late final String devBlock;

    setUpAll(() {
      // The test runs with CWD at the package root.
      pubspec = File('pubspec.yaml').readAsStringSync();

      // Split the manifest at the `dev_dependencies:` header so we can
      // assert which block each pin lives in. `dependencies:` is the
      // runtime block; everything from `dev_dependencies:` on is the dev
      // block. (`environment:` precedes `dependencies:`, so the runtime
      // block is the slice between the two headers.)
      final depsIdx = pubspec.indexOf(RegExp(r'^dependencies:', multiLine: true));
      final devIdx =
          pubspec.indexOf(RegExp(r'^dev_dependencies:', multiLine: true));
      expect(depsIdx, greaterThanOrEqualTo(0),
          reason: 'pubspec.yaml must have a runtime dependencies: block.');
      expect(devIdx, greaterThan(depsIdx),
          reason: 'dev_dependencies: must follow dependencies:.');

      runtimeBlock = pubspec.substring(depsIdx, devIdx);
      devBlock = pubspec.substring(devIdx);
    });

    test('tom_d4rt_generator is a dev-dep pinned >=1.12.1 (barrel-template fix)',
        () {
      expect(
        devBlock.contains(
            RegExp(r'^  tom_d4rt_generator:\s*">=1\.12\.1"', multiLine: true)),
        isTrue,
        reason: 'tom_d4rt_generator is pinned >=1.12.1. The 1.9.2..1.9.7 line '
            'fixed the dartscript/AllBridge template desync (the barrel surface '
            '— sourceLibraries/getImportBlock/subPackageBarrels — is emitted by '
            'the generator again), retiring the temporary hand-patch of '
            'brain_bridges.b.dart (HC-71); the constraint has since advanced to '
            '>=1.12.1. Verified 2026-07-07 (UB2): regenerating the bridges with '
            'the resolved generator reproduces the committed barrels '
            'byte-for-byte (statics intact), so no hand-patch remains. '
            'dev_dependencies must adopt the current pin verbatim.',
      );
    });

    test('build_runner is NOT a dev-dep (migrated to the d4rtgen CLI)', () {
      // The build no longer drives the generator through build_runner; it
      // runs the standalone `d4rtgen` CLI against buildkit.yaml. A re-added
      // build_runner dev-dep would signal a regression to the old path.
      expect(
        devBlock.contains(RegExp(r'^  build_runner:', multiLine: true)),
        isFalse,
        reason: 'build_runner was dropped when the build migrated to the '
            'd4rtgen CLI; it must not reappear in dev_dependencies.',
      );
    });

    test('the generation dev-dep does not leak into the runtime block', () {
      // Scope discipline (C.7): the bridge-generation toolchain is
      // build-time only. If the pin appears in the runtime dependencies:
      // block it would ship in the engine's surface.
      expect(
        runtimeBlock.contains(RegExp(r'^  tom_d4rt_generator:', multiLine: true)),
        isFalse,
        reason: 'tom_d4rt_generator is build-time only — it must not be a '
            'runtime dependency.',
      );
      expect(
        runtimeBlock.contains(RegExp(r'^  build_runner:', multiLine: true)),
        isFalse,
        reason: 'build_runner is build-time only — it must not be a runtime '
            'dependency.',
      );
    });
  });
}
