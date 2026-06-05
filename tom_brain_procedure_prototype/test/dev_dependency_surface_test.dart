// C.9 dev-dependency-surface contract test.
//
// Locks the two D4rt bridge-generation dev-dependencies the plan (C.9)
// adds, with the exact pins the C.5 record fixed as the single source of
// truth:
//
//   - tom_d4rt_generator: ^1.9.0   — the bridge generator. C.14 drives
//                                    its `d4rt_bridge_builder` builder
//                                    (factory `d4rtBridgeBuilder`) through
//                                    `dart run build_runner build`.
//                                    (Prototype-plan-2 item 1 re-pinned the
//                                    C.5 `^1.8.24` to the published `^1.9.0`.)
//   - build_runner:       ^2.10.4  — the build-runner the generator runs
//                                    under.
//
// Two complementary locks:
//
//   1. Import-locked — `tom_d4rt_generator` is a dev-dependency, so a test
//      may import it. We import its public builder entry point and
//      reference `d4rtBridgeBuilder`, the factory C.11's `build.yaml`
//      names. If the dependency vanishes or the factory is renamed, this
//      test fails to *load* before the rest of the suite runs. (Note: the
//      C.7 runtime test does the analogous thing for runtime deps; this
//      is the dev-dep analogue.) `build_runner` is a CLI toolchain with no
//      stable importable symbol to anchor on, so it is manifest-locked
//      only.
//
//   2. Manifest-locked — parses `pubspec.yaml` and asserts both pins are
//      declared in the `dev_dependencies:` block (not the runtime
//      `dependencies:` block). This catches: a removed dev-dep, a drifted
//      pin, and — critically — either pin leaking into the runtime
//      dependency set (which would put a build-time-only toolchain into
//      the engine's shipped surface, violating C.7 scope discipline).
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
      // The factory C.11's build.yaml references under
      // `targets.$default.builders.tom_d4rt_generator:d4rt_bridge_builder`.
      // A tear-off reference is compile-time-only — no Builder is
      // constructed here (that needs BuilderOptions, which is C.14's job).
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

    test('tom_d4rt_generator is a dev-dep pinned ^1.9.0 (prototype-plan-2 item 1)', () {
      expect(
        devBlock.contains(
            RegExp(r'^  tom_d4rt_generator:\s*\^1\.9\.0', multiLine: true)),
        isTrue,
        reason: 'Prototype-plan-2 item 1 re-pinned tom_d4rt_generator to the '
            'published ^1.9.0 (from the C.5 ^1.8.24); dev_dependencies must '
            'adopt it verbatim.',
      );
    });

    test('build_runner is a dev-dep pinned ^2.10.4 (the C.5 pin)', () {
      expect(
        devBlock.contains(
            RegExp(r'^  build_runner:\s*\^2\.10\.4', multiLine: true)),
        isTrue,
        reason: 'C.5 fixed build_runner: ^2.10.4 as the authoritative pin; '
            'C.9 must adopt it verbatim in dev_dependencies.',
      );
    });

    test('neither generation dev-dep leaks into the runtime block', () {
      // Scope discipline (C.7): the bridge-generation toolchain is
      // build-time only. If either pin appears in the runtime
      // dependencies: block it would ship in the engine's surface.
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
