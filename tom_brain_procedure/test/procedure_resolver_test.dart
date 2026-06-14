// C.25 — ProcedureResolver unit tests.
//
// Covers the version resolver and its fallback chain:
//
//   - index construction from already-loaded procedures (grouping by id,
//     descending-version order), including the duplicate-(id, version)
//     guard;
//   - `resolve(id)` → latest, `resolve(id, version:)` → exact, and the two
//     `ProcedureNotFound` branches (unknown id / unknown version);
//   - `fallbackChain` `[v_latest, …, v1]`, full and stepped-down via
//     `from:`, plus its not-found branches;
//   - the `ids` / `knows` / `versions` / `latestVersion` query surface;
//   - `fromStore` over a fake `ProcedureStore`: enumerate → read → load →
//     resolve, the null-read skip (benign race), and the malformed-header
//     propagation.
//
// `ProcedureHeaderInvalid` / `ProcedureNotFound` carry stable wire codes;
// the tests assert on the code, not the message, matching the C.24 style.

import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:test/test.dart';

/// Builds a [LoadedProcedure] with a minimal valid header for [id]/[version].
///
/// The header is built directly (not parsed) so resolver tests stay
/// independent of the loader's grammar — except the `fromStore` tests,
/// which deliberately exercise the real parse path with [_headerSource].
LoadedProcedure _loaded(String id, int version, {ProcedureRef? ref}) =>
    LoadedProcedure(
      ref: ref ?? ProcedureRef.system('/$id.v$version.dart'),
      header: ProcedureHeader(
        id: id,
        version: version,
        summary: 'summary of $id v$version',
        successCriterion: 'it works',
        budget: ProcedureBudget(const {'wallClockMs': 1000}),
      ),
      source: '/// @procedure\n/// id: $id\n/// version: $version\n// body',
    );

/// A real, parseable procedure source for the `fromStore` path.
String _headerSource(String id, int version) => '''
/// @procedure
/// id: $id
/// version: $version
/// summary: summary of $id v$version
/// successCriterion: it works
/// budget: { wallClockMs: 1000 }
ProcedureResult run(Map inputs) => ProcedureResult.ok();
''';

/// A minimal in-memory [ProcedureStore] for the `fromStore` tests. Holds a
/// fixed `ref → source` map; a `null` source models a ref that reads back
/// `null` (deleted between `list` and `read`).
final class _FakeStore implements ProcedureStore {
  _FakeStore(this._sources);

  final Map<ProcedureRef, String?> _sources;

  @override
  Future<List<ProcedureRef>> list() async => _sources.keys.toList();

  @override
  bool handles(ProcedureRef ref) => _sources.containsKey(ref);

  @override
  Future<ProcedureSource?> read(ProcedureRef ref) async {
    final src = _sources[ref];
    if (src == null) return null;
    return ProcedureSource(ref: ref, source: src);
  }

  @override
  Future<String> signature() async {
    final parts = _sources.entries
        .map((e) => '${e.key}|${e.value?.length ?? -1}')
        .toList()
      ..sort();
    return parts.join('\n');
  }
}

