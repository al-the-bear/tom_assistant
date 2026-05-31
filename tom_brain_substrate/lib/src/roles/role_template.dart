// B.21 — `RoleTemplate`.
//
// Plan-step text (verbatim):
//   "B.21 Implement `RoleTemplate`: persona text, objective,
//    allowed-action set, budget defaults."
//
// `substrate_specification.md` § 6.1 lists eight fields for
// `RoleTemplate`: `id`, `personaText`, `objective`, `allowedActions`,
// `forbiddenActions`, `outputSchema`, `budgetDefaults`, `templateRef`.
// The B.21 plan text names four (`personaText`, `objective`,
// `allowedActions`, `budgetDefaults`). The remaining four split as:
//
//   * `id`              — included at B.21; the registry key is
//                         load-bearing for every downstream consumer
//                         (router resolution, trail attribution, the
//                         dispatcher's gate). Omitting it would leave
//                         the value class incoherent.
//   * `forbiddenActions`— included at B.21 (defaults to empty); the
//                         field is the structural counterpart to
//                         `allowedActions` and adding it later forces a
//                         constructor-signature change for zero
//                         additional implementation cost now.
//   * `outputSchema`    — included as optional (`null` default). Roles
//                         that emit structured output (the evaluator's
//                         JSON-shaped critique, the recaller's ranked
//                         list) need the slot; roles that emit free
//                         text leave it null.
//   * `templateRef`     — *deferred to B.22*. The template registry
//                         step is where templates are loaded from
//                         `_ai/prompts/<role>.system.md` and assigned
//                         their git sha. Including the field at B.21
//                         would either force a non-functional placeholder
//                         or pull the YAML loader forward into this
//                         step. The B.22 forward note records the
//                         shape this field will take.
//
// Why no `assemble(...)` method at B.21:
//
//   * B.23 (verbatim plan text): "Implement `AssistantDedicationAnchor`
//     injection: every prompt issued by the substrate is wrapped via
//     `tom_brain_shared.anchor.wrap(...)`. There is no path to bypass
//     it." — the assemble path *is* the injection mechanism and is the
//     subject of its own plan step. Shipping `assemble(...)` at B.21
//     would either (a) duplicate the wrap call across two steps, or
//     (b) pre-empt B.23's anchor-enforcement test surface. Keeping
//     B.21 strictly to the value class leaves B.23 free to land the
//     producer in one structurally clean change.
//
//   * The `wire_prompt.dart` header (B.11) already documents that
//     "only constructor runs through `RoleTemplate.assemble(...)`,
//     which calls `tom_brain_shared.anchor.wrap(...)` unconditionally"
//     — that doc-comment correctly describes the *eventual* layout
//     after B.23 lands; it does not require B.21 to ship the method.
//     B.21's forward note in this file's header makes the staged
//     handoff explicit.
//
// What this file deliberately does NOT own:
//
//   * The anchor mechanism. Lives in
//     `tom_brain_shared/lib/src/anchor/assistant_dedication_anchor.dart`
//     (A.17). The value class does not import the anchor; only the
//     B.23 `assemble(...)` method will.
//
//   * The template body / sha. Lives in B.22's `templateRef`. The
//     `RoleTemplate` shipped here has no body text — `personaText` and
//     `objective` are the structured fields the eventual assemble path
//     will weave with the template body and the user inputs.
//
//   * The registry that holds `RoleTemplate` instances. Lives at B.22
//     in `roles_registry.dart` (yet to land). The five prototype
//     roles are constructed there from YAML / Markdown sources; this
//     file only provides the value class.
//
//   * The dispatcher-side gate that enforces `allowedActions` /
//     `forbiddenActions` against a procedure's attempted operations.
//     Lives in Phase D (`tom_brain_procedure_dispatcher`). This file
//     only *declares* what is allowed; nothing here enforces.

import 'allowed_action.dart';
import 'role_budget_defaults.dart';

