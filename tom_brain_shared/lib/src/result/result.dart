// Barrel for the `result/` module (Plan step A.13). This file also defines
// the `Result<T, E>` sealed hierarchy itself — same convention as `budget.dart`,
// where the primary type lives in the barrel rather than a redundant
// `result_type.dart` shim.
//
// Module surface:
//
//   * `Result<T, E>`   — defined below; sealed sum type with two leaves.
//   * `Ok<T, E>`       — success variant carrying a `value`.
//   * `Err<T, E>`      — failure variant carrying an `error`.
//   * `Maybe<T>` / `Some<T>` / `None<T>` — re-exported from `maybe.dart`.
//   * `ResultMap`      — extension adding `map` / `mapErr` transformations.
//   * `ResultWhen`     — extension adding fluent `whenOk` / `whenErr`
//                        side-effect chaining (the surface asked for by the
//                        plan).
//
// Design notes:
//
//   * `Result` is `sealed` so consumers can `switch` over `Ok` / `Err`
//     exhaustively without an explicit default clause. Both leaves are
//     `final class`es — neither variant is meant to be extended further;
//     the sum is closed by design.
//   * The base class declares only the minimum virtual surface (`isOk`,
//     `isErr`, `fold`). Everything else — `map`, `mapErr`, `whenOk`,
//     `whenErr` — is an extension method built on top of `fold`. Extensions
//     keep the surface open to additions in downstream packages without
//     touching the sealed core.
//   * Equality and hashCode are reified by the runtime generic type: two
//     `Ok<int, String>(1)` instances are equal; an `Ok<int, String>(1)` and
//     an `Ok<int, Exception>(1)` are not, because Dart reifies generics and
//     `runtimeType` differs. This is correct — the type parameters are part
//     of the value's identity at this layer.

export 'maybe.dart' show Maybe, MaybeMap, MaybeWhen, None, Some;

/// A success-or-failure value over two distinguishable type parameters.
///
/// `Result<T, E>` is the standard sum type for operations that can either
/// produce a `T` (the success payload) or an `E` (the failure payload).
/// Both arms are exhaustive — there is no third state.
///
/// Construction:
///
/// ```dart
/// final ok = Result<int, String>.ok(42);
/// final err = Result<int, String>.err('not a number');
/// // Equivalent, more terse where the type parameters are obvious from context:
/// const Ok<int, String>(42);
/// const Err<int, String>('not a number');
/// ```
///
/// Consumption (idiomatic patterns):
///
/// ```dart
/// // 1. Pattern match — exhaustive over the sealed hierarchy.
/// switch (r) {
///   case Ok(:final value): print('got $value');
///   case Err(:final error): print('failed: $error');
/// }
///
/// // 2. Functional fold — both arms collapse to one return type.
/// final message = r.fold(
///   ok: (v) => 'got $v',
///   err: (e) => 'failed: $e',
/// );
///
/// // 3. Side-effect chaining via the extensions.
/// r.whenOk(print).whenErr(logger.warn);
/// ```
///
/// `Result` is an *immutable value*. Mutation is modeled by returning a new
/// `Result` (see `map`, `mapErr`) — instances are safe to share.
sealed class Result<T, E> {
  /// Common base constructor. Subclasses are `final` and live in this file;
  /// the constructor is private to prevent third-party variants.
  const Result._();

  /// Construct a success `Result` carrying [value]. Equivalent to
  /// `Ok<T, E>(value)` — the factory form is sometimes more readable when
  /// the type parameters are written on the left of an assignment.
  const factory Result.ok(T value) = Ok<T, E>;

  /// Construct a failure `Result` carrying [error]. Equivalent to
  /// `Err<T, E>(error)`.
  const factory Result.err(E error) = Err<T, E>;

  /// True for an `Ok` variant.
  bool get isOk;

  /// True for an `Err` variant. Always the negation of [isOk] — both
  /// accessors exist because the call site reads better with whichever name
  /// matches the question being asked.
  bool get isErr;

