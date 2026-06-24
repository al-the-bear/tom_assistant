// R5 — `ProfileRegistry` directory-sourcing (`profilesDir`).
//
// CLI plan step 5 (tom_brain_cli_plan.md): the top-level `profiles:` block may
// be sourced from a `profilesDir` (the standalone `tom_brain` CLI's
// `<agent>/profiles/` convention) instead of being declared inline. This
// mirrors step 2's substrate `providersDir`/`modelsDir` directory-sourcing, but
// `profilesDir` is a *top-level* key (sibling to `profiles:`), not nested.
//
// Contract under test:
//
//   * `profilesDir` unions the `profiles:` maps from every `*.yaml`/`*.yml`
//     file under the directory, in filename order, keyed by profile id.
//   * Inline `profiles:` still works unchanged (no directory key).
//   * Declaring both `profiles:` inline and `profilesDir:` is a config error.
//   * A duplicate profile id across two files is a config error.
//   * A relative `profilesDir` resolves against `basePath` (threaded from
//     `loadFromFile`); a relative path with no base is an error; a missing
//     directory is an error.
//   * A dir-sourced profile still flows through `validateAtBoot` — its
//     `templateOverlay` resolves through the injected `overlayDirExists`
//     predicate (`<cognition.root>/overlays/<name>/`).

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_brain_run/tom_brain_run.dart'
    show ProfileConfigException, ProfileRegistry;

void main() {
  group('R5 — ProfileRegistry directory-sourcing (profilesDir)', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('profiles_dir_');
    });
    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    Future<void> writeProfileFile(
      String dir,
      String name,
      String content,
    ) async {
      final d = Directory('${tmp.path}/$dir');
      await d.create(recursive: true);
      await File('${d.path}/$name').writeAsString(content);
    }

    test('PDIR-01: profilesDir unions profiles across files by id (absolute)',
        () async {
      await writeProfileFile('profiles', 'research.yaml', '''
profiles:
  research:
    mode: cognitive
    role: researcher
''');
      await writeProfileFile('profiles', 'quick.yaml', '''
profiles:
  quick:
    mode: answer
''');
      final r = ProfileRegistry.fromYamlString(
        'profilesDir: ${tmp.path}/profiles\n',
      );
      expect(r.names, containsAll(<String>['default', 'research', 'quick']));
      expect(r.profile('research')!.role, 'researcher');
      expect(r.profile('quick')!.effectiveEntryProcedure,
          'answer_with_memory_v1');
    });

    test('PDIR-02: a relative profilesDir resolves against basePath', () async {
      await writeProfileFile('profiles', 'a.yaml', '''
profiles:
  alpha: {mode: answer}
''');
      final r = ProfileRegistry.fromYamlString(
        'profilesDir: profiles\n',
        basePath: tmp.path,
      );
      expect(r.contains('alpha'), isTrue);
    });

    test('PDIR-03: a relative profilesDir with no basePath is an error', () {
      expect(
        () => ProfileRegistry.fromYamlString('profilesDir: profiles\n'),
        throwsA(isA<ProfileConfigException>()),
      );
    });

    test('PDIR-04: both profiles: inline and profilesDir: → config error',
        () async {
      await writeProfileFile('profiles', 'a.yaml', 'profiles:\n  a: {}\n');
      expect(
        () => ProfileRegistry.fromYamlString(
          'profilesDir: ${tmp.path}/profiles\n'
          'profiles:\n  inline: {}\n',
        ),
        throwsA(isA<ProfileConfigException>()
            .having((e) => e.code, 'code', 'profile.dir_inline_conflict')),
      );
    });

    test('PDIR-05: a duplicate profile id across files → config error',
        () async {
      await writeProfileFile(
          'profiles', 'a.yaml', 'profiles:\n  dup: {mode: answer}\n');
      await writeProfileFile(
          'profiles', 'b.yaml', 'profiles:\n  dup: {mode: cognitive}\n');
      expect(
        () => ProfileRegistry.fromYamlString(
            'profilesDir: ${tmp.path}/profiles\n'),
        throwsA(isA<ProfileConfigException>()
            .having((e) => e.code, 'code', 'profile.duplicate_id')),
      );
    });

    test('PDIR-06: a missing profilesDir directory is an error', () {
      expect(
        () => ProfileRegistry.fromYamlString(
            'profilesDir: ${tmp.path}/nope\n'),
        throwsA(isA<ProfileConfigException>()),
      );
    });

    test('PDIR-07: inline profiles: unchanged when basePath is supplied', () {
      final r = ProfileRegistry.fromYamlString(
        'profiles:\n  inline: {mode: answer}\n',
        basePath: tmp.path,
      );
      expect(r.contains('inline'), isTrue);
      expect(r.profile('inline')!.effectiveEntryProcedure,
          'answer_with_memory_v1');
    });

    test('PDIR-08: a dir-sourced templateOverlay is validated at boot',
        () async {
      await writeProfileFile('profiles', 'r.yaml', '''
profiles:
  research:
    templateOverlay: research
''');
      final r = ProfileRegistry.fromYamlString(
          'profilesDir: ${tmp.path}/profiles\n');
      // Present overlay → passes (path resolution against the predicate).
      expect(
        () => r.validateAtBoot(
          knownRoles: const {},
          overlayDirExists: (name) => name == 'research',
        ),
        returnsNormally,
      );
      // Missing overlay → profile.overlay_missing.
      expect(
        () => r.validateAtBoot(
          knownRoles: const {},
          overlayDirExists: (_) => false,
        ),
        throwsA(isA<ProfileConfigException>()
            .having((e) => e.code, 'code', 'profile.overlay_missing')),
      );
    });
  });
}
