// A.53 — Degraded-mode recall when the sqlite-vec extension is
// missing (integration).
//
// Plan step A.53:
//   "Tests: extension load + vec query roundtrip; degraded-mode recall
//    when extension missing; embedding-model mismatch rejection."
//
// What A.50 already covered:
//   * The loader emits exactly one `VectorIndexUnavailable` event on
//     each non-loaded branch.
//   * `wasError == false` for the two `unavailable` branches
//     (notConfigured, fileMissing); `wasError == true` for every
//     `failed` branch (dynamicLibraryError, symbolMissing,
//     registrationFailed).
//
// What A.53 adds (this file):
//   * The **operational continuity** contract: when the loader does
//     not reach `loaded`, the rest of the storage stack remains
//     constructible and recall paths refuse with a *typed*
//     `EmbeddingModelMismatch` rather than crashing. That refusal is
//     what spec § 1 ("BM25 fallback when vec0 absent") and the
//     definition's "no silent vector results" rule lean on:
//     downstream code that asks for nearest-neighbour recall in BM25-
//     only mode gets a refusal it can route, not a crash.
//   * The event emitted by the wiring helper survives to the consumer
//     **as the only memory event** for the boot — no spurious
//     follow-ups, no double-emission across two boot calls in the same
//     process, and the categorical `wasError` flag matches the loader
//     outcome.
//
// Why we exercise three reason codes (notConfigured, fileMissing,
// dynamicLibraryError) here:
//   The first two are the *expected* developer-machine path (no
//   binary on disk; no extensionPath in config); the third is the
//   *fault* path (binary is present but rejected by dlopen). A.50
//   covered each loader call in isolation; A.53 confirms the
//   composition with downstream `VectorTable` lookups behaves
//   identically across both expected and fault degraded boots.

import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show BrainTime, FixedClock, Vec;

const String _modelId = 'A.53/never-installed';

