// `PersonaResolver` — the edge step that resolves *which persona* answers an
// inbound request (E.26).
//
// What this file owns (Plan § Phase E, substep E.26; proto spec § 7.3;
// AC-5):
//
//   * `PersonaResolver` — maps a model id (or the absence of one) to the
//     `tom_brain_shared` `Persona` the dispatcher hands to substrate. The
//     prototype recognises exactly the three persona-as-model ids
//     (`tom-assistant`, `tom-assistant:terse`, `tom-assistant:verbose`),
//     all resolving to the single substrate role `assistant_to_user`; the
//     variant a caller asked for is preserved in `Persona.personaId`. An
//     absent or unrecognised model id is *not* an error — it falls back to
//     `Persona.assistant()` (AC-5). This is the third and last of the three
//     resolvers that fill an `Access` (identity E.24, session E.25, persona
//     E.26).
//
// Why it reuses the adapter's vocabulary rather than restating it:
//
//   E.15's `OpenAiPersonaMapping` already owns the closed persona-as-model
//   id list as a pure, network-free constant (it imports only
//   `tom_brain_shared`). The E.15 log fixed that the two substeps "share
//   one source of truth here rather than duplicating the id list", with
//   E.26 named as the second consumer. So this resolver's *default*
//   vocabulary is `OpenAiPersonaMapping.knownModels` — the one id list,
//   not a copy. The resolver remains the layer that turns that vocabulary
//   into a `Persona` for the dispatcher path (`OpenAiPersonaMapping` does
//   the same for the adapter's own E.15 model-id echo / E.17 listing).
//
// Why the vocabulary is injectable (but defaults to the shared list):
//
//   `AccessConfig` (§ 11.4) lists "the persona vocabulary" as configuration
//   loaded at boot (E.41+). So the resolver accepts an optional vocabulary
//   and resolves against it with the same rule; when none is given it uses
//   the shared prototype list. The prototype always uses the default — the
//   seam exists so boot can widen the vocabulary without a code change.
//
// Scope discipline (per the strict per-substep log). E.26 is the model-id →
// persona resolver only. It does NOT:
//
//   * resolve identity (E.24, `IdentityResolver`) or sessions (E.25,
//     `SessionManager`) — the other two `Access`-filling resolvers.
//   * fold in user-knowledge enrichment — the rich persona ("everything we
//     know about the user", thinking spec § 2 / § 10) is preserved for the
//     final `tom_brain_access` and is out of prototype scope (§ 14 / proto
//     spec § 7.3). The prototype keeps it a pure id → template map.
//   * choose the substrate role per variant — every prototype persona
//     resolves to `assistant_to_user`; the `:terse` / `:verbose` variant
//     distinction lives entirely in `personaId` (Q-E.2.4 defers the
//     verbosity behaviour to the answer step's prompt assembly).
//   * construct an `Access` or wire boot (E.41+).

import 'package:tom_brain_shared/tom_brain_shared.dart';

import '../adapters/openai_http_sse/persona_mapping.dart';

/// Resolves a model id (or its absence) to the [Persona] handed to
/// substrate (proto spec § 7.3, E.26).
///
/// A recognised model id (one of [knownModels]) yields a persona carrying
/// that id and the prototype substrate role ([Persona.defaultSubstrateRole],
/// `assistant_to_user`). A `null` or unrecognised model id falls back to
/// [Persona.assistant] — per AC-5 an unknown model is not an error, it
/// defaults.
///
/// Stateless after construction (the vocabulary is fixed at build time);
/// safe to share across requests.
final class PersonaResolver {
  /// The closed, ordered vocabulary of recognised persona-as-model ids this
  /// resolver maps. Defaults to the shared [OpenAiPersonaMapping.knownModels]
  /// (the single source of truth E.15 established); boot (E.41+) may inject a
  /// wider list from `AccessConfig`.
  final List<String> knownModels;

  /// Builds a resolver over [knownModels] (default: the shared prototype
  /// persona vocabulary). The list is copied unmodifiable so a caller's later
  /// mutation cannot change resolution mid-flight.
  PersonaResolver({List<String>? knownModels})
      : knownModels = List<String>.unmodifiable(
          knownModels ?? OpenAiPersonaMapping.knownModels,
        );

  /// Resolves [modelId] to its [Persona].
  ///
  /// A recognised id (one of [knownModels]) yields a persona carrying that id
  /// and [Persona.defaultSubstrateRole]. A `null` or unrecognised id falls
  /// back to [Persona.assistant] (AC-5 — an unknown model id is not an error).
  Persona resolve(String? modelId) {
    if (isKnown(modelId)) {
      return Persona(
        personaId: modelId!,
        substrateRole: Persona.defaultSubstrateRole,
      );
    }
    return Persona.assistant();
  }

  /// Whether [modelId] is one of this resolver's recognised persona ids.
  bool isKnown(String? modelId) =>
      modelId != null && knownModels.contains(modelId);
}