void main() {
  group('C.25 ProcedureResolver — index construction', () {
    test('groups by id and orders versions descending', () {
      final resolver = ProcedureResolver([
        _loaded('alpha', 1),
        _loaded('alpha', 3),
        _loaded('alpha', 2),
        _loaded('beta', 1),
      ]);

      expect(resolver.ids, equals(['alpha', 'beta']));
      expect(resolver.versions('alpha'), equals([3, 2, 1]));
      expect(resolver.versions('beta'), equals([1]));
    });

    test('input order does not matter', () {
      final a = ProcedureResolver([_loaded('x', 2), _loaded('x', 1)]);
      final b = ProcedureResolver([_loaded('x', 1), _loaded('x', 2)]);
      expect(a.versions('x'), equals(b.versions('x')));
      expect(a.resolve('x').header.version, 2);
      expect(b.resolve('x').header.version, 2);
    });

    test('rejects a duplicate (id, version) with ArgumentError', () {
      expect(
        () => ProcedureResolver([
          _loaded('dup', 1, ref: const ProcedureRef.system('/disk.dart')),
          _loaded('dup', 1, ref: const ProcedureRef.brain('node_1')),
        ]),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('the same id at different versions is not a duplicate', () {
      final resolver = ProcedureResolver([_loaded('ok', 1), _loaded('ok', 2)]);
      expect(resolver.versions('ok'), equals([2, 1]));
    });

    test('an empty input yields an empty resolver', () {
      final resolver = ProcedureResolver(const <LoadedProcedure>[]);
      expect(resolver.ids, isEmpty);
      expect(resolver.knows('anything'), isFalse);
      expect(resolver.versions('anything'), isEmpty);
      expect(resolver.latestVersion('anything'), isNull);
    });
  });

  group('C.25 ProcedureResolver — query surface', () {
    final resolver = ProcedureResolver([
      _loaded('proc', 1),
      _loaded('proc', 2),
      _loaded('other', 5),
    ]);

    test('knows reflects membership', () {
      expect(resolver.knows('proc'), isTrue);
      expect(resolver.knows('missing'), isFalse);
    });

    test('latestVersion returns the highest version, null when unknown', () {
      expect(resolver.latestVersion('proc'), 2);
      expect(resolver.latestVersion('other'), 5);
      expect(resolver.latestVersion('missing'), isNull);
    });

    test('versions is descending and empty for an unknown id', () {
      expect(resolver.versions('proc'), equals([2, 1]));
      expect(resolver.versions('missing'), isEmpty);
    });

    test('ids is sorted lexicographically', () {
      expect(resolver.ids, equals(['other', 'proc']));
    });
  });

  group('C.25 ProcedureResolver — resolve', () {
    final resolver = ProcedureResolver([
      _loaded('answer_with_memory_v1', 1),
      _loaded('multi', 1),
      _loaded('multi', 3),
    ]);

    test('resolve(id) returns the latest version', () {
      expect(resolver.resolve('multi').header.version, 3);
    });

    test('resolve(id, version:) returns the exact version', () {
      expect(resolver.resolve('multi', version: 1).header.version, 1);
      expect(resolver.resolve('multi', version: 3).header.version, 3);
    });

    test('resolve carries the loaded procedure through (ref + source)', () {
      final loaded = resolver.resolve('answer_with_memory_v1');
      expect(loaded.header.id, 'answer_with_memory_v1');
      expect(loaded.header.summary, contains('answer_with_memory_v1'));
      expect(loaded.source, contains('@procedure'));
    });

    test('resolve of an unknown id throws ProcedureNotFound (version null)',
        () {
      expect(
        () => resolver.resolve('nope'),
        throwsA(
          isA<ProcedureNotFound>()
              .having((e) => e.id, 'id', 'nope')
              .having((e) => e.version, 'version', isNull)
              .having((e) => e.code, 'code', procedureNotFoundCode),
        ),
      );
    });

    test('resolve of a known id at an unknown version throws ProcedureNotFound',
        () {
      expect(
        () => resolver.resolve('multi', version: 2),
        throwsA(
          isA<ProcedureNotFound>()
              .having((e) => e.id, 'id', 'multi')
              .having((e) => e.version, 'version', 2),
        ),
      );
    });
  });

  group('C.25 ProcedureResolver — fallback chain [v_latest, …, v1]', () {
    final resolver = ProcedureResolver([
      _loaded('p', 1),
      _loaded('p', 2),
      _loaded('p', 4),
      _loaded('solo', 1),
    ]);

    test('full chain is newest-first down to v1', () {
      final chain = resolver.fallbackChain('p');
      expect(chain.map((e) => e.header.version), equals([4, 2, 1]));
    });

    test('a single-version procedure has a singleton chain (PE-6)', () {
      final chain = resolver.fallbackChain('solo');
      expect(chain.map((e) => e.header.version), equals([1]));
    });

    test('from: steps the chain down from the given version inclusive', () {
      expect(
        resolver.fallbackChain('p', from: 4).map((e) => e.header.version),
        equals([4, 2, 1]),
      );
      expect(
        resolver.fallbackChain('p', from: 2).map((e) => e.header.version),
        equals([2, 1]),
      );
      expect(
        resolver.fallbackChain('p', from: 1).map((e) => e.header.version),
        equals([1]),
      );
    });

    test('unknown id throws ProcedureNotFound', () {
      expect(
        () => resolver.fallbackChain('missing'),
        throwsA(isA<ProcedureNotFound>()),
      );
    });

    test('unknown from-version throws ProcedureNotFound', () {
      expect(
        () => resolver.fallbackChain('p', from: 3),
        throwsA(
          isA<ProcedureNotFound>().having((e) => e.version, 'version', 3),
        ),
      );
    });

    test('the returned chain is unmodifiable', () {
      final chain = resolver.fallbackChain('p');
      expect(() => chain.add(_loaded('p', 9)), throwsUnsupportedError);
    });
  });

  group('C.25 ProcedureResolver.fromStore', () {
    test('enumerates, reads, parses headers, and resolves', () async {
      final store = _FakeStore({
        const ProcedureRef.system('/a.dart'): _headerSource('a', 1),
        const ProcedureRef.user('/b.dart'): _headerSource('b', 2),
        const ProcedureRef.brain('node_c'): _headerSource('a', 2),
      });

      final resolver = await ProcedureResolver.fromStore(store);

      expect(resolver.ids, equals(['a', 'b']));
      expect(resolver.versions('a'), equals([2, 1]));
      expect(resolver.resolve('a').header.version, 2);
      expect(resolver.resolve('b').header.version, 2);
    });

    test('skips a ref that reads back null (benign list/read race)', () async {
      final store = _FakeStore({
        const ProcedureRef.system('/present.dart'): _headerSource('present', 1),
        const ProcedureRef.system('/gone.dart'): null,
      });

      final resolver = await ProcedureResolver.fromStore(store);

      expect(resolver.ids, equals(['present']));
      expect(resolver.knows('present'), isTrue);
    });

    test('propagates ProcedureHeaderInvalid for a malformed header', () async {
      final store = _FakeStore({
        const ProcedureRef.system('/bad.dart'): '// no @procedure header here',
      });

      expect(
        () => ProcedureResolver.fromStore(store),
        throwsA(isA<ProcedureHeaderInvalid>()),
      );
    });

    test('an empty store yields an empty resolver', () async {
      final resolver =
          await ProcedureResolver.fromStore(_FakeStore(const {}));
      expect(resolver.ids, isEmpty);
    });
  });

  group('C.25 ProcedureNotFound', () {
    test('unknown-id message omits a version', () {
      const e = ProcedureNotFound('foo');
      expect(e.version, isNull);
      expect(e.code, procedureNotFoundCode);
      expect(e.message, contains('foo'));
      expect(e.toString(), contains('ProcedureNotFound'));
    });

    test('unknown-version message names the version', () {
      const e = ProcedureNotFound('foo', version: 7);
      expect(e.version, 7);
      expect(e.message, contains('7'));
    });
  });
}
