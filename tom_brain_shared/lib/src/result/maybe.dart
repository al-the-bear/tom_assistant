// `Maybe<T>` — the optional-value half of the `result/` module
// (Plan step A.13).
//
// `Maybe` parallels `Result` but with a *unit* failure arm. Use it when the
// absence of a value carries no further information — "the cache had no
// entry" rather than "the cache lookup failed for reason X". When the
// absence does carry information, prefer `Result<T, E>` with an explicit
// error type.
//
// Design notes:
//
//   * `Maybe` is `sealed` and the two leaves are `final class` — same shape
//     as `Result` so the consumption patterns transfer (`switch`, `fold`,
//     fluent `whenSome` / `whenNone`).
//   * `None<T>` carries the type parameter even though it carries no value.
//     This is what makes `None<int>() is Maybe<int>` true and lets the
//     compiler check `Maybe<int>` flows without an `as` cast. The const
//     constructor means `const None<int>()` is a shared canonical instance
//     per type argument, so allocating a None is free.
//   * Equality on `None` is reified by `runtimeType`: two `None<int>()`
//     are equal; `None<int>()` and `None<String>()` are not. This is the
//     same rule used by `Ok` / `Err`.

import 'result.dart';

/// An optional value of type [T].
///
/// `Maybe<T>` is the right type when the absence of a value carries no
/// further information — i.e. when a downstream consumer treats "no value"
/// as a single uniform case. When the absence has structure (reasons,
/// recoverable failures, error payloads), use `Result<T, E>` instead.
///
/// Construction:
///
/// ```dart
/// final present = Maybe<int>.some(42);
/// const absent = Maybe<int>.none();
/// ```
///
/// Consumption mirrors [Result]: pattern match, `fold`, or the fluent
/// `whenSome` / `whenNone` extensions.
sealed class Maybe<T> {
  /// Common base constructor. Private — the sum is closed.
  const Maybe._();

  /// Construct a [Maybe] carrying [value].
  const factory Maybe.some(T value) = Some<T>;

  /// Construct an empty [Maybe]. Const-constructible — `const Maybe<int>.none()`
  /// shares a single canonical instance per `T`.
  const factory Maybe.none() = None<T>;

  /// True for a [Some] variant.
  bool get isSome;

  /// True for a [None] variant. Always the negation of [isSome].
  bool get isNone;

  /// Collapse both arms to a single value of type [R].
  ///
  /// The `none` arm is a zero-arg callback because there is no payload to
  /// pass — `none: () => default`, not `none: (_) => default`.
  R fold<R>({
    required R Function(T value) some,
    required R Function() none,
  });
}

/// The present variant of [Maybe]. Carries a [value] of type [T].
final class Some<T> extends Maybe<T> {
  /// The carried payload.
  final T value;

  /// Wraps [value] as a present [Maybe].
  const Some(this.value) : super._();

  @override
  bool get isSome => true;

  @override
  bool get isNone => false;

  @override
  R fold<R>({
    required R Function(T value) some,
    required R Function() none,
  }) =>
      some(value);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Some<T> && other.value == value);

  @override
  int get hashCode => Object.hash(runtimeType, value);

  @override
  String toString() => 'Some($value)';
}

/// The absent variant of [Maybe]. Carries no payload, but is parameterised
/// by [T] so it can fit into a `Maybe<T>` slot without a cast.
///
/// `None` is const-constructible. Two `None<T>` of the same `T` compare
/// equal; `None`s of different `T` do not.
final class None<T> extends Maybe<T> {
  /// Constructs the empty `Maybe`.
  const None() : super._();

  @override
  bool get isSome => false;

  @override
  bool get isNone => true;

  @override
  R fold<R>({
    required R Function(T value) some,
    required R Function() none,
  }) =>
      none();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is None<T>);

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() => 'None';
}

/// Transformation extensions on [Maybe].
///
/// Built on top of [Maybe.fold] — same pattern as [ResultMap] on `Result`.
extension MaybeMap<T> on Maybe<T> {
  /// Transform the carried value, leaving a [None] untouched.
  Maybe<U> map<U>(U Function(T value) f) => fold(
        some: (v) => Some<U>(f(v)),
        none: () => None<U>(),
      );

  /// Return the carried value when this is a [Some]; otherwise call
  /// [defaultValue] and return its result.
  ///
  /// `orElse` takes a *thunk* (a zero-arg callback) rather than a precomputed
  /// default so that the default-construction cost is only paid on the [None]
  /// path. For a literal default, pass `() => myLiteral`.
  T orElse(T Function() defaultValue) => fold(
        some: (v) => v,
        none: defaultValue,
      );

  /// Bridge to [Result]: a [Some] becomes `Ok(value)`; a [None] becomes
  /// `Err(errorIfNone())`. The error is constructed lazily for the same
  /// reason as [orElse]'s thunk.
  Result<T, E> toResult<E>(E Function() errorIfNone) => fold(
        some: (v) => Ok<T, E>(v),
        none: () => Err<T, E>(errorIfNone()),
      );
}

/// Fluent side-effect extensions on [Maybe] — the parallel of [ResultWhen]
/// on `Result`.
extension MaybeWhen<T> on Maybe<T> {
  /// Invoke [callback] with the carried value when this is a [Some]; no-op
  /// when this is a [None]. Returns `this` to support chaining.
  Maybe<T> whenSome(void Function(T value) callback) {
    final self = this;
    if (self is Some<T>) {
      callback(self.value);
    }
    return this;
  }

  /// Invoke [callback] when this is a [None]; no-op when this is a [Some].
  /// Returns `this` to support chaining.
  Maybe<T> whenNone(void Function() callback) {
    if (this is None<T>) {
      callback();
    }
    return this;
  }
}
