// Step 12 guard — the low-level `sub.llm` substrate primitive is retired.
//
// Phase 5 / step 12 deleted the `llm` method from `SubstrateBridge` and removed
// it from the bridged primitive API. `sub.run` / `sub.send` are now the only
// substrate completion entry points. This file is the executable proof that no
// `sub.llm` low-level primitive survives anywhere in the shipped surface:
//
//   1. SURFACE — the generated `SubstrateBridge` advertises `send` + `run` and
//      no `llm` method (the catalog's completion entry points are exactly those
//      two).
//   2. CATALOG — `BridgedPrimitiveCatalog` no longer knows the bare `llm`
//      primitive; the substrate family lists `send`/`run` and not `llm`.
//   3. SCRIPTS — no system procedure body calls the removed `sub.llm(...)`
//      low-level form. (The high-level scripted sugar is spelled `subLlm(...)`;
//      the dotted `sub.llm(...)` spelling is no longer callable.)

import 'dart:io';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:tom_brain_procedure/src/bridges/brain_bridges.b.dart';
import 'package:test/test.dart';

void main() {
  group('Step 12 — `sub.llm` low-level primitive retired', () {
    test('the generated SubstrateBridge exposes send + run, never llm', () {
      final substrate = AllBridge.bridgeClasses()
          .firstWhere((b) => b.name == 'SubstrateBridge');
      expect(substrate.methods.keys, containsAll(<String>['send', 'run']),
          reason: 'send and run are the substrate completion entry points');
      expect(substrate.methods.keys, isNot(contains('llm')),
          reason: 'the low-level llm method was deleted');
    });

    test('the catalog no longer knows the bare `llm` primitive', () {
      expect(BridgedPrimitiveCatalog.isKnown('llm'), isFalse,
          reason: 'llm was removed from the substrate family');
      expect(BridgedPrimitiveCatalog.isKnown('send'), isTrue);
      expect(BridgedPrimitiveCatalog.isKnown('run'), isTrue);
      expect(BridgedPrimitiveCatalog.substrate, isNot(contains('llm')));
      expect(BridgedPrimitiveCatalog.substrate, containsAll(<String>['send', 'run']));
    });

    test('no system procedure body calls the removed `sub.llm(...)` form', () {
      final scripts = Directory('scripts');
      expect(scripts.existsSync(), isTrue,
          reason: 'run from the package root so scripts/ resolves');
      final offenders = <String>[];
      for (final entity in scripts.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final lineNo = <int>[];
        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (lines[i].contains('sub.llm(')) lineNo.add(i + 1);
        }
        if (lineNo.isNotEmpty) offenders.add('${entity.path}:$lineNo');
      }
      expect(offenders, isEmpty,
          reason: 'the only completion calls are sub.send / sub.run / subLlm');
    });
  });
}
