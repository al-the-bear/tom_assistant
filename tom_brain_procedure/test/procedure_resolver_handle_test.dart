// Slice 1 — brain-side resolver reload (`prompt_tracing.md` § 6.3, AUTH-5).
//
// Proves the two mechanisms that let Tom Brain pick up an edited
// `scripts/system/<id>.dart` on the *next* run without a restart, while
// keeping resolution a pure function of a fixed snapshot within a turn:
//
//   1. `DiskProcedureStore.signature()` is a *cheap* fingerprint (path +
//      mtime + size, no body reads) that is stable across a no-op and
//      changes on add / edit / remove of a source file;
//   2. `ProcedureResolverHandle.fixed` never reloads (`maybeRefresh` is a
//      no-op), and a `reloading` / `open` handle swaps in a freshly-built
//      resolver — reflecting the new header version — exactly when the
//      signature changed, and not otherwise.
//
// Disk fixtures use `Directory.systemTemp.createTempSync` (the sibling
// `tom_brain_memory` convention used across this package's tests).

import 'dart:io';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:test/test.dart';

/// A real, parseable § 4.4 procedure header (plus a trivial body) for
/// [id]/[version].
String _source(String id, int version) => '''
/// @procedure
/// id: $id
/// version: $version
/// summary: summary of $id v$version
/// successCriterion: $id v$version succeeds
/// budget: { wallClockMs: 1000, toolCalls: 4 }
/// requires: [ recall, llm ]
Future<ProcedureResult> run(ProcedureInputs inputs) async {
  return ProcedureResult.ok();
}
''';

/// A disk store over a fresh temp system dir seeded with [procedures]. The
/// returned record exposes the store and its system directory so a test can
/// mutate the on-disk source between calls.
({DiskProcedureStore store, Directory systemDir}) _diskStore(
  List<(String id, int version)> procedures,
) {
  final root = Directory.systemTemp.createTempSync('handle_');
  addTearDown(() => root.deleteSync(recursive: true));
  final systemDir = Directory('${root.path}/system')..createSync();
  for (final (id, version) in procedures) {
    File('${systemDir.path}/${id}_$version.dart')
        .writeAsStringSync(_source(id, version));
  }
  return (
    store: DiskProcedureStore(systemDir: systemDir, userDir: null),
    systemDir: systemDir,
  );
}

void main() {
  group('DiskProcedureStore.signature — cheap change fingerprint', () {
    test('is stable when nothing changes', () async {
      final fixture = _diskStore([('alpha', 1)]);
      final first = await fixture.store.signature();
      final second = await fixture.store.signature();
      expect(second, equals(first));
    });

    test('changes when a source file is added', () async {
      final fixture = _diskStore([('alpha', 1)]);
      final before = await fixture.store.signature();
      File('${fixture.systemDir.path}/beta_1.dart')
          .writeAsStringSync(_source('beta', 1));
      final after = await fixture.store.signature();
      expect(after, isNot(equals(before)));
    });

    test('changes when a source file is removed', () async {
      final fixture = _diskStore([('alpha', 1), ('beta', 1)]);
      final before = await fixture.store.signature();
      File('${fixture.systemDir.path}/beta_1.dart').deleteSync();
      final after = await fixture.store.signature();
      expect(after, isNot(equals(before)));
    });

    test('changes when a source file is edited (size differs)', () async {
      final fixture = _diskStore([('alpha', 1)]);
      final before = await fixture.store.signature();
      // A larger body changes the size component without depending on
      // filesystem mtime granularity.
      File('${fixture.systemDir.path}/alpha_1.dart').writeAsStringSync(
        '${_source('alpha', 1)}\n// edit that grows the file\n',
      );
      final after = await fixture.store.signature();
      expect(after, isNot(equals(before)));
    });
  });

  group('ProcedureResolverHandle.fixed — never reloads', () {
    test('maybeRefresh is a no-op and the snapshot is unchanged', () async {
      final fixture = _diskStore([('alpha', 1)]);
      final resolver = await ProcedureResolver.fromStore(fixture.store);
      final handle = ProcedureResolverHandle.fixed(resolver);

      expect(handle.reloads, isFalse);
      expect(await handle.maybeRefresh(), isFalse);
      expect(identical(handle.current, resolver), isTrue);
    });
  });

  group('ProcedureResolverHandle — pull-based pickup (AUTH-5)', () {
    test('open settles so a no-change maybeRefresh is a true no-op', () async {
      final fixture = _diskStore([('alpha', 1)]);
      final handle = await ProcedureResolverHandle.open(fixture.store);

      expect(handle.reloads, isTrue);
      expect(await handle.maybeRefresh(), isFalse);
    });

    test('picks up an edited script (new version) on the next refresh',
        () async {
      final fixture = _diskStore([('alpha', 1)]);
      final handle = await ProcedureResolverHandle.open(fixture.store);

      expect(handle.current.resolve('alpha').header.version, 1);

      // The operator edits the source in place, bumping the header version.
      File('${fixture.systemDir.path}/alpha_1.dart')
          .writeAsStringSync(_source('alpha', 2));

      expect(await handle.maybeRefresh(), isTrue);
      expect(handle.current.resolve('alpha').header.version, 2);
    });

    test('a seeded reloading handle rebuilds once on first refresh', () async {
      final fixture = _diskStore([('alpha', 1)]);
      final initial = await ProcedureResolver.fromStore(fixture.store);
      final handle =
          ProcedureResolverHandle.reloading(fixture.store, initial);

      // Signature left uncaptured, so the first refresh re-stats and rebuilds
      // once even with no edit — picking up anything changed between boot and
      // the first run.
      expect(await handle.maybeRefresh(), isTrue);
      // ...and settles: a subsequent no-change refresh is a no-op.
      expect(await handle.maybeRefresh(), isFalse);
    });
  });
}
