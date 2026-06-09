// C.6 smoke test.
//
// Verifies that the `tom_brain_procedure` package is
// importable and that its barrel resolves. Real surface lands in
// C.7+; until then, the only guarantee this test makes is that the
// project is well-formed enough for `dart pub get` + `dart analyze`
// to pass and for consumers to add the dependency without it breaking
// their build.
//
// The act of compiling the `import` is itself the assertion — if the
// package layout regresses, this test fails to load.

// ignore: unused_import
import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:test/test.dart';

void main() {
  group('tom_brain_procedure package', () {
    test('barrel library resolves and test framework runs', () {
      expect(1 + 1, equals(2));
    });
  });
}
