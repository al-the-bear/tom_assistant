// C.11 build.yaml generator-config contract test.
//
// Plan step C.11 produces exactly one artifact: `build.yaml`, configuring
// `tom_d4rt_generator`'s `d4rt_bridge_builder` to bridge the engine's two
// source classes. This test is that config's executable specification.
//
// The contract is locked against the LIVE builder schema
// (`tom_d4rt_generator/lib/src/bridge_config.dart` -- BridgeConfig /
// ModuleConfig `fromJson`), recorded at C.3 as authoritative over the
// partly-stale `doc/bridgegenerator_user_reference.md`. The assertions cover:
//
//   1. The builder is registered + enabled under the exact key
//      `tom_d4rt_generator:d4rt_bridge_builder`.
//   2. `name` is the package name.
//   3. Both C.11 target source files appear under `barrelFiles` as canonical
//      `package:` URIs (`package:tom_brain_procedure/src/bridges/<x>.dart`) --
//      the plan's "Targets: bridges/memory_bridge.dart and
//      bridges/substrate_bridge.dart", resolved to the C.8 `lib/src/bridges/`
//      layout. The `package:` form is required so the generated registration
//      keys each bridge under the same URI a procedure script imports from.
//   4. The generated-output and barrel paths are present, and
//      `generateDartscript` is ON (re-enabled by plan-2 item #13a once
//      `tom_d4rt_generator 1.9.1` fixed the dartscript template — it now emits
//      `relaxers.b.dart` and `AllBridge.subPackageBarrels()`, so the generated
//      `dartscript.b.dart` compiles). The config carries a `dartscriptPath` and
//      `registrationClass: BrainBridges`; the hand-authored registrar is
//      deleted (no shim). `libraryPath` is pinned to `lib/src/bridges` so the
//      per-package generator output does not introduce a tenth `lib/src/` folder.
//   5. `helpersImport` points at `package:tom_d4rt/tom_d4rt.dart` (C.3
//      convention 3 -- required for generated code to resolve the `D4` helper).
//   6. No STALE option keys leak in -- the C.3-flagged deltas (`barrelFile`
//      singular, the doc-only re-export knobs) must not appear, guarding against
//      a copy of the stale reference doc.
//
// History note: at C.14 the generated `dartscript.b.dart` did not compile in
// `tom_d4rt_generator 1.8.24` (it imported a never-written `relaxers.b.dart`
// and called an unemitted `subPackageBarrels()`), so the feature was turned off
// and registration was carried by a hand-authored `BrainBridges`. Plan-2 item
// #13a re-enabled it: `1.9.1` fixed the template (it now writes
// `relaxers.b.dart` and emits `AllBridge.subPackageBarrels()`), the
// hand-authored registrar was deleted with no shim, and this test was revised
// in the same change to lock the `generateDartscript: true` contract.
//
// String/regex parsing (no `yaml` dependency) mirrors the C.7 / C.9 manifest
// contract tests: it keeps C.11 scoped to "create build.yaml" without a
// dependency add, and it fails loudly on any drift of the locked keys.
//
// What this test does NOT do: it does not run the generator (C.14) and asserts
// nothing about generated output (C.15). The config *surface* is the code C.11
// produces; that is all this file specifies.

import 'dart:io';

import 'package:test/test.dart';

