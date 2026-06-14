// Slice 2 — substrate-side role-prose reload (`prompt_tracing.md` § 6.3,
// AUTH-5).
//
// `ReloadingRoleRegistry` is the refreshable holder that lets an operator edit
// a role's `<role>.persona.md` / `<role>.objective.md` and have the *next* LLM
// call assemble its prompt from the edited prose, without a restart — the same
// pull-based pickup the prompt *template body* already has.
//
// What this proves:
//   - fixed: never reloads; `current()` always returns the wrapped registry and
//     touches no filesystem.
//   - reloading: built (and fingerprinted) up front, so a no-change `current()`
//     returns the same overlay; an edited persona / objective is reflected on
//     the next `current()`; a *deleted* prose file reverts that half to the
//     in-code value (the holder keeps the in-code base for exactly this).
//   - the roster (ids + order) and capability surface are invariant across
//     reloads — only prose changes.

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  late Directory rolesDir;

  setUp(() {
    rolesDir = Directory.systemTemp.createTempSync('reload_roles_');
  });

  tearDown(() {
    if (rolesDir.existsSync()) rolesDir.deleteSync(recursive: true);
  });

  void writePersona(String roleId, String text) =>
      File('${rolesDir.path}/$roleId.persona.md').writeAsStringSync(text);

  void writeObjective(String roleId, String text) =>
      File('${rolesDir.path}/$roleId.objective.md').writeAsStringSync(text);

  group('ReloadingRoleRegistry.fixed — never reloads', () {
    test('current() returns the exact wrapped registry', () {
      final registry = bootstrapRoleRegistry();
      final holder = ReloadingRoleRegistry.fixed(registry);

      expect(holder.reloads, isFalse);
      expect(identical(holder.current(), registry), isTrue);
      expect(identical(holder.latest, registry), isTrue);
    });
  });

  group('ReloadingRoleRegistry.reloading — pull-based pickup (AUTH-5)', () {
    test('starts from the overlaid prose and reports it reloads', () {
      writePersona('analyser', 'INITIAL ANALYSER VOICE');
      final holder = ReloadingRoleRegistry.reloading(
        base: bootstrapRoleRegistry(),
        rolesDir: rolesDir,
      );

      expect(holder.reloads, isTrue);
      expect(
        holder.current().get('analyser').personaText,
        equals('INITIAL ANALYSER VOICE'),
      );
    });

    test('a no-change current() returns the same overlay instance', () {
      writePersona('analyser', 'STABLE VOICE');
      final holder = ReloadingRoleRegistry.reloading(
        base: bootstrapRoleRegistry(),
        rolesDir: rolesDir,
      );

      final first = holder.current();
      final second = holder.current();
      expect(identical(first, second), isTrue);
    });

    test('picks up an edited persona on the next current()', () {
      writePersona('analyser', 'OLD VOICE');
      final holder = ReloadingRoleRegistry.reloading(
        base: bootstrapRoleRegistry(),
        rolesDir: rolesDir,
      );
      expect(holder.current().get('analyser').personaText, equals('OLD VOICE'));

      writePersona('analyser', 'NEW VOICE FROM THE OBSERVATORY');

      final refreshed = holder.current();
      expect(
        refreshed.get('analyser').personaText,
        equals('NEW VOICE FROM THE OBSERVATORY'),
      );
    });

    test('picks up an edited objective on the next current()', () {
      writeObjective('analyser', 'OLD OBJECTIVE');
      final holder = ReloadingRoleRegistry.reloading(
        base: bootstrapRoleRegistry(),
        rolesDir: rolesDir,
      );
      expect(
        holder.current().get('analyser').objective,
        equals('OLD OBJECTIVE'),
      );

      writeObjective('analyser', 'NEW OBJECTIVE');
      expect(
        holder.current().get('analyser').objective,
        equals('NEW OBJECTIVE'),
      );
    });

    test('a deleted prose file reverts that role half to the in-code value',
        () {
      final inCodePersona =
          bootstrapRoleRegistry().get('analyser').personaText;
      writePersona('analyser', 'TEMPORARY OVERRIDE');
      final holder = ReloadingRoleRegistry.reloading(
        base: bootstrapRoleRegistry(),
        rolesDir: rolesDir,
      );
      expect(
        holder.current().get('analyser').personaText,
        equals('TEMPORARY OVERRIDE'),
      );

      File('${rolesDir.path}/analyser.persona.md').deleteSync();

      expect(
        holder.current().get('analyser').personaText,
        equals(inCodePersona),
      );
    });

    test('the roster and capability surface are invariant across a reload', () {
      final base = bootstrapRoleRegistry();
      writePersona('analyser', 'V1');
      final holder = ReloadingRoleRegistry.reloading(
        base: base,
        rolesDir: rolesDir,
      );
      final beforeIds = holder.current().ids.toList();
      final beforeActions = holder.current().get('analyser').allowedActions;

      writePersona('analyser', 'V2');
      final after = holder.current();

      expect(after.ids.toList(), equals(beforeIds));
      expect(after.ids.toList(), equals(base.ids.toList()));
      // Capability surface is always the in-code authority — a prose edit can
      // never widen it.
      expect(after.get('analyser').allowedActions, equals(beforeActions));
    });
  });
}
