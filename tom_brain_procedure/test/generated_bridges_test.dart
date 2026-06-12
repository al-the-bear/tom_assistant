// C.14 generated-bridge contract test.
//
// Plan step C.14: "Run `dart run build_runner build`. Verify generated
// bridges compile and register with tom_core_d4rt."
//
// This test is the executable acceptance check for that step. It proves
// three things about the output of `tom_d4rt_generator` (run via
// build_runner against `build.yaml`, C.11) and the generated
// `BrainBridges` registration entrypoint (`dartscript.b.dart`, re-enabled
// by plan-2 item #13a):
//
//   1. COMPILES — the generated `*.b.dart` files (including the
//      `dartscript.b.dart` registration entrypoint and `relaxers.b.dart`)
//      are part of the package's import graph (this test imports them; if
//      they did not compile, the suite would not load). All expected
//      generator outputs are present.
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

import 'package:tom_brain_procedure/src/bridges/brain_bridges.b.dart';
import 'package:tom_brain_procedure/src/bridges/bridge_libraries.dart';
import 'package:tom_brain_procedure/src/bridges/dartscript.b.dart';

void main() {
  group('C.14 generated bridge output — files', () {
    test('expected generator outputs exist under lib/src/bridges/', () {
      for (final name in const <String>[
        'brain_bridges.b.dart', // delegating barrel (AllBridge)
        'package_tom_brain_procedure_bridges.b.dart', // per-package
        'd4rt_bridges.b.dart', // generateBarrel output
        'bridges_trigger.b.dart', // regeneration trigger
        'dartscript.b.dart', // BrainBridges registration entrypoint (#13a)
        'relaxers.b.dart', // generic/relaxer factory stubs (#13a)
      ]) {
        expect(
          File('lib/src/bridges/$name').existsSync(),
          isTrue,
          reason: 'generator must produce lib/src/bridges/$name',
        );
      }
    });

    test('the hand-authored registrar is gone (#13a — no shim)', () {
      // #13a: tom_d4rt_generator 1.9.1 fixed the dartscript template, so the
      // generated dartscript.b.dart is now the registration entrypoint and
      // the hand-authored registrar is deleted with no shim. Guard against a
      // regression that re-introduces a parallel hand-authored registrar.
      expect(
        File('lib/src/bridges/brain_bridges_registrar.dart').existsSync(),
        isFalse,
        reason: 'brain_bridges_registrar.dart must be deleted (#13a, no shim).',
      );
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
    test('AllBridge exposes exactly the seven authored bridged classes', () {
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
          'BudgetView',
        }),
        reason: 'C.12 MemoryBridge + C.13 SubstrateBridge (and its '
            'LlmCompletionFailure carrier) + Extension F step 6 ToolBridge + '
            'Extension F step 8 McpBridge + Extension F step 14 '
            'VsCodeScriptingBridge + § 5.4.2 BudgetView (the read-only '
            'budget window) must all be bridged.',
      );
    });

    test('classSourceUris map each class to its canonical source file', () {
      final uris = AllBridge.classSourceUris();
      expect(
        uris['MemoryBridge'],
        'package:tom_brain_procedure/src/bridges/memory_bridge.dart',
      );
      expect(
        uris['SubstrateBridge'],
        'package:tom_brain_procedure/src/bridges/substrate_bridge.dart',
      );
      expect(
        uris['LlmCompletionFailure'],
        'package:tom_brain_procedure/src/bridges/substrate_bridge.dart',
      );
      expect(
        uris['ToolBridge'],
        'package:tom_brain_procedure/src/bridges/tool_bridge.dart',
      );
      expect(
        uris['McpBridge'],
        'package:tom_brain_procedure/src/bridges/mcp_bridge.dart',
      );
      expect(
        uris['VsCodeScriptingBridge'],
        'package:tom_brain_procedure/src/bridges/'
            'vscode_scripting_bridge.dart',
      );
      expect(
        uris['BudgetView'],
        'package:tom_brain_procedure/src/budget/budget_view.dart',
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
import '${BridgeLibraries.substrateLibrary}';
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
import '${BridgeLibraries.memoryLibrary}';
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
import '${BridgeLibraries.memoryLibrary}';
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