void main() {
  group('C.11 build.yaml generator config', () {
    late final String buildYaml;

    setUpAll(() {
      // The test runs with CWD at the package root.
      final file = File('build.yaml');
      expect(file.existsSync(), isTrue,
          reason: 'C.11 must create build.yaml at the package root.');
      buildYaml = file.readAsStringSync();
    });

    test('registers the d4rt_bridge_builder and enables it', () {
      expect(
        buildYaml.contains(
            RegExp(r'^\s*tom_d4rt_generator:d4rt_bridge_builder:', multiLine: true)),
        isTrue,
        reason: 'The generator builder must be configured under its exact key.',
      );
      expect(
        buildYaml.contains(RegExp(r'^\s*enabled:\s*true', multiLine: true)),
        isTrue,
        reason: 'The builder must be explicitly enabled.',
      );
    });

    test('options.name is the package name', () {
      expect(
        buildYaml.contains(
            RegExp(r'^\s*name:\s*tom_brain_procedure', multiLine: true)),
        isTrue,
        reason: 'options.name must match the package name.',
      );
    });

    test('both C.11 target bridge sources are listed under barrelFiles', () {
      // The live schema uses `barrelFiles` (plural), not the stale `barrelFile`.
      expect(
        buildYaml.contains(RegExp(r'^\s*barrelFiles:', multiLine: true)),
        isTrue,
        reason: 'Live schema uses the plural `barrelFiles` key.',
      );
      expect(
        buildYaml.contains(RegExp(
            r'^\s*-\s*package:tom_brain_procedure/src/bridges/memory_bridge\.dart',
            multiLine: true)),
        isTrue,
        reason: 'C.11 target #1 (MemoryBridge source, C.12) must be a barrelFile '
            'as a package: URI (so generated registration keys it under the URI '
            'a procedure script imports from).',
      );
      expect(
        buildYaml.contains(RegExp(
            r'^\s*-\s*package:tom_brain_procedure/src/bridges/substrate_bridge\.dart',
            multiLine: true)),
        isTrue,
        reason:
            'C.11 target #2 (SubstrateBridge source, C.13) must be a barrelFile '
            'as a package: URI.',
      );
    });

    test('generated output + barrel paths set, dartscript ON (#13a)', () {
      expect(
        buildYaml.contains(RegExp(
            r'^\s*outputPath:\s*lib/src/bridges/brain_bridges\.b\.dart',
            multiLine: true)),
        isTrue,
        reason: 'Per-module bridge output path must be set.',
      );
      expect(
        buildYaml.contains(
            RegExp(r'^\s*generateBarrel:\s*true', multiLine: true)),
        isTrue,
        reason: 'generateBarrel must be true: the clean d4rt_bridges.b.dart '
            'barrel re-exports the delegating AllBridge.',
      );
      expect(
        buildYaml.contains(RegExp(
            r'^\s*barrelPath:\s*lib/src/bridges/d4rt_bridges\.b\.dart',
            multiLine: true)),
        isTrue,
        reason: 'barrelPath must be set when generateBarrel is true.',
      );
      // #13a: dartscript generation is ON since tom_d4rt_generator 1.9.1 fixed
      // the template. The generated dartscript.b.dart compiles and provides
      // `BrainBridges.register`; the hand-authored registrar is deleted.
      expect(
        buildYaml.contains(
            RegExp(r'^\s*generateDartscript:\s*true', multiLine: true)),
        isTrue,
        reason: 'generateDartscript must be true (#13a): 1.9.1 emits a '
            'compiling dartscript.b.dart (relaxers.b.dart + subPackageBarrels).',
      );
      expect(
        buildYaml.contains(RegExp(
            r'^\s*dartscriptPath:\s*lib/src/bridges/dartscript\.b\.dart',
            multiLine: true)),
        isTrue,
        reason: 'dartscriptPath must be set when generateDartscript is on, '
            'pinned inside lib/src/bridges (keeps the C.8 inventory intact).',
      );
      expect(
        buildYaml.contains(RegExp(
            r'^\s*registrationClass:\s*BrainBridges', multiLine: true)),
        isTrue,
        reason: 'registrationClass names the generated entrypoint class '
            '(BrainBridges) the host calls register() on.',
      );
      expect(
        buildYaml.contains(
            RegExp(r'^\s*libraryPath:\s*lib/src/bridges', multiLine: true)),
        isTrue,
        reason: 'libraryPath is pinned to lib/src/bridges so per-package '
            'generator output stays inside the existing folder (keeps the C.8 '
            'inventory intact).',
      );
    });

    test('helpersImport points at the tom_d4rt runtime (D4 helper)', () {
      expect(
        buildYaml.contains(RegExp(
            r'^\s*helpersImport:\s*package:tom_d4rt/tom_d4rt\.dart',
            multiLine: true)),
        isTrue,
        reason: 'C.3 convention 3: generated code resolves the D4 helper from '
            'package:tom_d4rt/tom_d4rt.dart.',
      );
    });

    test('no stale option keys from the partly-stale reference doc leak in', () {
      // The C.3 read flagged these as belonging only to the stale
      // `doc/bridgegenerator_user_reference.md`, not the live builder.
      expect(
        buildYaml.contains(RegExp(r'^\s*barrelFile:', multiLine: true)),
        isFalse,
        reason: 'Singular `barrelFile:` is the stale-doc key; the live builder '
            'uses plural `barrelFiles:`.',
      );
      expect(
        buildYaml.contains(RegExp(r'^\s*barrelImport:', multiLine: true)),
        isFalse,
        reason: 'C.11 lists source files directly; no `barrelImport` indirection.',
      );
      expect(
        buildYaml.contains(RegExp(r'^\s*importedBridges:', multiLine: true)),
        isFalse,
        reason: 'Q-C.3.3: primitive-typed signatures avoid cross-package '
            'bridged types, so no importedBridges is needed.',
      );
    });
  });
}
