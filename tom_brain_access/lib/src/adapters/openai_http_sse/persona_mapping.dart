// OpenAI `model` string → `Persona` mapping (E.15).
//
// What this file owns (Plan § Phase E, substep E.15; proto spec § 5.5;
// AC-5):
//
//   * `OpenAiPersonaMapping` — the pure, network-free map from an OpenAI
//     `model` string to a `tom_brain_shared` [Persona]. The recognised
//     vocabulary is the three prototype personas — `tom-assistant`,
//     `tom-assistant:terse`, `tom-assistant:verbose` — each carrying that
//     id as its `personaId` and all resolving to the single prototype
//     substrate role `assistant_to_user`. An absent or unrecognised model
//     resolves to the default `Persona.assistant()` (AC-5: an unknown
//     model is *not* an error; it falls back).
//
// Scope discipline (per the strict per-substep log): E.15 is the
// *persona-as-model* mapping only. It is the adapter's local view of the
// vocabulary so the chat route can stamp the resolved persona's canonical
// id into the rendered body (replacing E.14's raw `request.model` echo).
// It does NOT:
//
//   * fold in user-knowledge enrichment — the rich persona is preserved for
//     the final `tom_brain_access` and is out of prototype scope (§ 14).
//   * produce the `Access.persona` field — the full `PersonaResolver`
//     (E.26, identity/) does that for the dispatcher path. E.26 reuses this
//     same vocabulary (proto spec § 7.3 names the identical map); the two
//     substeps share one source of truth here rather than duplicating the
//     id list. Until E.26 lands, this is the only consumer.
//   * choose the substrate role per variant — every prototype persona
//     resolves to `assistant_to_user`; the `:terse` / `:verbose` variant
//     distinction lives entirely in `personaId` (Q-E.2.4 defers the
//     verbosity behaviour to the answer step's prompt assembly).

import 'package:tom_brain_shared/tom_brain_shared.dart';

/// Maps an OpenAI `model` string to the prototype [Persona] it names
/// (proto spec § 5.5, E.15).
///
/// The prototype recognises exactly three persona-as-model ids; every other
/// value — including a `null` model — resolves to [Persona.assistant]. All
/// three personas resolve to the substrate role
/// [Persona.defaultSubstrateRole] (`assistant_to_user`); the variant a
/// caller asked for is preserved in [Persona.personaId].
///
/// Pure and stateless — a namespaced set of static members, not an
/// instantiable object.
final class OpenAiPersonaMapping {
  const OpenAiPersonaMapping._();

  /// The base persona id (`tom-assistant`) — also the default when a
  /// request names no (or an unknown) model.
  static const String baseModel = Persona.defaultPersonaId;

  /// The terse-variant persona id.
  static const String terseModel = 'tom-assistant:terse';

  /// The verbose-variant persona id.
  static const String verboseModel = 'tom-assistant:verbose';

  /// The closed, ordered vocabulary of recognised persona-as-model ids.
  /// `GET /v1/models` (E.17) lists exactly these.
  static const List<String> knownModels = <String>[
    baseModel,
    terseModel,
    verboseModel,
  ];

  /// Resolves [model] to its [Persona].
  ///
  /// A recognised id (one of [knownModels]) yields a persona carrying that
  /// id and the prototype substrate role. A `null` or unrecognised model
  /// falls back to [Persona.assistant] — per AC-5 an unknown model is not an
  /// error.
  static Persona resolve(String? model) {
    if (model != null && knownModels.contains(model)) {
      return Persona(
        personaId: model,
        substrateRole: Persona.defaultSubstrateRole,
      );
    }
    return Persona.assistant();
  }

  /// Whether [model] is one of the recognised persona-as-model ids.
  static bool isKnown(String? model) =>
      model != null && knownModels.contains(model);
}