/// One role the substrate's LLM path can dispatch under.
///
/// Sourced from a role config file at registry `open()` time
/// (B.22 — `_ai/prompts/<role>.system.md` plus the matching
/// `roles_registry.yaml` entry). The five prototype roles
/// (`assistant_to_user`, `analyser`, `sub_thinker`, `recaller`,
/// `evaluator`) each materialise as a `RoleTemplate` instance.
///
/// `RoleTemplate` is a *value class*: immutable, `==` / `hashCode`
/// defined, no mutable state. The registry hands the same instance
/// out to every consumer; safe to compare by reference or by value.
///
/// Subclassing is forbidden (`final class`) — every role goes through
/// the same `assemble(...)` mechanism (added at B.23) and a subclass
/// would invite a per-role override of the anchor injection path,
/// the exact bypass Postulate 3 / spec § 6.3 structurally prevents.
final class RoleTemplate {
  /// Stable role key — `assistant_to_user`, `analyser`, `sub_thinker`,
  /// `recaller`, `evaluator` for the prototype roster.
  ///
  /// The registry rejects duplicate ids at `open()`; downstream
  /// consumers (router, dispatcher, trail) treat the id as the
  /// canonical identity. Renaming a role is a coordinated migration
  /// (new id, retire the old one); a free in-place rename would
  /// orphan every trail entry recorded against the prior id.
  final String id;

  /// The role's voice — short, role-bound.
  ///
  /// Concatenated into the system prompt at assemble time (B.23).
  /// Tone: first-person, present-tense ("I am the evaluator. I read
  /// proposed answers and …"), to keep the anchor's identity-framing
  /// shape consistent. The text is *additional* framing on top of
  /// the assistant-dedication anchor, never a replacement for it.
  ///
  /// Validated non-empty at construction — a role without a persona
  /// is structurally incoherent; an empty string would produce a
  /// blank line in the assembled prompt with no diagnostic.
  final String personaText;

  /// One paragraph: what this role is responsible for.
  ///
  /// Reads as a directive sentence ("Critique the proposed answer
  /// against the criteria below and emit a JSON-shaped result with
  /// `accept | revise | escalate`."). Concatenated into the system
  /// prompt after [personaText]; together they form the role's
  /// preamble before the template body (B.22) and the user inputs
  /// land.
  ///
  /// Validated non-empty at construction — a role without an
  /// objective gives the model no task and produces unbounded output.
  final String objective;

  /// What this role is allowed to do — the closed action set
  /// declared up front so the dispatcher's gate (Phase D) can refuse
  /// out-of-scope attempts without consulting the procedure.
  ///
  /// A role that omits an action *cannot* perform it: the dispatcher
  /// defaults to deny. Listing all actions a role needs is required.
  /// Stored as an unmodifiable [Set] so the registry's distribution
  /// guarantee (every consumer sees the same view) is structural.
  final Set<AllowedAction> allowedActions;

  /// Hard prohibitions — actions a role is explicitly forbidden
  /// from, regardless of any procedure-level grant.
  ///
  /// Semantically distinct from "absent from [allowedActions]":
  /// absent ⇒ "not granted by this role; a future variant could
  /// grant it"; forbidden ⇒ "this role is *defined by* not doing
  /// this, and no variant or override can grant it." The dispatcher
  /// reads forbidden as a structural denial even if a higher layer
  /// would have allowed.
  ///
  /// Defaults to `const <AllowedAction>{}`. An action that appears
  /// in both [allowedActions] and [forbiddenActions] is rejected at
  /// construction — the conflict is a bug in the role config, not
  /// something to resolve silently in favour of one or the other.
  final Set<AllowedAction> forbiddenActions;

  /// Optional JSON-schema-shaped structured-output declaration.
  ///
  /// `null` ⇒ free-form text output. A non-null schema lands on
  /// `LlmOptions.responseFormat` at submission (B.23 / B.40) — the
  /// router merges it with the per-call `LlmOptions.responseFormat`
  /// (per-call wins when both are non-null).
  ///
  /// Stored as `Map<String, Object?>?` rather than a stronger
  /// `JsonSchema` type because the schema vocabulary is provider-
  /// portable JSON and a stronger type would force every role-config
  /// load to validate the schema body — a check that belongs at the
  /// (yet-to-exist) JsonSchema layer, not here.
  final Map<String, Object?>? outputSchema;

  /// Token / wall-clock / model-preference defaults the router
  /// applies when the `LlmOptions` leaves the corresponding field
  /// unset.
  ///
  /// See `role_budget_defaults.dart` for the resolution order and
  /// the per-field semantics. Defaults to [RoleBudgetDefaults.empty]
  /// — "role provides no guidance; fall through to per-call options
  /// then to provider defaults."
  final RoleBudgetDefaults budgetDefaults;

