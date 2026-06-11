// Extension F — the two-tier file sandbox value type
// (`tom_brain_procedure_specification.md` § 21.4; PE-1).
//
// What this suite locks:
//
//   F.18-1 — a FileScope keeps its write and read-only roots, exposes the
//            write roots verbatim as `writeableRoots`, and derives
//            `readableRoots` as the de-duplicated union (write roots first).
//   F.18-2 — a writeable root is implicitly readable; a root listed in both
//            tiers appears once in `readableRoots`.
//   F.18-3 — the value type is immutable and rejects an empty sandbox.
//   F.18-4 — `FileScope.fromPriorityList` reproduces the legacy single-list
//            interpretation (first root writeable, the rest read-only).

import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:test/test.dart';

void main() {
  group('F.18-1 write and read tiers', () {
    test('writeableRoots is the write list verbatim', () {
      final scope = FileScope(
        writeRoots: <String>['/w/one', '/w/two'],
        readRoots: <String>['/r/only'],
      );
      expect(scope.writeableRoots, <String>['/w/one', '/w/two']);
    });

    test('readableRoots unions write then read-only roots in order', () {
      final scope = FileScope(
        writeRoots: <String>['/w/one'],
        readRoots: <String>['/r/one', '/r/two'],
      );
      expect(scope.readableRoots, <String>['/w/one', '/r/one', '/r/two']);
    });
  });

  group('F.18-2 writeable implies readable', () {
    test('a write-only scope is readable in the same roots', () {
      final scope = FileScope(writeRoots: <String>['/w/one', '/w/two']);
      expect(scope.readableRoots, <String>['/w/one', '/w/two']);
      expect(scope.readRoots, isEmpty);
    });

    test('a root in both tiers appears once in readableRoots', () {
      final scope = FileScope(
        writeRoots: <String>['/shared'],
        readRoots: <String>['/shared', '/r/extra'],
      );
      expect(scope.readableRoots, <String>['/shared', '/r/extra']);
    });
  });

  group('F.18-3 immutability and invariants', () {
    test('writeRoots and readRoots are unmodifiable', () {
      final scope = FileScope(
        writeRoots: <String>['/w'],
        readRoots: <String>['/r'],
      );
      expect(() => scope.writeRoots.add('/x'), throwsUnsupportedError);
      expect(() => scope.readRoots.add('/x'), throwsUnsupportedError);
      expect(() => scope.readableRoots.add('/x'), throwsUnsupportedError);
    });

    test('a scope with no roots at all is rejected', () {
      expect(
        () => FileScope(writeRoots: const <String>[]),
        throwsA(isA<AssertionError>()),
      );
    });

    test('a read-only scope (no write roots) is allowed', () {
      final scope = FileScope(
        writeRoots: const <String>[],
        readRoots: <String>['/r/only'],
      );
      expect(scope.writeableRoots, isEmpty);
      expect(scope.readableRoots, <String>['/r/only']);
    });
  });

  group('F.18-4 fromPriorityList legacy interpretation', () {
    test('first root is writeable, the rest read-only', () {
      final scope = FileScope.fromPriorityList(
        <String>['/primary', '/second', '/third'],
      );
      expect(scope.writeableRoots, <String>['/primary']);
      expect(scope.readableRoots, <String>['/primary', '/second', '/third']);
    });

    test('a single-root list is writeable and readable', () {
      final scope = FileScope.fromPriorityList(<String>['/only']);
      expect(scope.writeableRoots, <String>['/only']);
      expect(scope.readableRoots, <String>['/only']);
    });

    test('an empty list is rejected', () {
      expect(
        () => FileScope.fromPriorityList(const <String>[]),
        throwsArgumentError,
      );
    });
  });
}
