// DispatcherConfigInvalid — the typed rejection for a malformed dispatcher
// configuration document (Plan step D.47;
// `tom_brain_procedure_prototype_specification.md` § 13).
//
// `DispatcherConfig.fromYamlString` / `.loadFromFile` parse a small YAML
// document into the dispatcher's four configuration knobs (the two
// procedure-script paths, the foreground queue depth, the coordinator hard
// step deadline, and the free-time-scheduler enabled flag). Any structural
// problem — the document is not a mapping, a section has the wrong shape, a
// value is ill-typed, the queue depth is negative, or the hard step deadline
// is not strictly positive — is reported as this single typed error rather
// than a raw `YamlException`, `FormatException`, or `TypeError`. That gives
// the boot path (D.47 consumer) one exception type to catch when it boots a
// dispatcher from operator-supplied config, mirroring how `EngineConfig`
// (C.42) funnels every problem through `EngineConfigInvalid` and the
// procedure loader (C.24) through `ProcedureHeaderInvalid`.

library;

/// The canonical wire code every dispatcher-config-invalid failure carries.
///
/// Matches the `dispatcher.config.invalid` failure class used in logs and
/// trails. Kept as a named constant so the boot path (D.47 consumer) can
/// route on the wire code without string-matching the message — the same
/// idiom the loader/validator codes follow.
const String dispatcherConfigInvalidCode = 'dispatcher.config.invalid';

/// Thrown when a dispatcher configuration document is structurally invalid.
///
/// Carries a human-readable [message] and, when the problem is localised to
/// one field, the dotted [path] of the offending key (e.g.
/// `deadline.hardStepMs`). The string form prefixes `dispatcher.config.invalid:`
/// so the failure class is greppable in logs and trails.
final class DispatcherConfigInvalid implements Exception {
  /// Describes what is wrong with the configuration document.
  final String message;

  /// The dotted path of the offending field, when the problem is local to a
  /// single key (e.g. `queue.foregroundDepth`). `null` for document-level
  /// problems (not a mapping).
  final String? path;

  /// Builds an invalid-config error with [message] and an optional field
  /// [path].
  const DispatcherConfigInvalid(this.message, {this.path});

  /// The wire code carried by every dispatcher-config-invalid failure.
  String get code => dispatcherConfigInvalidCode;

  @override
  String toString() {
    final at = path == null ? '' : ' (at "$path")';
    return '$code: $message$at';
  }
}
