// C.14 generated-bridge contract test.
//
// Plan step C.14: "Run `dart run build_runner build`. Verify generated
// bridges compile and register with tom_core_d4rt."
//
// This test is the executable acceptance check for that step. It proves
// three things about the output of `tom_d4rt_generator` (run via
// build_runner against `build.yaml`, C.11) and the hand-authored
// `BrainBridges` registrar (C.14, Q-C.14.1):
//
//   1. COMPILES — the generated `*.b.dart` files and the registrar are
//      part of the package's import graph (this test imports them; if
//      they did not compile, the suite would not load). The expected
//      generator outputs are present and the broken dartscript / relaxer
//      files are absent.
//   2. STRUCTURE — the generated delegating `AllBridge` exposes exactly
//      the authored bridged classes (`MemoryBridge`, `SubstrateBridge`,
//      and the substrate failure carrier `LlmCompletionFailure` at
//      C.12/C.13; `ToolBridge` at Extension F step 6; `McpBridge` at
//      Extension F step 8; `VsCodeScriptingBridge` at Extension F step 14)
//      with their canonical source URIs.
//   3. REGISTERS — `BrainBridges.register(D4rt())` registers those
//      classes with a real D4rt interpreter (the tom_core_d4rt
//      registration layer), and a d4rt script imported under a bridge
//      library path resolves the registered class. A fresh, unregistered
//      interpreter fails the same resolution — the negative control that
//      proves it is registration, not leniency, doing the work.
//
// What this test does NOT do: it does not call instance methods on the
// bridges against in-memory doubles — that round-trip is C.15. The
// C.12/C.13 native tests already exercise the primitive⇄domain
// conversions directly.

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_d4rt/d4rt.dart';

import 'package:tom_brain_procedure_prototype/src/bridges/brain_bridges.b.dart';
import 'package:tom_brain_procedure_prototype/src/bridges/brain_bridges_registrar.dart';

