// Smoke test for the access-prototype package surface.
//
// The act of compiling the barrel import is the assertion: if the package
// layout regresses (barrel removed, library renamed, pubspec broken) this
// test fails to load. At E.9 the barrel exports its first concrete symbol
// (`accessPrototypeTool`), so the test references it directly — the
// `// ignore: unused_import` carried since E.6 is now removed.

import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:test/test.dart';

void main() {
  test('package loads and exports the tool definition', () {
    // Referencing a real exported symbol proves the barrel resolves and
    // the api/ surface is wired through to the top-level library.
    expect(accessPrototypeTool.name, 'tom_brain_access');
  });
}
