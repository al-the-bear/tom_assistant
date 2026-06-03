// EngineConfigInvalid — the typed rejection for a malformed engine
// configuration document (Plan step C.42;
// `tom_brain_procedure_prototype_specification.md` § 13).
//
// `EngineConfig.fromYamlString` / `.loadFromFile` parse a small YAML
// document into the engine's four configuration knobs (system-scripts
// path, user-scripts path, sandbox switches, deadline defaults). Any
// structural problem — the document is not a mapping, a section has the
// wrong shape, a value is ill-typed, or the step deadline is not strictly
// positive — is reported as this single typed error rather than a raw
// `YamlException`, `FormatException`, or `TypeError`. That gives the
// dispatcher (C.42 consumer) one exception type to catch when it boots an
// engine from operator-supplied config, mirroring how the procedure
// loader (C.24) funnels every header problem through
// `ProcedureHeaderInvalid`.

library;

/// The canonical wire code every engine-config-invalid failure carries.
///
/// Matches the `engine.config.invalid` failure class used in logs and
/// trails. Kept as a named constant so the dispatcher boot path (C.42
/// consumer) can route on the wire code without string-matching the
/// message — the same idiom the loader/validator codes follow.
const String engineConfigInvalidCode = 'engine.config.invalid';

/// Thrown when an engine configuration document is structurally invalid.
///
/// Carries a human-readable [message] and, when the problem is localised
/// to one field, the dotted [path] of the offending key (e.g.
/// `deadline.stepMs`). The string form prefixes `engine.config.invalid:`
/// so the failure class is greppable in logs and trails.
final class EngineConfigInvalid implements Exception {
  /// Describes what is wrong with the configuration document.
  final String message;

  /// The dotted path of the offending field, when the problem is local to
  /// a single key (e.g. `sandbox.enableUnixCommands`). `null` for
  /// document-level problems (not a mapping, empty where content is
  /// required).
  final String? path;

  /// Builds an invalid-config error with [message] and an optional field
  /// [path].
  const EngineConfigInvalid(this.message, {this.path});

  /// The wire code carried by every engine-config-invalid failure.
  String get code => engineConfigInvalidCode;

  @override
  String toString() {
    final at = path == null ? '' : ' (at "$path")';
    return '$code: $message$at';
  }
}
