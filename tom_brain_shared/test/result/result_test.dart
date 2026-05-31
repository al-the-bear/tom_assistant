// Tests for `Result<T, E>` (Plan step A.13).
//
// Surface under test:
//   * Construction via `Ok` / `Err` direct constructors and the
//     `Result.ok` / `Result.err` factory forms.
//   * `isOk` / `isErr` predicates on both variants.
//   * `fold` collapses both arms to a single value of the target type.
//   * `switch` pattern-matches exhaustively (sealed hierarchy).
//   * `ResultMap.map` transforms the success payload.
//   * `ResultMap.mapErr` transforms the failure payload.
//   * `ResultWhen.whenOk` invokes the callback on Ok, no-ops on Err,
//     returns `this` for chaining.
//   * `ResultWhen.whenErr` is the mirror of `whenOk`.
//   * Equality, hashCode, toString.
//   * Reified-generic identity: `Ok<int, String>(1) != Ok<int, Exception>(1)`.

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  group('Result construction', () {
    test('Ok direct constructor', () {
      const r = Ok<int, String>(42);
      expect(r.value, equals(42));
      expect(r.isOk, isTrue);
      expect(r.isErr, isFalse);
    });

    test('Err direct constructor', () {
      const r = Err<int, String>('boom');
      expect(r.error, equals('boom'));
      expect(r.isOk, isFalse);
      expect(r.isErr, isTrue);
    });

    test('Result.ok factory produces an Ok variant', () {
      const Result<int, String> r = Result.ok(7);
      expect(r, isA<Ok<int, String>>());
      expect((r as Ok<int, String>).value, equals(7));
    });

    test('Result.err factory produces an Err variant', () {
      const Result<int, String> r = Result.err('nope');
      expect(r, isA<Err<int, String>>());
      expect((r as Err<int, String>).error, equals('nope'));
    });

    test('Ok accepts a nullable T carrying null', () {
      const r = Ok<int?, String>(null);
      expect(r.value, isNull);
      expect(r.isOk, isTrue);
    });
  });

  group('Result.fold', () {
    test('Ok runs the ok arm', () {
      const r = Ok<int, String>(3);
      final s = r.fold(
        ok: (v) => 'ok-$v',
        err: (e) => 'err-$e',
      );
      expect(s, equals('ok-3'));
    });

    test('Err runs the err arm', () {
      const r = Err<int, String>('x');
      final s = r.fold(
        ok: (v) => 'ok-$v',
        err: (e) => 'err-$e',
      );
      expect(s, equals('err-x'));
    });

    test('fold can change the return type', () {
      const r = Ok<int, String>(5);
      final n = r.fold(
        ok: (v) => v * 2,
        err: (_) => -1,
      );
      expect(n, equals(10));
    });
  });

  group('Result switch (sealed exhaustiveness)', () {
    String describe(Result<int, String> r) {
      switch (r) {
        case Ok(:final value):
          return 'ok($value)';
        case Err(:final error):
          return 'err($error)';
      }
    }

    test('Ok arm', () {
      expect(describe(const Ok(1)), equals('ok(1)'));
    });

    test('Err arm', () {
      expect(describe(const Err('x')), equals('err(x)'));
    });
  });

  group('ResultMap.map', () {
    test('Ok.map transforms the success payload', () {
      const r = Ok<int, String>(2);
      final mapped = r.map((v) => v * 21);
      expect(mapped, isA<Ok<int, String>>());
      expect((mapped as Ok<int, String>).value, equals(42));
    });

    test('Err.map preserves the error untouched', () {
      const r = Err<int, String>('boom');
      final mapped = r.map((v) => v * 21);
      expect(mapped, isA<Err<int, String>>());
      expect((mapped as Err<int, String>).error, equals('boom'));
    });

    test('map can change the success type', () {
      const r = Ok<int, String>(2);
      final mapped = r.map((v) => 'n=$v');
      expect(mapped, equals(const Ok<String, String>('n=2')));
    });
  });

  group('ResultMap.mapErr', () {
    test('Ok.mapErr preserves the value untouched', () {
      const r = Ok<int, String>(5);
      final mapped = r.mapErr((e) => e.length);
      expect(mapped, isA<Ok<int, int>>());
      expect((mapped as Ok<int, int>).value, equals(5));
    });

    test('Err.mapErr transforms the error payload', () {
      const r = Err<int, String>('boom');
      final mapped = r.mapErr((e) => e.length);
      expect(mapped, isA<Err<int, int>>());
      expect((mapped as Err<int, int>).error, equals(4));
    });

    test('mapErr can change the error type', () {
      const r = Err<int, String>('e');
      final mapped = r.mapErr(Exception.new);
      expect(mapped, isA<Err<int, Exception>>());
    });
  });

  group('ResultWhen.whenOk', () {
    test('runs the callback on Ok and returns this', () {
      const r = Ok<int, String>(7);
      int? captured;
      final returned = r.whenOk((v) => captured = v);
      expect(captured, equals(7));
      expect(identical(returned, r), isTrue);
    });

    test('does not run the callback on Err', () {
      const r = Err<int, String>('x');
      var ran = false;
      final returned = r.whenOk((_) => ran = true);
      expect(ran, isFalse);
      expect(identical(returned, r), isTrue);
    });
  });

  group('ResultWhen.whenErr', () {
    test('runs the callback on Err and returns this', () {
      const r = Err<int, String>('boom');
      String? captured;
      final returned = r.whenErr((e) => captured = e);
      expect(captured, equals('boom'));
      expect(identical(returned, r), isTrue);
    });

    test('does not run the callback on Ok', () {
      const r = Ok<int, String>(1);
      var ran = false;
      final returned = r.whenErr((_) => ran = true);
      expect(ran, isFalse);
      expect(identical(returned, r), isTrue);
    });
  });

  group('ResultWhen chaining', () {
    test('whenOk then whenErr composes left-to-right', () {
      const r = Ok<int, String>(3);
      final log = <String>[];
      r.whenOk((v) => log.add('ok-$v')).whenErr((e) => log.add('err-$e'));
      expect(log, equals(<String>['ok-3']));
    });

    test('whenErr then whenOk composes left-to-right', () {
      const r = Err<int, String>('x');
      final log = <String>[];
      r.whenErr((e) => log.add('err-$e')).whenOk((v) => log.add('ok-$v'));
      expect(log, equals(<String>['err-x']));
    });
  });

  group('Result equality and hash', () {
    test('two Oks of the same value compare equal', () {
      const a = Ok<int, String>(1);
      const b = Ok<int, String>(1);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('two Errs of the same payload compare equal', () {
      const a = Err<int, String>('x');
      const b = Err<int, String>('x');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('Ok with different values is unequal', () {
      const a = Ok<int, String>(1);
      const b = Ok<int, String>(2);
      expect(a == b, isFalse);
    });

    test('Ok and Err are never equal even with overlapping payloads', () {
      // Payloads are different types here (int vs String), but the rule is
      // structural: a success is never a failure. Comparison goes through
      // Object so the analyzer does not flag the cross-variant check.
      const a = Ok<int, String>(1);
      const Object b = Err<int, String>('x');
      expect(a == b, isFalse);
    });

    test(
      'Reified generics: Ok<int, String>(1) != Ok<int, Exception>(1)',
      () {
        // Different runtimeTypes; Dart's `is` reifies generics. The values
        // are unequal on purpose — the type parameters are part of identity.
        // Right operand goes through `Object` so the analyzer accepts the
        // cross-generic comparison.
        const a = Ok<int, String>(1);
        const Object b = Ok<int, Exception>(1);
        expect(a == b, isFalse);
      },
    );

    test('Equality is false against an unrelated Object', () {
      const r = Ok<int, String>(1);
      expect(r == Object(), isFalse);
    });
  });

  group('Result toString', () {
    test('Ok includes the value', () {
      expect(const Ok<int, String>(42).toString(), equals('Ok(42)'));
    });

    test('Err includes the error', () {
      expect(const Err<int, String>('boom').toString(), equals('Err(boom)'));
    });
  });
}
