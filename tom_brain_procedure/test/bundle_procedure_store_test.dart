// Step 3 (tom_brain_cli_plan.md) — bundled procedure store + disk-overlays-
// bundle shadowing.
//
// The standalone `tom_brain` CLI ships its `scripts/system/` procedures as a
// *bundle* compiled into the executable, so a single-file CLI carries its
// safety-net procedures with no on-disk `scripts/` tree. A deployment may
// still drop `.dart` files into a writable disk `scripts/` directory; those
// disk procedures **overlay the bundle by procedure id** — any disk version
// of an id suppresses every bundled version of that id.
//
// Contract under test (the new pieces this step adds):
//
//   * `BundledProcedureStore` — a read-only `ProcedureStore` over an
//     in-memory `locator → source` map (the compiled bundle). It has no
//     write path: you cannot author into the bundle. This is what realizes
//     "authored procedures require a writable disk `scripts/`".
//   * `ProcedureOrigin.bundle` (+ `ProcedureRef.bundle`) — a third origin so
//     a composite/shadowing store can route a read to the bundle backend
//     without colliding with the disk (`system`/`user`) origins.
//   * `ShadowingProcedureStore(primary: disk, shadowed: bundle)` — presents
//     disk-overlays-bundle as one store: every primary ref, plus only the
//     bundle refs whose parsed id is NOT among the disk ids. Shadowing is
//     **by id**, so a disk `foo_v1` (version 1) suppresses a bundled `foo`
//     version 2 as well — the disk side wins the whole id.
//
// The fixtures reuse the § 4.4 header shape from
// `procedure_store_acceptance_test.dart` so the loader's parse path runs
// end-to-end on every assertion.

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

