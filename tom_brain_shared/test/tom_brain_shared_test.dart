// Smoke test for the tom_brain_shared scaffold.
//
// At step A.7 the package barrel is intentionally empty. This test verifies
// that:
//   1. The package resolves and imports cleanly (the `import` line itself is
//      the load-bearing assertion — a broken pubspec or barrel fails the
//      compile here).
//   2. The barrel is *intentionally* empty at this step so subsequent steps
//      (A.10 – A.17) can append exports without needing to touch this test.
//
// When A.10 lands the first real type, the relevant per-module test files
// take over and this smoke test stays as the scaffold-level sanity check.

// ignore: unused_import
import 'package:tom_brain_shared/tom_brain_shared.dart';

import 'package:test/test.dart';

void main() {
  group('tom_brain_shared scaffold', () {
    test('package barrel is importable', () {
      // Compile-time success of the import above is the assertion.
      // The runtime expect keeps the test framework happy.
      expect(true, isTrue);
    });
  });
}
