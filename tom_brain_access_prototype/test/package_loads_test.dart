// Smoke test for the E.6 project skeleton.
//
// The act of compiling the barrel import is the assertion: if the
// package layout regresses (barrel removed, library renamed, pubspec
// broken) this test fails to load. The trivial `expect` keeps the test
// runner happy until the real surface lands at E.7+.
//
// The barrel exports nothing yet (E.6 skeleton), so the import is
// formally unused — but importing it IS the layout check, so the lint
// is suppressed here deliberately. The ignore is removed at E.9 when
// the api/ surface gives the test something concrete to reference.

// ignore: unused_import
import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart';
import 'package:test/test.dart';

void main() {
  test('package loads', () {
    // Nothing is exported yet (E.6 skeleton). Importing the barrel above
    // is the real check; this asserts the test infra is wired.
    expect(true, isTrue);
  });
}
