// ToolDenial — the typed refusal a policy produces for a hidden tool
// (`tom_brain_procedure_specification.md` § 21.8, § 21.10).
//
// Unlike `ToolAlreadyRegistered` (a wiring *error* that is thrown), a denial
// is a *value*: it is what `ToolPolicy.denialFor` returns and what the
// `tool.invoke` primitive (step 6) surfaces as `{ok: false, error}` when a
// procedure names a tool the active policy does not expose (§ 21.10). It is
// not thrown and it is not a fallback trigger.
//
// The wire code is `tool.denied`. The step-16 observability event that
// records the same condition is named `ToolDenied` — distinct from this
// `ToolDenial` value so the event name stays free.

/// Wire-stable discriminator for a policy-denied tool (`tool.denied`).
const String toolDeniedCode = 'tool.denied';

/// The typed refusal returned for a tool the active [ToolPolicy] does not
/// expose. A returned value, not an exception: the caller decides how to
/// surface it (the `tool.invoke` primitive turns it into `{ok: false}`).
final class ToolDenial {
  /// The name of the tool that was denied.
  final String name;

  /// Optional human-readable reason (which profile / deny rule hid the tool).
  final String? reason;

  /// Builds a denial for [name], optionally carrying a [reason].
  const ToolDenial(this.name, {this.reason});

  /// The wire-stable failure class (`tool.denied`).
  String get code => toolDeniedCode;

  /// Human-readable detail.
  String get message => reason == null
      ? 'tool "$name" is not exposed by the active policy'
      : 'tool "$name" is not exposed by the active policy ($reason)';

  @override
  String toString() => '$code: $message';
}
