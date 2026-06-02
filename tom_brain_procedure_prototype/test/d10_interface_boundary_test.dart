// Interface-boundary audit (Plan step D.10 — `tom_brain_procedure_prototype`
// depends on `tom_brain_memory` and `tom_brain_substrate` only at the
// interface boundary — never reaches into `lib/src/`).
//
// D.10 is a *confirmation* step. C.7's `dependency_surface_test.dart`
// import-locks the two client interfaces (`TomBrainMemoryClient`,
// `TomBrainSubstrateClient`) so the dependency exists at the type level;
// this test closes the negative half — that no source the prototype
// *authors* reaches past the public barrel into either dependency's
// `lib/src/` internals. The static scan is the load-bearing guard: it
// fails the moment a future edit (hand-written or regenerated) couples
// the engine to a memory/substrate implementation file.
//
// What "interface boundary only" means here, made precise:
//
//   1. Hand-written `lib/` + `bin/` source imports memory/substrate only
//      through the public barrels
//      (`package:tom_brain_memory/tom_brain_memory.dart`,
//      `package:tom_brain_substrate/tom_brain_substrate.dart`) — never a
//      `package:<dep>/src/...` path. This is the engine's own coupling
//      surface and it must stay at the barrel.
//
//   2. The only `lib/src/` reach-ins into memory/substrate anywhere in
//      the package are inside *generated* bridge files (`*.b.dart`, the
//      `// do not edit` artifacts the d4rt generator emits with
//      `ignore_for_file: implementation_imports`). The generator resolves
//      each bridged type to its declaring library, so it cannot use the
//      re-export barrel — this is an unavoidable, audited generator
//      artifact, not engine code.
//
//   3. Even the generated reach-ins stay at the *interface* boundary
//      semantically: they target only the two interface-client
//      declaration files (`tom_brain_memory_client.dart`,
//      `tom_brain_substrate_client.dart`) — never a concrete store /
//      facade / isolate-adapter implementation file. So no path — hand
//      written or generated — couples the engine to a concrete
//      implementation of memory or substrate.
//
// Interpretation note (recorded as Q-D.10.1): the plan text "never
// reaches into `lib/src/`" is read as the *semantic* interface boundary
// (consume the client interface, never a concrete implementation),
// enforced literally at the path level for the code we author and bounded
// to the interface-declaration files for the code the generator emits.
//
// The scan runs with the package root as the working directory (Dart's
// standard `dart test` CWD), matching `d7_scripts_tree_test.dart` and
// `dependency_surface_test.dart`.

import 'dart:io';

import 'package:test/test.dart';

/// Public barrels — the only memory/substrate import a hand-written file
/// may use.
const String _memoryBarrel = 'package:tom_brain_memory/tom_brain_memory.dart';
const String _substrateBarrel =
    'package:tom_brain_substrate/tom_brain_substrate.dart';

/// The two interface-client declaration files. A generated `lib/src/`
/// reach-in may only target one of these — never a concrete impl file.
const Set<String> _allowedGeneratedReachIns = {
  'package:tom_brain_memory/src/api/tom_brain_memory_client.dart',
  'package:tom_brain_substrate/src/api/tom_brain_substrate_client.dart',
};

/// A single `import`/`export` directive lifted from a source file.
class _Directive {
  _Directive(this.file, this.uri, this.isGenerated);
  final String file;
  final String uri;
  final bool isGenerated;
}

/// True when [file] is a generator artifact (basename `*.b.dart`, or the
/// canonical "Generated file, do not edit" banner on the first line).
bool _isGenerated(File file) {
  if (file.path.endsWith('.b.dart')) return true;
  final firstLine = file.readAsLinesSync().take(1).join();
  return firstLine.contains('Generated file, do not edit');
}

/// Extracts every `package:` import/export URI from [file].
Iterable<_Directive> _directivesOf(File file, bool generated) sync* {
  final re = RegExp(
    r'''^\s*(?:import|export)\s+['"](package:[^'"]+)['"]''',
    multiLine: true,
  );
  for (final m in re.allMatches(file.readAsStringSync())) {
    yield _Directive(file.path, m.group(1)!, generated);
  }
}

/// All `.dart` files under [root], if it exists.
List<File> _dartFiles(String root) {
  final dir = Directory(root);
  if (!dir.existsSync()) return const [];
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();
}

