// D.9 manifest-wiring contract test.
//
// D.9 — "Wire the new sub-folders into the project manifest." For a Dart
// package the *project manifest* is `pubspec.yaml`; the
// `.tom_metadata/tom_master.yaml` reading is a no-op per policy override
// 5 (see Q-D.9.2). D.6–D.8 added three sub-folders to the project:
//
//   - lib/src/dispatcher/  (D.6) — the dispatcher half's module folder.
//   - scripts/system/      (D.7) — well-known shipped procedures.
//   - scripts/user/        (D.7) — optional user-authored procedures.
//   - scripts/system/answer_with_memory_v1.dart (D.8) — the stub route.
//
// A pure-Dart package has no `flutter: assets:` section, so the scripts
// tree needs no structural pubspec field — it ships because it is
// git-tracked and not excluded, and the lib/ folder auto-ships. D.9's
// deliverable is therefore the manifest *record* (the
// "Project structure manifest (Plan step D.9)" block in pubspec.yaml)
// plus this contract test that locks manifest ⇄ on-disk consistency:
// if a future pubspec rewrite drops the structure record, or a
// sub-folder is moved/removed, or the scripts tree is excluded from the
// shipped package, this test fails.
//
// The test is black-box at the package level — it reads the manifest,
// the barrel, the .gitignore, and the filesystem; it imports no
// `lib/src/`. It mirrors the manifest-locked style of
// `dependency_surface_test.dart`.

import 'dart:io';

import 'package:test/test.dart';

void main() {
  // The test runs with CWD at the package root.
  late final String pubspec;
  late final String barrel;
  late final String gitignore;

  setUpAll(() {
    pubspec = File('pubspec.yaml').readAsStringSync();
    barrel =
        File('lib/tom_brain_procedure_prototype.dart').readAsStringSync();
    final gitignoreFile = File('.gitignore');
    gitignore =
        gitignoreFile.existsSync() ? gitignoreFile.readAsStringSync() : '';
  });

  group('D.9 manifest ⇄ on-disk (the sub-folders D.6–D.8 added exist)', () {
    test('pubspec is this package, publish_to: none, versioned', () {
      expect(
        pubspec.contains(
            RegExp(r'^name:\s*tom_brain_procedure_prototype', multiLine: true)),
        isTrue,
        reason: 'the manifest must identify this package.',
      );
      expect(
        pubspec.contains(RegExp(r'^publish_to:\s*none', multiLine: true)),
        isTrue,
        reason: 'the prototype is path-consumed only (PE-10).',
      );
      expect(
        pubspec.contains(RegExp(r'^version:\s*\d', multiLine: true)),
        isTrue,
        reason: 'the manifest must carry a version.',
      );
    });

    test('lib/src/dispatcher/ exists (D.6)', () {
      expect(Directory('lib/src/dispatcher').existsSync(), isTrue);
    });

    test('scripts/system/ exists (D.7)', () {
      expect(Directory('scripts/system').existsSync(), isTrue);
    });

    test('scripts/user/ exists (D.7)', () {
      expect(Directory('scripts/user').existsSync(), isTrue);
    });

    test('answer_with_memory_v1.dart stub exists under scripts/system (D.8)',
        () {
      expect(
        File('scripts/system/answer_with_memory_v1.dart').existsSync(),
        isTrue,
      );
    });
  });

  group('D.9 manifest records the new sub-folders (project-structure block)',
      () {
    test('pubspec carries the D.9 project-structure manifest block', () {
      expect(
        pubspec.contains('Project structure manifest (Plan step D.9'),
        isTrue,
        reason: 'D.9 wires the new sub-folders into the manifest via the '
            'project-structure record block.',
      );
    });

    test('the block names each D.6–D.8 sub-folder', () {
      for (final path in const <String>[
        'lib/src/dispatcher/',
        'scripts/system/',
        'scripts/user/',
        'scripts/system/answer_with_memory_v1.dart',
      ]) {
        expect(
          pubspec.contains(path),
          isTrue,
          reason: 'the manifest structure block must name "$path".',
        );
      }
    });

    test('the block records the tom_master.yaml part as a no-op (override 5)',
        () {
      expect(
        pubspec.contains(RegExp(r'tom_master\.yaml')) &&
            pubspec.contains(RegExp(r'no-?op', caseSensitive: false)) &&
            pubspec.contains('policy override 5'),
        isTrue,
        reason: 'D.9 must record that the .tom_metadata/tom_master.yaml '
            'reading is a no-op per policy override 5.',
      );
    });
  });

  group('D.9 manifest surface wiring intact', () {
    test('top-level barrel re-exports the dispatcher module folder (D.6)', () {
      expect(
        barrel.contains(
            RegExp(r"export\s+'src/dispatcher/dispatcher\.dart';")),
        isTrue,
        reason: 'the package surface (the barrel) must expose the '
            'dispatcher folder wired in at D.6.',
      );
    });

    test('the scripts tree is not excluded from the shipped package', () {
      // The scripts/ tree is runtime data read via EngineConfig's default
      // paths. It ships because it is git-tracked and not gitignored. A
      // line that ignored it would silently drop the procedures from any
      // consumer that pulls the package — guard against that here.
      final ignoresScripts = gitignore.split('\n').any((line) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) return false;
        return trimmed == 'scripts' ||
            trimmed == 'scripts/' ||
            trimmed == '/scripts' ||
            trimmed == '/scripts/' ||
            trimmed.startsWith('scripts/') ||
            trimmed.startsWith('/scripts/');
      });
      expect(
        ignoresScripts,
        isFalse,
        reason: 'scripts/ must ship with the package — it must not appear '
            'in .gitignore.',
      );
    });
  });
}