void main() {
  group('C.14 generated bridge output — files', () {
    test('expected generator outputs exist under lib/src/bridges/', () {
      for (final name in const <String>[
        'brain_bridges.b.dart', // delegating barrel (AllBridge)
        'package_tom_brain_procedure_prototype_bridges.b.dart', // per-package
        'd4rt_bridges.b.dart', // generateBarrel output
        'bridges_trigger.b.dart', // regeneration trigger
      ]) {
        expect(
          File('lib/src/bridges/$name').existsSync(),
          isTrue,
          reason: 'generator must produce lib/src/bridges/$name',
        );
      }
    });

    test('the non-compiling dartscript / relaxer files are NOT produced', () {
      // Q-C.14.1: generateDartscript is off because the 1.8.24 dartscript
      // does not compile (it imports a never-written relaxers.b.dart and
      // calls an unemitted subPackageBarrels()). Guard against a
      // regression that turns the feature back on.
      expect(File('lib/src/bridges/dartscript.b.dart').existsSync(), isFalse,
          reason: 'dartscript.b.dart must not be generated (Q-C.14.1).');
      expect(File('lib/src/bridges/relaxers.b.dart').existsSync(), isFalse,
          reason: 'relaxers.b.dart is never written by the 1.8.24 builder.');
    });

    test('per-package generator output stays inside lib/src/bridges/', () {
      // libraryPath is pinned so the generator does not introduce a
      // tenth lib/src/ subfolder (keeps the C.8 inventory intact).
      expect(
        Directory('lib/src/d4rt_library_bridges').existsSync(),
        isFalse,
        reason: 'libraryPath=lib/src/bridges must suppress the default '
            'lib/src/d4rt_library_bridges/ folder.',
      );
    });
  });

  group('C.14 generated bridge output — structure', () {
    test('AllBridge exposes exactly the six authored bridged classes', () {
      final names = AllBridge.bridgeClasses().map((b) => b.name).toSet();
      expect(
        names,
        equals(<String>{
          'MemoryBridge',
          'SubstrateBridge',
          'LlmCompletionFailure',
          'ToolBridge',
          'McpBridge',
          'VsCodeScriptingBridge',
        }),
        reason: 'C.12 MemoryBridge + C.13 SubstrateBridge (and its '
            'LlmCompletionFailure carrier) + Extension F step 6 ToolBridge + '
            'Extension F step 8 McpBridge + Extension F step 14 '
            'VsCodeScriptingBridge must all be bridged.',
      );
    });

    test('classSourceUris map each class to its canonical source file', () {
      final uris = AllBridge.classSourceUris();
      expect(
        uris['MemoryBridge'],
        'package:tom_brain_procedure_prototype/src/bridges/memory_bridge.dart',
      );
      expect(
        uris['SubstrateBridge'],
        'package:tom_brain_procedure_prototype/src/bridges/substrate_bridge.dart',
      );
      expect(
        uris['LlmCompletionFailure'],
        'package:tom_brain_procedure_prototype/src/bridges/substrate_bridge.dart',
      );
      expect(
        uris['ToolBridge'],
        'package:tom_brain_procedure_prototype/src/bridges/tool_bridge.dart',
      );
      expect(
        uris['McpBridge'],
        'package:tom_brain_procedure_prototype/src/bridges/mcp_bridge.dart',
      );
      expect(
        uris['VsCodeScriptingBridge'],
        'package:tom_brain_procedure_prototype/src/bridges/'
            'vscode_scripting_bridge.dart',
      );
    });

    test('the substrate bridge advertises its instance method surface', () {
      // Locate the SubstrateBridge definition and confirm the four
      // primitive-API methods (C.13) survived generation.
      final substrate =
          AllBridge.bridgeClasses().firstWhere((b) => b.name == 'SubstrateBridge');
      expect(
        substrate.methods.keys,
        containsAll(<String>['llm', 'embed', 'search', 'fetch']),
      );
    });

    test('the memory bridge advertises its instance method surface', () {
      final memory =
          AllBridge.bridgeClasses().firstWhere((b) => b.name == 'MemoryBridge');
      expect(
        memory.methods.keys,
        containsAll(<String>[
          'recall',
          'persist',
          'edge',
          'proposeNodeType',
          'stackList',
          'stackCreate',
          'stackPush',
          'stackPeek',
          'stackPop',
          'stackUpdate',
          'stackRemove',
        ]),
      );
    });
  });

  group('C.14 generated bridge output — registers with the interpreter', () {
    test('BrainBridges.register completes without throwing', () {
      expect(() => BrainBridges.register(D4rt()), returnsNormally);
    });

    test('a registered bridged class resolves inside a d4rt script', () async {
      final interpreter = D4rt();
      BrainBridges.register(interpreter);
      // Reading a registered static getter requires the class to resolve
      // under the substrate library path. No instance method is called,
      // so this stays inside C.14's "register" scope (vs. C.15's
      // method round-trip).
      final role = await interpreter.execute(
        source: '''
import '${BrainBridges.substrateLibrary}';
String main() => SubstrateBridge.defaultRole;
''',
      );
      expect(role, 'assistant_to_user');
    });

    test('the memory bridge resolves as a type after registration', () async {
      final interpreter = D4rt();
      BrainBridges.register(interpreter);
      final result = await interpreter.execute(
        source: '''
import '${BrainBridges.memoryLibrary}';
bool main() {
  Object? x = 0;
  return x is MemoryBridge;
}
''',
      );
      // 0 is not a MemoryBridge, so the answer is false — but evaluating
      // the `is` requires MemoryBridge to be a resolvable registered type.
      expect(result, isFalse);
    });

    test('an unregistered interpreter cannot resolve the bridged type', () {
      // Negative control: without registration the same script must fail
      // to resolve MemoryBridge — proving registration (not interpreter
      // leniency) is what makes the positive case work.
      final bare = D4rt();
      expect(
        () => bare.execute(
          source: '''
import '${BrainBridges.memoryLibrary}';
bool main() {
  Object? x = 0;
  return x is MemoryBridge;
}
''',
        ),
        throwsA(anything),
      );
    });
  });
}