bool _isMemoryOrSubstrate(String uri) =>
    uri.startsWith('package:tom_brain_memory/') ||
    uri.startsWith('package:tom_brain_substrate/');

bool _reachesIntoSrc(String uri) =>
    uri.startsWith('package:tom_brain_memory/src/') ||
    uri.startsWith('package:tom_brain_substrate/src/');

void main() {
  late final List<_Directive> handWritten;
  late final List<_Directive> generated;

  setUpAll(() {
    handWritten = [];
    generated = [];
    for (final root in ['lib', 'bin']) {
      for (final file in _dartFiles(root)) {
        final gen = _isGenerated(file);
        for (final d in _directivesOf(file, gen)) {
          (gen ? generated : handWritten).add(d);
        }
      }
    }
  });

  group('D.10 interface boundary — hand-written source', () {
    test('lib/ + bin/ source files are present to audit', () {
      // Guard against the scan silently finding nothing (e.g. a broken
      // CWD) and reporting a false pass.
      expect(handWritten, isNotEmpty,
          reason: 'expected to find package imports in lib/ — is the CWD '
              'the package root?');
    });

    test('no hand-written file reaches into a memory/substrate lib/src/', () {
      final offenders =
          handWritten.where((d) => _reachesIntoSrc(d.uri)).toList();
      expect(
        offenders,
        isEmpty,
        reason: 'hand-written engine code must consume memory/substrate '
            'through the public barrel only; these reach into lib/src/: '
            '${offenders.map((o) => "${o.file} -> ${o.uri}").join("; ")}',
      );
    });

    test('every memory/substrate import is the public barrel', () {
      final offenders = handWritten
          .where((d) => _isMemoryOrSubstrate(d.uri))
          .where((d) => d.uri != _memoryBarrel && d.uri != _substrateBarrel)
          .toList();
      expect(
        offenders,
        isEmpty,
        reason: 'memory/substrate must be imported via '
            '"$_memoryBarrel" or "$_substrateBarrel"; offending: '
            '${offenders.map((o) => "${o.file} -> ${o.uri}").join("; ")}',
      );
    });

    test('at least one hand-written file consumes each barrel', () {
      // Positive proof the boundary is actually exercised, not vacuous.
      final uris = handWritten.map((d) => d.uri).toSet();
      expect(uris, contains(_memoryBarrel),
          reason: 'the engine must consume the memory client interface');
      expect(uris, contains(_substrateBarrel),
          reason: 'the engine must consume the substrate client interface');
    });
  });

  group('D.10 interface boundary — generated bridge artifacts', () {
    test('every memory/substrate lib/src/ reach-in lives in a generated file',
        () {
      // The whole package, not just hand-written code: any src-reach-in
      // that is NOT in a generated file is a contract breach.
      final all = [...handWritten, ...generated];
      final leaked = all
          .where((d) => _reachesIntoSrc(d.uri) && !d.isGenerated)
          .toList();
      expect(
        leaked,
        isEmpty,
        reason: 'a non-generated file reaches into memory/substrate '
            'lib/src/: '
            '${leaked.map((o) => "${o.file} -> ${o.uri}").join("; ")}',
      );
    });

    test('generated reach-ins target only the interface-client decls', () {
      final reachIns =
          generated.where((d) => _reachesIntoSrc(d.uri)).toList();
      // The bridge does reach in (generator artifact) — prove it does so
      // only to the two interface-client declaration files, never a
      // concrete store / facade / isolate-adapter implementation.
      expect(reachIns, isNotEmpty,
          reason: 'the generated bridge is expected to import the two '
              'interface-client declaration files');
      final offenders = reachIns
          .where((d) => !_allowedGeneratedReachIns.contains(d.uri))
          .toList();
      expect(
        offenders,
        isEmpty,
        reason: 'generated bridges may reach lib/src/ only for the two '
            'interface-client declarations '
            '($_allowedGeneratedReachIns); these reach a concrete impl: '
            '${offenders.map((o) => "${o.file} -> ${o.uri}").join("; ")}',
      );
    });

    test('both interface-client declarations are reached (drift guard)', () {
      // If memory or substrate moved its client interface, or the bridge
      // stopped wrapping one of them, this catches the drift.
      final reached =
          generated.where((d) => _reachesIntoSrc(d.uri)).map((d) => d.uri).toSet();
      expect(reached, containsAll(_allowedGeneratedReachIns),
          reason: 'the generated bridge must import both the memory and '
              'substrate interface-client declarations');
    });
  });
}