/// Tempdir helper — created on call, removed on test teardown.
Directory _tempDir(String prefix) {
  final dir = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

/// Builds a `MemoryConfig` whose `extensionPath` is the empty string
/// (the notConfigured branch — every developer machine until the vec0
/// binary is published).
MemoryConfig _notConfiguredConfig() {
  final root = _tempDir('tbm_a53_degraded_notcfg_').path;
  return MemoryConfig.forTesting(root: root, extensionPath: '');
}

/// Builds a `MemoryConfig` whose `extensionPath` points at a file
/// that does not exist on disk (the fileMissing branch).
MemoryConfig _fileMissingConfig() {
  final dir = _tempDir('tbm_a53_degraded_missing_');
  final ghost = '${dir.path}${Platform.pathSeparator}vec0_not_here.so';
  return MemoryConfig.forTesting(root: dir.path, extensionPath: ghost);
}

/// Builds a `MemoryConfig` whose `extensionPath` points at a real
/// file that fails to dlopen (the dynamicLibraryError branch — the
/// failure is engineered by overriding `openDynamicLibrary` in the
/// loader passed to the wiring helper).
MemoryConfig _brokenBinaryConfig() {
  final dir = _tempDir('tbm_a53_degraded_broken_');
  final stub = File('${dir.path}${Platform.pathSeparator}not_a_lib.bin');
  stub.writeAsStringSync('text-not-binary');
  return MemoryConfig.forTesting(
    root: dir.path,
    extensionPath: stub.path,
  );
}

void main() {
  group('A.53 degraded-mode recall when extension missing', () {
    late Database vectorsDb;
    late VectorTable table;

    setUp(() {
      vectorsDb = sqlite3.openInMemory();
      table = VectorTable(
        vectorsDb: vectorsDb,
        backend: const PlainBlobTableBackend(),
        clock: FixedClock(BrainTime.utc(2026, 5, 30, 12)),
      );
    });

    tearDown(() {
      vectorsDb.dispose();
    });

    test('notConfigured boot → exactly one wasError=false event → '
        'recall paths refuse with EmbeddingModelMismatch (no crash)',
        () {
      final events = <MemoryEvent>[];

      final result = loadVecExtensionWithFailOpen(
        sqlite: sqlite3,
        config: _notConfiguredConfig(),
        emit: events.add,
      );

      expect(result.isUnavailable, isTrue);
      expect(result.reason, equals(VecUnavailableReason.notConfigured));
      expect(events, hasLength(1),
          reason: 'exactly one event per non-loaded boot');
      final event = events.single as VectorIndexUnavailable;
      expect(event.wasError, isFalse,
          reason: 'notConfigured is a configuration choice, not a fault');

      // Downstream: with no installIndex call, recall paths refuse
      // cleanly. This is what "BM25-only mode" means at the
      // VectorTable layer — vector recall is not silently empty, it
      // is a typed refusal that callers can branch on.
      expect(
        () => table.queryNearest(
          query: Vec.fromList(<double>[1, 0, 0, 0]),
          k: 5,
          modelId: _modelId,
        ),
        throwsA(isA<EmbeddingModelMismatch>()),
      );
      expect(
        () => table.insertVector(
          nodeId: 'n_x',
          vector: Vec.fromList(<double>[1, 0, 0, 0]),
          modelId: _modelId,
        ),
        throwsA(isA<EmbeddingModelMismatch>()),
      );
    });

    test('fileMissing boot → exactly one wasError=false event → '
        'meta-table reads remain safe (lookupIndex returns null)', () {
      final events = <MemoryEvent>[];

      final result = loadVecExtensionWithFailOpen(
        sqlite: sqlite3,
        config: _fileMissingConfig(),
        emit: events.add,
      );

      expect(result.isUnavailable, isTrue);
      expect(result.reason, equals(VecUnavailableReason.fileMissing));
      expect(events, hasLength(1));
      final event = events.single as VectorIndexUnavailable;
      expect(event.wasError, isFalse);

      // The meta-table reads do not require the extension; the layer
      // still answers "no, nothing installed" without throwing.
      expect(table.lookupIndex(_modelId), isNull);
      expect(table.hasIndex(_modelId), isFalse);
      expect(table.listInstalledIndexes(), isEmpty);
    });

    test('dynamicLibraryError boot → exactly one wasError=true event → '
        'cause is captured; recall paths refuse just like the '
        'unavailable branches', () {
      final events = <MemoryEvent>[];

      final brokenLoader = VecExtensionLoader(
        openDynamicLibrary: (path) =>
            throw ArgumentError('A.53 synthetic dlopen failure for $path'),
      );

      final result = loadVecExtensionWithFailOpen(
        sqlite: sqlite3,
        config: _brokenBinaryConfig(),
        emit: events.add,
        loader: brokenLoader,
      );

      expect(result.isFailed, isTrue,
          reason: 'broken-binary boot is a fault, not a configuration '
              'choice');
      expect(result.reason,
          equals(VecUnavailableReason.dynamicLibraryError));
      expect(events, hasLength(1));
      final event = events.single as VectorIndexUnavailable;
      expect(event.wasError, isTrue);
      expect(event.cause, isA<ArgumentError>());

      // The downstream refusal shape is identical — degraded mode is
      // degraded mode regardless of whether the cause was a missing
      // file or a broken binary. The operator UI tells the two apart
      // via `wasError`; the storage layer treats them the same.
      expect(
        () => table.queryNearest(
          query: Vec.fromList(<double>[1, 0, 0, 0]),
          k: 5,
          modelId: _modelId,
        ),
        throwsA(isA<EmbeddingModelMismatch>()),
      );
    });

    test('two degraded boots in the same process emit two independent '
        'events (no de-duplication across boots)', () {
      // Operationally a process boots once, but tests share a single
      // process via the test runner; if the loader carried any
      // process-wide "already reported" state it would collapse the
      // second event silently and an integration test that re-opens
      // the store mid-suite would see a missing event. Lock the
      // independence here.
      final events = <MemoryEvent>[];

      loadVecExtensionWithFailOpen(
        sqlite: sqlite3,
        config: _notConfiguredConfig(),
        emit: events.add,
      );
      loadVecExtensionWithFailOpen(
        sqlite: sqlite3,
        config: _fileMissingConfig(),
        emit: events.add,
      );

      expect(events, hasLength(2));
      final first = events.first as VectorIndexUnavailable;
      final second = events.last as VectorIndexUnavailable;
      expect(first.reason, equals(VecUnavailableReason.notConfigured));
      expect(second.reason, equals(VecUnavailableReason.fileMissing));
    });
  });
}
