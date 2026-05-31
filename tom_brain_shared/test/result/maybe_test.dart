// Tests for `Maybe<T>` (Plan step A.13).
//
// Surface under test:
//   * Construction via `Some` / `None` direct constructors and the
//     `Maybe.some` / `Maybe.none` factory forms.
//   * `isSome` / `isNone` predicates on both variants.
//   * `fold` collapses both arms to a single value.
//   * `switch` pattern-matches exhaustively.
//   * `MaybeMap.map` transforms a Some, preserves None.
//   * `MaybeMap.orElse` returns the value on Some, the thunk on None,
//     and only evaluates the thunk on the None path.
//   * `MaybeMap.toResult` bridges to `Result<T, E>` (and only evaluates
//     the error thunk on the None path).
//   * `MaybeWhen.whenSome` / `whenNone` invoke their callbacks on the
//     correct arm, no-op on the other, return `this` for chaining.
//   * Equality, hashCode, toString.
//   * `None<int>() != None<String>()` — reified-generic identity.

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  group('Maybe construction', () {
    test('Some direct constructor', () {
      const m = Some<int>(7);
      expect(m.value, equals(7));
      expect(m.isSome, isTrue);
      expect(m.isNone, isFalse);
    });

    test('None direct constructor', () {
      const m = None<int>();
      expect(m.isSome, isFalse);
      expect(m.isNone, isTrue);
    });

    test('Maybe.some factory produces a Some variant', () {
      const Maybe<int> m = Maybe.some(3);
      expect(m, isA<Some<int>>());
    });

    test('Maybe.none factory produces a None variant', () {
      const Maybe<int> m = Maybe.none();
      expect(m, isA<None<int>>());
    });

    test('Some accepts a nullable T carrying null', () {
      const m = Some<int?>(null);
      expect(m.value, isNull);
      expect(m.isSome, isTrue);
    });
  });

  group('Maybe.fold', () {
    test('Some runs the some arm', () {
      const m = Some<int>(3);
      final s = m.fold(some: (v) => 'some-$v', none: () => 'none');
      expect(s, equals('some-3'));
    });

    test('None runs the none arm', () {
      const m = None<int>();
      final s = m.fold(some: (v) => 'some-$v', none: () => 'none');
      expect(s, equals('none'));
    });
  });

  group('Maybe switch (sealed exhaustiveness)', () {
    String describe(Maybe<int> m) {
      switch (m) {
        case Some(:final value):
          return 'some($value)';
        case None<int>():
          return 'none';
      }
    }

    test('Some arm', () {
      expect(describe(const Some(1)), equals('some(1)'));
    });

    test('None arm', () {
      expect(describe(const None()), equals('none'));
    });
  });

  group('MaybeMap.map', () {
    test('Some.map transforms the payload', () {
      const m = Some<int>(2);
      final mapped = m.map((v) => v * 21);
      expect(mapped, equals(const Some<int>(42)));
    });

    test('None.map preserves None with the new type', () {
      const m = None<int>();
      final mapped = m.map((v) => v * 21);
      expect(mapped, isA<None<int>>());
    });

    test('map can change the carried type', () {
      const m = Some<int>(2);
      final mapped = m.map((v) => 'n=$v');
      expect(mapped, equals(const Some<String>('n=2')));
    });
  });

  group('MaybeMap.orElse', () {
    test('Some.orElse returns the carried value', () {
      const m = Some<int>(7);
      expect(m.orElse(() => 0), equals(7));
    });

    test('None.orElse returns the thunk result', () {
      const m = None<int>();
      expect(m.orElse(() => 99), equals(99));
    });

    test('Some.orElse does NOT evaluate the thunk', () {
      const m = Some<int>(7);
      var calls = 0;
      m.orElse(() {
        calls += 1;
        return 0;
      });
      expect(calls, equals(0));
    });

    test('None.orElse evaluates the thunk exactly once', () {
      const m = None<int>();
      var calls = 0;
      m.orElse(() {
        calls += 1;
        return 0;
      });
      expect(calls, equals(1));
    });
  });

  group('MaybeMap.toResult', () {
    test('Some.toResult yields Ok(value)', () {
      const m = Some<int>(5);
      final r = m.toResult<String>(() => 'absent');
      expect(r, equals(const Ok<int, String>(5)));
    });

    test('None.toResult yields Err(errorIfNone())', () {
      const m = None<int>();
      final r = m.toResult<String>(() => 'absent');
      expect(r, equals(const Err<int, String>('absent')));
    });

    test('Some.toResult does NOT evaluate the error thunk', () {
      const m = Some<int>(5);
      var calls = 0;
      m.toResult<String>(() {
        calls += 1;
        return 'unused';
      });
      expect(calls, equals(0));
    });
  });

  group('MaybeWhen.whenSome', () {
    test('runs the callback on Some and returns this', () {
      const m = Some<int>(7);
      int? captured;
      final returned = m.whenSome((v) => captured = v);
      expect(captured, equals(7));
      expect(identical(returned, m), isTrue);
    });

    test('does not run the callback on None', () {
      const m = None<int>();
      var ran = false;
      final returned = m.whenSome((_) => ran = true);
      expect(ran, isFalse);
      expect(identical(returned, m), isTrue);
    });
  });

  group('MaybeWhen.whenNone', () {
    test('runs the callback on None and returns this', () {
      const m = None<int>();
      var ran = false;
      final returned = m.whenNone(() => ran = true);
      expect(ran, isTrue);
      expect(identical(returned, m), isTrue);
    });

    test('does not run the callback on Some', () {
      const m = Some<int>(7);
      var ran = false;
      final returned = m.whenNone(() => ran = true);
      expect(ran, isFalse);
      expect(identical(returned, m), isTrue);
    });
  });

  group('MaybeWhen chaining', () {
    test('whenSome then whenNone composes left-to-right', () {
      const m = Some<int>(3);
      final log = <String>[];
      m.whenSome((v) => log.add('some-$v')).whenNone(() => log.add('none'));
      expect(log, equals(<String>['some-3']));
    });

    test('whenNone then whenSome composes left-to-right', () {
      const m = None<int>();
      final log = <String>[];
      m.whenNone(() => log.add('none')).whenSome((v) => log.add('some-$v'));
      expect(log, equals(<String>['none']));
    });
  });

  group('Maybe equality and hash', () {
    test('two Somes of the same value compare equal', () {
      const a = Some<int>(1);
      const b = Some<int>(1);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('two Nones of the same type compare equal', () {
      const a = None<int>();
      const b = None<int>();
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('Somes with different payloads are unequal', () {
      const a = Some<int>(1);
      const b = Some<int>(2);
      expect(a == b, isFalse);
    });

    test('Some and None are never equal', () {
      // Comparison goes through `Object` so the analyzer does not flag the
      // cross-variant check.
      const a = Some<int>(1);
      const Object b = None<int>();
      expect(a == b, isFalse);
    });

    test(
      'Reified generics: None<int>() != None<String>()',
      () {
        // The receiver `a` has runtimeType None<int>; `b is None<int>` is
        // false because Dart reifies generics. Type-different Nones are
        // unequal on purpose. Right operand goes through `Object` so the
        // analyzer accepts the cross-generic comparison.
        const a = None<int>();
        const Object b = None<String>();
        expect(a == b, isFalse);
      },
    );

    test('Equality is false against an unrelated Object', () {
      const m = Some<int>(1);
      expect(m == Object(), isFalse);
    });
  });

  group('Maybe toString', () {
    test('Some includes the value', () {
      expect(const Some<int>(42).toString(), equals('Some(42)'));
    });

    test('None has a stable rendering', () {
      expect(const None<int>().toString(), equals('None'));
    });
  });
}
