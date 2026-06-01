// ProcedureInputs — the typed, immutable input bag a procedure's `run`
// entry point receives (`tom_brain_procedure_prototype_specification.md`
// § 4.3, § 5.3).
//
// The spec mandates the entry point `Future<ProcedureResult> run(
// ProcedureInputs inputs)` and that every bridged call returns a typed
// result, "never a raw `Map`/`String`". `ProcedureInputs` is the typed
// wrapper over the named values the loader parsed from the inbound
// invocation. It is introduced at C.19 because `runProcedure(id, inputs,
// {version, depthDelta})` (the first engine-native primitive) takes one;
// C.38–C.41 build the rest of the `api/` surface (`ProcedureEngine`, the
// run handle, the sugar aliases) on top of it.

import 'dart:collection';

/// The named inputs handed to a procedure's `run` entry point.
///
/// Immutable: the backing map is copied and wrapped on construction, so a
/// caller cannot mutate a procedure's inputs after the fact and a
/// procedure cannot mutate the bag it was given. Lookups are typed via
/// [get] / [getOrNull]; [has] tests presence without forcing a type.
final class ProcedureInputs {
  /// Wraps [values] as an immutable input bag.
  ProcedureInputs(Map<String, Object?> values)
      : _values = UnmodifiableMapView<String, Object?>(
          Map<String, Object?>.of(values),
        );

  /// An input bag with no entries.
  factory ProcedureInputs.empty() => ProcedureInputs(const <String, Object?>{});

  final Map<String, Object?> _values;

  /// The input names present in this bag.
  Iterable<String> get names => _values.keys;

  /// Whether [name] is present (even when its value is `null`).
  bool has(String name) => _values.containsKey(name);

  /// Returns the value bound to [name] as a [T].
  ///
  /// Throws [ArgumentError] when [name] is absent and [StateError] when
  /// the bound value is not a [T]. Absence and type-mismatch are distinct
  /// faults — a procedure asking for an input that was never supplied is a
  /// contract problem at the call site; a value of the wrong type is a
  /// loader/coercion problem.
  T get<T>(String name) {
    if (!_values.containsKey(name)) {
      throw ArgumentError.value(name, 'name', 'no input named "$name"');
    }
    final value = _values[name];
    if (value is! T) {
      throw StateError(
        'input "$name" is ${value.runtimeType}, not $T',
      );
    }
    return value;
  }

  /// Returns the value bound to [name] as a [T], or `null` when [name] is
  /// absent or bound to `null`.
  ///
  /// Throws [StateError] when [name] is present with a non-null value of
  /// the wrong type — a present-but-wrong-type value is still a fault, not
  /// a silent miss.
  T? getOrNull<T>(String name) {
    if (!_values.containsKey(name)) return null;
    final value = _values[name];
    if (value == null) return null;
    if (value is! T) {
      throw StateError(
        'input "$name" is ${value.runtimeType}, not $T',
      );
    }
    return value as T;
  }

  @override
  String toString() => 'ProcedureInputs(${_values.keys.join(', ')})';
}
