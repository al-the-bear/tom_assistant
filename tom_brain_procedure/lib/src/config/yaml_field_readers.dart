// Shared YAML field readers for the prototype's two configuration loaders
// (E.2 de-duplication).
//
// `EngineConfig` (C.42) and `DispatcherConfig` (D.47) grew identical
// optional-field extraction blocks: each rejected a present-but-ill-typed
// section/value through its own typed error (`EngineConfigInvalid`,
// `DispatcherConfigInvalid`) while accepting an absent field as "use the
// default". The two reader sets were line-for-line identical apart from the
// exception class they constructed. This file is that one shared
// implementation, parameterised by a [ConfigInvalidFactory] so each loader
// keeps its own structured error type (with its own `path` field and wire
// code) while the parse/validate logic lives in exactly one place.
//
// Why not the generic `YamlConfigReader` in `tom_core_agentic`:
//
//   `tom_core_agentic` already ships a `YamlConfigReader`, but it uses a
//   deliberately different error model — a single-argument factory that
//   bakes the dotted path *into the message string* (`'$path must be a
//   string'`). The prototype configs instead carry the path as a
//   *structured* field on the exception (`EngineConfigInvalid(msg,
//   path: …)`), so the path survives as data an operator tool can read,
//   and they enforce stricter shapes the generic reader does not model
//   (non-empty strings, strictly-positive and non-negative integers). The
//   two-argument [ConfigInvalidFactory] below preserves that structured
//   model. Collapsing the two into the generic reader would change the
//   exceptions' `toString()` output and drop the structured `path` — a
//   behavioural regression the config tests assert against.

import 'package:yaml/yaml.dart';

/// Builds the loader's typed configuration error from a [message] and an
/// optional structured [path] (the dotted location of the offending key).
///
/// Both `EngineConfigInvalid.new` and `DispatcherConfigInvalid.new` match
/// this signature, so a loader passes its own constructor as a tear-off.
typedef ConfigInvalidFactory = Object Function(String message, {String? path});

/// Returns the value of an optional mapping-valued [field] as a [YamlMap],
/// or `null` when the field is absent/null. Rejects a present field whose
/// value is not a mapping (reported by `field`, matching both loaders).
YamlMap? optionalConfigMap(
  YamlMap node,
  String field,
  ConfigInvalidFactory invalid,
) {
  if (!node.containsKey(field) || node[field] == null) return null;
  final value = node[field];
  if (value is! YamlMap) {
    throw invalid('must be a mapping', path: field);
  }
  return value;
}

/// Returns the value of an optional string-valued [field] as a non-empty
/// `String`, or `null` when absent/null. Rejects a present value that is not
/// a non-empty string.
String? optionalConfigString(
  YamlMap node,
  String field,
  String path,
  ConfigInvalidFactory invalid,
) {
  if (!node.containsKey(field) || node[field] == null) return null;
  final value = node[field];
  if (value is! String || value.trim().isEmpty) {
    throw invalid('must be a non-empty string', path: path);
  }
  return value;
}

/// Returns the value of an optional boolean-valued [field], or `null` when
/// absent/null. Rejects a present value that is not a boolean.
bool? optionalConfigBool(
  YamlMap node,
  String field,
  String path,
  ConfigInvalidFactory invalid,
) {
  if (!node.containsKey(field) || node[field] == null) return null;
  final value = node[field];
  if (value is! bool) {
    throw invalid('must be a boolean', path: path);
  }
  return value;
}

/// Returns the value of an optional strictly-positive-integer [field], or
/// `null` when absent/null. Rejects a present value that is not an integer,
/// or is not strictly positive.
int? optionalConfigPositiveInt(
  YamlMap node,
  String field,
  String path,
  ConfigInvalidFactory invalid,
) {
  if (!node.containsKey(field) || node[field] == null) return null;
  final value = node[field];
  if (value is! int) {
    throw invalid('must be an integer', path: path);
  }
  if (value <= 0) {
    throw invalid('must be strictly positive', path: path);
  }
  return value;
}

/// Returns the value of an optional non-negative-integer [field], or `null`
/// when absent/null. Rejects a present value that is not an integer, or is
/// negative (zero is allowed — it disables queueing).
int? optionalConfigNonNegativeInt(
  YamlMap node,
  String field,
  String path,
  ConfigInvalidFactory invalid,
) {
  if (!node.containsKey(field) || node[field] == null) return null;
  final value = node[field];
  if (value is! int) {
    throw invalid('must be an integer', path: path);
  }
  if (value < 0) {
    throw invalid('must be zero or greater', path: path);
  }
  return value;
}

/// Renders a string scalar for YAML emission, quoting it when it could be
/// misread as a non-string (empty, leading/trailing space, or a reserved
/// scalar). Plain filesystem paths emit unquoted.
String yamlScalar(String value) {
  final needsQuote = value.isEmpty ||
      value != value.trim() ||
      const {'true', 'false', 'null', 'yes', 'no', '~'}
          .contains(value.toLowerCase()) ||
      RegExp(r'^[\[\]{}#&*!|>%@`"' "'" r']').hasMatch(value) ||
      value.contains(': ') ||
      value.contains(' #');
  if (!needsQuote) return value;
  final escaped = value.replaceAll('"', r'\"');
  return '"$escaped"';
}
