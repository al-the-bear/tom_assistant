// The vector-runtime precondition, stated as a test.
//
// Vector recall is mandatory (Q-A.6.1): `SqliteTomBrainMemory` refuses to
// open unless `vec0` registers. Roughly a tenth of this suite therefore
// depends on a precondition that is nowhere asserted — so when it is not
// met the suite goes red in dozens of places at once and none of them
// says why.
//
// This file is where it says why. It is deliberately the *first* thing to
// read in a failure triage: if the group below reports "not available",
// every store-touching failure in the rest of the suite has the same
// single cause, and the skip reason names the remedy.
//
// It does not gate the other tests. On a host with a capable SQLite they
// pass for real, which is worth more than a skip; on one without, they
// fail with a `VectorRuntimeUnavailable` that now carries the same
// remedy — see `VectorRuntimeProbe`.

import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';

void main() {
  final runtime = VectorRuntimeProbe.probe();

  group('vector runtime precondition', () {
    test('is stated, whether or not it is met', () {
      // Always runs. Its whole job is to print the verdict into the test
      // record so a triage starts from a sentence rather than from 64
      // stack traces.
      printOnFailure(runtime.toString());
      expect(runtime.toString(), isNotEmpty);
      if (!runtime.isAvailable) {
        printOnFailure('Store-touching tests in this suite will fail with '
            'VectorRuntimeUnavailable for this reason.');
      }
    });

    test(
      'vec0 is registered, so the store can open',
      () {
        expect(runtime.isAvailable, isTrue);
        expect(runtime.binariesRoot, isNotNull);
        expect(runtime.skipReason, isNull);
      },
      skip: runtime.skipReason,
    );

    test(
      'a packaged vec0 binary exists for this platform',
      () => expect(runtime.requireBinariesRoot, isNotEmpty),
      skip: runtime.binariesSkipReason,
    );

    test('requireBinariesRoot names the gate to check when there is none', () {
      if (runtime.binariesRoot != null) {
        expect(runtime.requireBinariesRoot, runtime.binariesRoot);
        return;
      }
      expect(
        () => runtime.requireBinariesRoot,
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('binariesSkipReason'),
        )),
      );
    });

    test('the probe is cached: registering vec0 twice is pointless', () {
      expect(identical(VectorRuntimeProbe.probe(), runtime), isTrue);
    });
  });

  group('discoverSqliteVecBinariesRoot', () {
    test('finds the workspace tom_binaries/sqlite_vec tree from here', () {
      // The suite runs with the package root as the working directory and
      // the tree lives at the workspace root, so discovery is what makes
      // the path work from any depth.
      expect(discoverSqliteVecBinariesRoot(), isNotNull);
    });

    test('gives up rather than walking forever', () {
      expect(discoverSqliteVecBinariesRoot(maxDepth: 0), isNull);
    });
  });
}
