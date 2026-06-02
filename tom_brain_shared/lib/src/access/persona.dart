// Persona — the minimal persona handle the dispatcher hands to substrate
// (Plan step D.11; def § 1.5; proto spec § 10.1).
//
// What this file owns:
//
//   * The `Persona` value type — a stable persona id plus the substrate
//     role it resolves to. The dispatcher passes `persona.substrateRole`
//     to the `llm` primitive's `role` path (D.38).
//
// Why `Persona` is a *new* shared type, not a substrate `RoleTemplate`:
//
//   The substrate has no `Persona` class — only `RoleTemplate`
//   (B.21–B.24). D.4 fixed that `Persona` is a new shared type that
//   *maps to* a substrate role; it does not duplicate `RoleTemplate`.
//   Phase E's `PersonaResolver` (E.26) produces it (model id → persona;
//   the prototype maps every persona to the `assistant_to_user` role).
//   The verbosity variants (`tom-assistant:terse` / `:verbose`, E.15)
//   are persona-level distinctions resolved by `PersonaResolver`, not
//   new substrate roles.
//
// Why it lives in `tom_brain_shared`:
//
//   The dispatcher reads `persona.substrateRole`; Phase E produces the
//   `Persona`. Two phases reference it → shared.

/// The persona handed to substrate for an inbound request, in the minimal
/// shape the dispatcher needs. Carried on [Access].
///
/// Immutable value object.
final class Persona {
  /// Stable persona identifier — e.g. `"tom-assistant"`,
  /// `"tom-assistant:terse"`. Non-empty. Phase E maps a model id (or the
  /// default) to this; the dispatcher does not interpret it beyond
  /// carrying it.
  final String personaId;

  /// The substrate role this persona resolves to — e.g.
  /// `"assistant_to_user"`. Non-empty. The dispatcher passes this to the
  /// `llm` primitive's `role` path (D.38). For the prototype every
  /// persona resolves to `assistant_to_user`.
  final String substrateRole;

  /// Builds an immutable persona handle. Both fields must be non-empty —
  /// an empty persona id or substrate role would route an answer to no
  /// role at all.
  Persona({
    required this.personaId,
    required this.substrateRole,
  }) {
    if (personaId.isEmpty) {
      throw ArgumentError.value(personaId, 'personaId', 'must be non-empty');
    }
    if (substrateRole.isEmpty) {
      throw ArgumentError.value(
        substrateRole,
        'substrateRole',
        'must be non-empty',
      );
    }
  }

  /// The substrate role every prototype persona resolves to (D.4 / D.38).
  static const String defaultSubstrateRole = 'assistant_to_user';

  /// The default persona id when an inbound request names no model
  /// (E.26 persona defaulting).
  static const String defaultPersonaId = 'tom-assistant';

  /// Convenience constructor for the prototype default persona —
  /// `tom-assistant` → `assistant_to_user`.
  factory Persona.assistant() => Persona(
        personaId: defaultPersonaId,
        substrateRole: defaultSubstrateRole,
      );

  @override
  bool operator ==(Object other) =>
      other is Persona &&
      other.personaId == personaId &&
      other.substrateRole == substrateRole;

  @override
  int get hashCode => Object.hash(personaId, substrateRole);

  @override
  String toString() =>
      'Persona(personaId: $personaId, substrateRole: $substrateRole)';
}
