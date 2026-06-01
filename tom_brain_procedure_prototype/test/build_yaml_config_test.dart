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
//   3. Both C.11 target source files appear under `barrelFiles` -- the plan's
//      "Targets: bridges/memory_bridge.dart and bridges/substrate_bridge.dart",
//      resolved to the C.8 `lib/src/bridges/` layout.
//   4. The generated-output / barrel / dartscript paths and the
//      `registrationClass` are present (so C.16's host can call
//      `BrainBridges.register(d4rt)`).
//   5. `helpersImport` points at `package:tom_d4rt/tom_d4rt.dart` (C.3
//      convention 3 -- required for generated code to resolve the `D4` helper).
//   6. No STALE option keys leak in -- the C.3-flagged deltas (`barrelFile`
//      singular, the doc-only re-export knobs) must not appear, guarding against
//      a copy of the stale reference doc.
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
            RegExp(r'^\s*name:\s*tom_brain_procedure_prototype', multiLine: true)),
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
        buildYaml.contains(
            RegExp(r'^\s*-\s*lib/src/bridges/memory_bridge\.dart', multiLine: true)),
        isTrue,
        reason: 'C.11 target #1 (MemoryBridge source, C.12) must be a barrelFile.',
      );
      expect(
        buildYaml.contains(RegExp(
            r'^\s*-\s*lib/src/bridges/substrate_bridge\.dart',
            multiLine: true)),
        isTrue,
        reason:
            'C.11 target #2 (SubstrateBridge source, C.13) must be a barrelFile.',
      );
    });

    test('generated output / barrel / dartscript paths + registrationClass set',
        () {
      expect(
        buildYaml.contains(RegExp(
            r'^\s*outputPath:\s*lib/src/bridges/brain_bridges\.b\.dart',
            multiLine: true)),
        isTrue,
        reason: 'Per-module bridge output path must be set.',
      );
      expect(
        buildYaml.contains(
            RegExp(r'^\s*generateDartscript:\s*true', multiLine: true)),
        isTrue,
        reason: 'generateDartscript must be true so a registration class is '
            'emitted (C.16 calls BrainBridges.register(d4rt)).',
      );
      expect(
        buildYaml.contains(RegExp(
            r'^\s*dartscriptPath:\s*lib/src/bridges/dartscript\.b\.dart',
            multiLine: true)),
        isTrue,
        reason: 'dartscriptPath must be set when generateDartscript is true.',
      );
      expect(
        buildYaml.contains(
            RegExp(r'^\s*registrationClass:\s*BrainBridges', multiLine: true)),
        isTrue,
        reason: 'registrationClass names the single register() entry point.',
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