void main() {
  group('bundle-only — BundledProcedureStore serves the compiled bundle', () {
    late BundledProcedureStore bundle;

    setUp(() {
      bundle = BundledProcedureStore(<String, String>{
        'answer_with_memory_v1': _source('answer_with_memory', 1),
        'think_v1': _source('think', 1),
      });
    });

    test('fromStore yields the bundled ids with bundle origin', () async {
      final resolver = await ProcedureResolver.fromStore(bundle);
      expect(resolver.ids, equals(['answer_with_memory', 'think']));
      final ref = resolver.resolve('answer_with_memory').ref;
      expect(ref.origin, equals(ProcedureOrigin.bundle));
      expect(ref.origin.isBundle, isTrue);
      expect(ref.origin.isDisk, isFalse);
      expect(ref.origin.isMemory, isFalse);
    });

    test('handles only bundle refs', () {
      expect(bundle.handles(const ProcedureRef.bundle('think_v1')), isTrue);
      expect(bundle.handles(const ProcedureRef.system('/x.dart')), isFalse);
      expect(bundle.handles(const ProcedureRef.brain('node')), isFalse);
    });

    test('read of a non-bundle ref is a programmer error', () {
      expect(
        () => bundle.read(const ProcedureRef.system('/x.dart')),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('read of an absent bundle locator returns null', () async {
      expect(await bundle.read(const ProcedureRef.bundle('absent')), isNull);
    });

    test('signature is stable across calls (bundle is immutable)', () async {
      expect(await bundle.signature(), equals(await bundle.signature()));
    });
  });

  group('disk-shadows-bundle — disk overlays the bundle by procedure id', () {
    late Directory root;
    late Directory systemDir;

    setUp(() {
      root = Directory.systemTemp.createTempSync('bundle_shadow_');
      addTearDown(() => root.deleteSync(recursive: true));
      systemDir = Directory('${root.path}/system')..createSync();
    });

    BundledProcedureStore makeBundle() => BundledProcedureStore(<String, String>{
          // Bundle ships answer_with_memory at v2 and think at v1.
          'answer_with_memory_v2': _source('answer_with_memory', 2),
          'think_v1': _source('think', 1),
        });

    test('a disk id suppresses every bundled version of that id', () async {
      // Disk ships answer_with_memory at v1 only. Because shadowing is by id,
      // the disk side wins the whole id — the bundled v2 is suppressed, even
      // though it is newer.
      File('${systemDir.path}/answer_with_memory_v1.dart')
          .writeAsStringSync(_source('answer_with_memory', 1));
      final disk = DiskProcedureStore(systemDir: systemDir, userDir: null);
      final store = ShadowingProcedureStore(primary: disk, shadowed: makeBundle());

      final resolver = await ProcedureResolver.fromStore(store);
      expect(resolver.ids, equals(['answer_with_memory', 'think']));

      final answer = resolver.resolve('answer_with_memory');
      expect(answer.ref.origin, equals(ProcedureOrigin.system));
      expect(answer.header.version, equals(1),
          reason: 'disk v1 wins the whole id; bundled v2 is shadowed out');
      expect(resolver.versions('answer_with_memory'), equals([1]),
          reason: 'no bundled version of a disk-shadowed id survives');

      // think has no disk shadow, so it resolves from the bundle.
      final think = resolver.resolve('think');
      expect(think.ref.origin, equals(ProcedureOrigin.bundle));
      expect(think.header.version, equals(1));
    });

    test('with an empty disk every bundled procedure is visible', () async {
      final disk = DiskProcedureStore(systemDir: systemDir, userDir: null);
      final store = ShadowingProcedureStore(primary: disk, shadowed: makeBundle());
      final resolver = await ProcedureResolver.fromStore(store);
      expect(resolver.ids, equals(['answer_with_memory', 'think']));
      expect(resolver.resolve('answer_with_memory').ref.origin,
          equals(ProcedureOrigin.bundle));
      expect(resolver.resolve('answer_with_memory').header.version, equals(2));
    });

    test('an unknown id resolves to ProcedureNotFound', () async {
      final disk = DiskProcedureStore(systemDir: systemDir, userDir: null);
      final store = ShadowingProcedureStore(primary: disk, shadowed: makeBundle());
      final resolver = await ProcedureResolver.fromStore(store);
      expect(
        () => resolver.resolve('absent'),
        throwsA(isA<ProcedureNotFound>().having((e) => e.id, 'id', 'absent')),
      );
    });

    test('shadowing routes reads to the owning backend', () async {
      File('${systemDir.path}/answer_with_memory_v1.dart')
          .writeAsStringSync(_source('answer_with_memory', 1));
      final disk = DiskProcedureStore(systemDir: systemDir, userDir: null);
      final store = ShadowingProcedureStore(primary: disk, shadowed: makeBundle());

      // A bundle ref reads through to the bundle.
      final bundleSrc = await store.read(const ProcedureRef.bundle('think_v1'));
      expect(bundleSrc, isNotNull);
      expect(bundleSrc!.ref.origin, equals(ProcedureOrigin.bundle));
    });
  });

  group('authored procedures require a writable disk scripts/ directory', () {
    test('authoring writes a new .dart on disk; the bundle is untouched',
        () async {
      final root = Directory.systemTemp.createTempSync('bundle_author_');
      addTearDown(() => root.deleteSync(recursive: true));
      final systemDir = Directory('${root.path}/system')..createSync();

      final bundle = BundledProcedureStore(<String, String>{
        'answer_with_memory_v1': _source('answer_with_memory', 1),
      });
      final disk = DiskProcedureStore(systemDir: systemDir, userDir: null);
      final store = ShadowingProcedureStore(primary: disk, shadowed: bundle);

      // Before authoring: only the bundled safety net is visible.
      final before = await ProcedureResolver.fromStore(store);
      expect(before.ids, equals(['answer_with_memory']));
      expect(before.resolve('answer_with_memory').ref.origin,
          equals(ProcedureOrigin.bundle));

      // "Author" a new procedure by writing it into the writable disk dir —
      // the only place a new procedure can land, since the bundle is read-only
      // by construction (it exposes no write path).
      File('${systemDir.path}/automate_inbox_v1.dart')
          .writeAsStringSync(_source('automate_inbox', 1));

      final after = await ProcedureResolver.fromStore(store);
      expect(after.ids, equals(['answer_with_memory', 'automate_inbox']));
      expect(after.resolve('automate_inbox').ref.origin,
          equals(ProcedureOrigin.system),
          reason: 'an authored procedure resolves from the writable disk store');
      // The bundle still serves the safety net, unchanged.
      expect(after.resolve('answer_with_memory').ref.origin,
          equals(ProcedureOrigin.bundle));
    });
  });
}