  /// Constructs a [RoleTemplate].
  ///
  /// Validation:
  ///   * [id] must be non-empty and contain no whitespace (the
  ///     registry / trail / YAML loader all treat it as an
  ///     identifier; whitespace would break round-trip equality).
  ///   * [personaText] and [objective] must be non-empty after
  ///     `trim()`. A role with an empty persona or objective is
  ///     structurally incoherent.
  ///   * [allowedActions] may be empty (a no-op role); the
  ///     [forbiddenActions] cap still applies.
  ///   * No action may appear in both [allowedActions] and
  ///     [forbiddenActions] — that conflict is a config bug.
  ///
  /// Each violation throws an [ArgumentError] at construction so
  /// the registry's `open()` step fails loudly on a bad config
  /// rather than per-dispatch.
  ///
  /// Field freezing: [allowedActions] / [forbiddenActions] are
  /// wrapped in [Set.unmodifiable] / [Map.unmodifiable] so a
  /// consumer that holds the returned reference cannot mutate the
  /// registry's view by accident.
  factory RoleTemplate({
    required String id,
    required String personaText,
    required String objective,
    required Set<AllowedAction> allowedActions,
    Set<AllowedAction> forbiddenActions = const <AllowedAction>{},
    Map<String, Object?>? outputSchema,
    RoleBudgetDefaults budgetDefaults = RoleBudgetDefaults.empty,
  }) {
    if (id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'must be non-empty');
    }
    if (RegExp(r'\s').hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'must not contain whitespace');
    }
    if (personaText.trim().isEmpty) {
      throw ArgumentError.value(
        personaText,
        'personaText',
        'must be non-empty after trim',
      );
    }
    if (objective.trim().isEmpty) {
      throw ArgumentError.value(
        objective,
        'objective',
        'must be non-empty after trim',
      );
    }
    final overlap = allowedActions.intersection(forbiddenActions);
    if (overlap.isNotEmpty) {
      throw ArgumentError.value(
        overlap.map((a) => a.token).toList(),
        'allowedActions / forbiddenActions',
        'an action may not appear in both sets',
      );
    }
    return RoleTemplate._(
      id,
      personaText,
      objective,
      Set<AllowedAction>.unmodifiable(allowedActions),
      Set<AllowedAction>.unmodifiable(forbiddenActions),
      outputSchema == null
          ? null
          : Map<String, Object?>.unmodifiable(outputSchema),
      budgetDefaults,
    );
  }

  const RoleTemplate._(
    this.id,
    this.personaText,
    this.objective,
    this.allowedActions,
    this.forbiddenActions,
    this.outputSchema,
    this.budgetDefaults,
  );

  /// True if [action] is in [allowedActions] and *not* in
  /// [forbiddenActions]. Convenience shortcut for the dispatcher's
  /// gate (Phase D); centralising the predicate here keeps the
  /// "forbidden wins over allowed" rule co-located with the field
  /// declarations.
  bool permits(AllowedAction action) =>
      allowedActions.contains(action) && !forbiddenActions.contains(action);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! RoleTemplate) return false;
    if (other.id != id) return false;
    if (other.personaText != personaText) return false;
    if (other.objective != objective) return false;
    if (other.budgetDefaults != budgetDefaults) return false;
    if (!_setEq(other.allowedActions, allowedActions)) return false;
    if (!_setEq(other.forbiddenActions, forbiddenActions)) return false;
    if (!_mapEq(other.outputSchema, outputSchema)) return false;
    return true;
  }

  static bool _setEq(Set<AllowedAction> a, Set<AllowedAction> b) {
    if (a.length != b.length) return false;
    for (final v in a) {
      if (!b.contains(v)) return false;
    }
    return true;
  }

  static bool _mapEq(Map<String, Object?>? a, Map<String, Object?>? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k)) return false;
      if (a[k] != b[k]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        id,
        personaText,
        objective,
        Object.hashAllUnordered(allowedActions),
        Object.hashAllUnordered(forbiddenActions),
        outputSchema == null ? null : Object.hashAll(outputSchema!.keys),
        budgetDefaults,
      );

  @override
  String toString() => 'RoleTemplate('
      'id: $id, '
      'personaText: ${_truncate(personaText)}, '
      'objective: ${_truncate(objective)}, '
      'allowedActions: ${allowedActions.map((a) => a.token).toList()}, '
      'forbiddenActions: ${forbiddenActions.map((a) => a.token).toList()}, '
      'outputSchema: ${outputSchema == null ? 'null' : '<set>'}, '
      'budgetDefaults: $budgetDefaults)';

  static String _truncate(String s) =>
      s.length <= 40 ? '"$s"' : '"${s.substring(0, 37)}..."';
}
