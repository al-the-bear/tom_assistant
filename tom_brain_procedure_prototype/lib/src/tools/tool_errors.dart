// Typed failures of the tool registry
// (`tom_brain_procedure_prototype_specification.md` § 21.2).
//
// `ToolAlreadyRegistered` is a *programming* error — two tools claiming the
// same name is a wiring mistake the composition root must fix, not a runtime
// condition a procedure can recover from. It mirrors the package's exception
// convention (`final class … implements Exception`, a wire-stable `code`
// constant, a `code` getter, a `message`, and a `toString()` that prefixes
// `$code:`), matching `ProcedureBudgetExceeded` and the `config/` error
// family.

/// Wire-stable discriminator for a duplicate-name registration.
const String toolAlreadyRegisteredCode = 'tool.already_registered';

/// Raised when a tool is registered under a name the registry already holds.
///
/// A wiring error, not a recoverable runtime condition: the registry refuses
/// the second registration rather than silently shadowing the first, so a
/// name collision surfaces at composition time instead of as a confusing
/// dispatch later.
final class ToolAlreadyRegistered implements Exception {
  /// The name that was already registered.
  final String name;

  /// Builds the failure for the colliding [name].
  const ToolAlreadyRegistered(this.name);

  /// The wire-stable failure class (`tool.already_registered`).
  String get code => toolAlreadyRegisteredCode;

  /// Human-readable detail.
  String get message => 'a tool named "$name" is already registered';

  @override
  String toString() => '$code: $message';
}