  /// Collapse both arms to a single value of type [R].
  ///
  /// `fold` is the primitive transformation method — `map` and `mapErr` are
  /// built on top of it as extension methods. It is the right call site
  /// whenever both arms collapse to the same downstream type (logging,
  /// rendering, error reporting).
  R fold<R>({
    required R Function(T value) ok,
    required R Function(E error) err,
  });
}

/// The success variant of [Result]. Carries a [value] of type [T].
///
/// Equality and hashCode are reified by `runtimeType`, so two `Ok` instances
/// with the same [value] but different declared error types compare
/// unequal — generics are part of identity at this layer.
final class Ok<T, E> extends Result<T, E> {
  /// The success payload.
  final T value;

  /// Wraps [value] as a success result.
  const Ok(this.value) : super._();

  @override
  bool get isOk => true;

  @override
  bool get isErr => false;

  @override
  R fold<R>({
    required R Function(T value) ok,
    required R Function(E error) err,
  }) =>
      ok(value);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Ok<T, E> && other.value == value);

  @override
  int get hashCode => Object.hash(runtimeType, value);

  @override
  String toString() => 'Ok($value)';
}

/// The failure variant of [Result]. Carries an [error] of type [E].
///
/// Symmetric with [Ok]: equality reifies the generic types. An
/// `Err<int, String>('x')` is not equal to an `Err<int, Exception>('x')`
/// because the runtime types differ.
final class Err<T, E> extends Result<T, E> {
  /// The failure payload.
  final E error;

  /// Wraps [error] as a failure result.
  const Err(this.error) : super._();

  @override
  bool get isOk => false;

  @override
  bool get isErr => true;

  @override
  R fold<R>({
    required R Function(T value) ok,
    required R Function(E error) err,
  }) =>
      err(error);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Err<T, E> && other.error == error);

  @override
  int get hashCode => Object.hash(runtimeType, error);

  @override
  String toString() => 'Err($error)';
}

/// Transformation extensions on [Result].
///
/// Built on top of [Result.fold] — the only virtual method either subclass
/// needs to implement is `fold`; everything else falls out of it.
extension ResultMap<T, E> on Result<T, E> {
  /// Transform the success payload, leaving an `Err` untouched.
  ///
  /// ```dart
  /// final r = Ok<int, String>(2).map((v) => v * 21); // Ok(42)
  /// final e = Err<int, String>('boom').map((v) => v * 21); // Err('boom')
  /// ```
  Result<U, E> map<U>(U Function(T value) f) => fold(
        ok: (v) => Ok<U, E>(f(v)),
        err: (e) => Err<U, E>(e),
      );

  /// Transform the error payload, leaving an `Ok` untouched.
  ///
  /// Useful for adapting between error vocabularies at module boundaries —
  /// e.g. translating a low-level storage error into a domain error before
  /// returning across an API surface.
  Result<T, F> mapErr<F>(F Function(E error) f) => fold(
        ok: (v) => Ok<T, F>(v),
        err: (e) => Err<T, F>(f(e)),
      );
}

/// Fluent side-effect extensions on [Result] — the surface called out in
/// plan step A.13.
///
/// Both methods return `this` so chained calls compose left-to-right:
///
/// ```dart
/// result
///   .whenOk((v) => logger.info('produced $v'))
///   .whenErr((e) => logger.warn('failed: $e'));
/// ```
///
/// The callbacks are `void`-returning by design — `whenOk` / `whenErr` are
/// the *do* side of the API. Use [ResultMap.map] / [ResultMap.mapErr] when
/// the goal is to produce a new value rather than perform a side effect.
extension ResultWhen<T, E> on Result<T, E> {
  /// Invoke [callback] with the success payload when this is an [Ok];
  /// no-op when this is an [Err]. Returns `this` to support chaining.
  Result<T, E> whenOk(void Function(T value) callback) {
    final self = this;
    if (self is Ok<T, E>) {
      callback(self.value);
    }
    return this;
  }

  /// Invoke [callback] with the error payload when this is an [Err];
  /// no-op when this is an [Ok]. Returns `this` to support chaining.
  Result<T, E> whenErr(void Function(E error) callback) {
    final self = this;
    if (self is Err<T, E>) {
      callback(self.error);
    }
    return this;
  }
}
