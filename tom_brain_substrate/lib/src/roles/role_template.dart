// B.21 — `RoleTemplate` value class.
// B.23 — `RoleTemplate.assemble(...)` anchor-injecting producer of
//        `WirePrompt`. The B.21 forward note ("assemble(...) deferred
//        to B.23, not co-shipped at B.21") is closed by this step.
//
// Plan-step text (verbatim):
//   "B.21 Implement `RoleTemplate`: persona text, objective,
//    allowed-action set, budget defaults."
//   "B.23 Implement `AssistantDedicationAnchor` injection: every
//    prompt issued by the substrate is wrapped via
//    `tom_brain_shared.anchor.wrap(...)`. There is no path to bypass
//    it."
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
// Why `assemble(...)` lands at B.23 (not B.21):
//
//   * B.21 owns the value class — fields, validation, equality. The
//     producer of `WirePrompt` (the anchor-injection mechanism) is
//     B.23's responsibility. Splitting the two steps keeps the audit
//     trail clean: a reader of the B.21 commit sees only the value
//     class; a reader of the B.23 commit sees the anchor-injection
//     producer plus the enforcement test in one structurally clean
//     change.
//
//   * The `wire_prompt.dart` header (B.11) describes the eventual
//     layout (the only legitimate producer of `WirePrompt` is the
//     role registry, which goes through `assemble`). B.21 documents
//     the deferral; B.23 (this step) closes it.
//
// What B.23 adds to this file:
//
//   * The [assemble] method on `RoleTemplate`. Composes the two-channel
//     [WirePrompt]: the `system` channel is
//     `[anchor block] + [persona] + [objective] + [optional output
//      schema marker]` (the anchor prepended via
//     [AssistantDedicationAnchor.ensurePrefix]); the `user` channel is
//     the per-call `[inputs]`. It then stamps
//     [AnchorRegistry.currentHash] on the produced [WirePrompt].
//     (Prompt-restructuring plan step 4 split the former single body
//     into these two channels and removed the old `_composeBody`.)
//
//   * The structural enforcement of Postulate 3: every [WirePrompt]
//     this method returns has its [WirePrompt.system] starting with
//     [AssistantDedicationAnchor.text] (via `ensurePrefix`), and its
//     [WirePrompt.anchorHash] equal to [AnchorRegistry.currentHash].
//     Tests at `test/b23_anchor_injection_test.dart` pin this for
//     every bootstrap role and every tampering vector enumerated in
//     `assistant_dedication_anchor.dart` (already-wrapped input,
//     empty input, whitespace-only input, inputs that try to inject
//     before the anchor block).
//
// What this file deliberately does NOT own:
//
//   * The anchor text. Lives in
//     `tom_brain_shared/lib/src/anchor/assistant_dedication_anchor.dart`
//     (A.17). B.23's [assemble] imports the constant via the shared-
//     layer barrel — `AssistantDedicationAnchor.wrap` performs the
//     idempotent prepend.
//
//   * The anchor hash. Lives in
//     `tom_brain_substrate/lib/src/llm/anchor_registry.dart` (B.23).
//     The shared layer cannot host the hash because A.9 forbids
//     `package:crypto` at the shared-types layer.
//
//   * The template body / sha. Lives in B.36's `templateRef` (the
//     file-backed loader). [assemble] omits the optional template
//     body until B.36 lands; the deferral is documented inline in
//     the method body.
//
//   * The dispatcher-side gate that enforces `allowedActions` /
//     `forbiddenActions` against a procedure's attempted operations.
//     Lives in Phase D (`tom_brain_procedure_dispatcher`). This file
//     only *declares* what is allowed; nothing here enforces.
//
//   * Per-call options resolution against [budgetDefaults] (router
//     concern at B.18+). [assemble] does not touch `LlmOptions`.

import 'dart:convert' show jsonEncode;

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show AssistantDedicationAnchor;
import 'package:tom_core_agentic/tom_core_agentic.dart' show textPreview;

import '../llm/anchor_registry.dart';
import 'package:tom_core_llm/tom_core_llm.dart';
import 'allowed_action.dart';
import 'role_budget_defaults.dart';
import 'system_scaffold.dart';

/// One role the substrate's LLM path can dispatch under.
///
/// Sourced from a role config file at registry `open()` time
/// (B.22 — `_ai/prompts/<role>.system.md` plus the matching
/// `roles_registry.yaml` entry). The six core roles
/// (`assistant_to_user`, `analyser`, `sub_thinker`, `recaller`,
/// `evaluator`, `researcher`) each materialise as a `RoleTemplate`
/// instance.
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

  /// Assembles a [WirePrompt] from this role's preamble and the
  /// caller-supplied [inputs] map.
  ///
  /// **Anchor invariant (Postulate 3 / Plan step B.23).** The
  /// returned [WirePrompt] is guaranteed:
  ///
  /// 1. Its [WirePrompt.system] starts with
  ///    [AssistantDedicationAnchor.text]. This is structural — the
  ///    assembled body is run through
  ///    [AssistantDedicationAnchor.wrap], which is idempotent and
  ///    rejects no-op (empty / whitespace-only) inputs by returning
  ///    the anchor alone.
  /// 2. Its [WirePrompt.anchorHash] equals
  ///    [AnchorRegistry.currentHash]. The hash is stamped here, on
  ///    every assembled prompt, with no per-role override path.
  /// 3. Its [WirePrompt.roleId] equals this template's [id], so the
  ///    trail can correlate the wire prompt with the role that
  ///    emitted it without reading the body.
  /// 4. Its [WirePrompt.templateSha] is the file-backed loader's
  ///    `templateRef` once B.36 lands; for now it is always `null`
  ///    (bootstrap-in-code roles have no git sha to point at — see
  ///    Q-B.22.3 in `prototype_implementation_questions.md`).
  ///
  /// **Channel split (prompt-restructuring plan step 4).** [assemble]
  /// produces the two-channel [WirePrompt]:
  ///
  ///   - [WirePrompt.system] — the standing framing, anchor-first. Built
  ///     from [_composeSystem] (persona / objective / optional output
  ///     schema) and then run through
  ///     [AssistantDedicationAnchor.ensurePrefix], so the anchor leads the
  ///     system channel even though the scaffold itself never emits it.
  ///     This is the in-code fallback for the role framing; Phase 3 of the
  ///     plan moves the `PERSONA:` / `OBJECTIVE:` / `OUTPUT SCHEMA:`
  ///     scaffolding into per-role `<role>.system.md` template files while
  ///     keeping this in-code rendering as the reviewed fallback.
  ///   - [WirePrompt.user] — the call-specific content. Built from
  ///     [_composeUser]: one `key: value` line per [inputs] entry, in
  ///     declaration order. An empty [inputs] map yields an empty user
  ///     half (legal — a system-only prompt). Phase 4/5 of the plan moves
  ///     this per-call rendering into `<role>.user.md` template slots.
  ///
  /// **System layout** ([_composeSystem], before the anchor is prepended):
  ///
  /// ```
  /// PERSONA:
  /// <personaText>
  ///
  /// OBJECTIVE:
  /// <objective>
  ///
  /// [OUTPUT SCHEMA (only when outputSchema != null):
  /// Respond with a single JSON object … that conforms to this
  /// JSON schema:
  /// <jsonEncode(outputSchema)>]
  /// ```
  ///
  /// **User layout** ([_composeUser]):
  ///
  /// ```
  /// <key>: <value (toString)>
  /// <key>: <value (toString)>
  /// ...
  /// ```
  ///
  /// **Input value serialisation.** Each input value is converted via
  /// `Object?.toString()` — the role layer does not enforce
  /// JSON-encodability here (the api/-layer [LlmCall.inputs] doc reserves
  /// the right to validate inputs against the role's declared schema). The
  /// only requirement at this step is "produce a user channel the model
  /// can read"; `toString` is the minimum that satisfies that.
  ///
  /// **No bypass.** This is the only method on the role layer that
  /// constructs [WirePrompt]. Dart has no friend access (see
  /// `wire_prompt.dart` header), so the type does not *forbid*
  /// other construction — but every production path that ends in
  /// `LlmProvider.complete` goes through [assemble], and the B.46
  /// conformance test (Plan step B.46) reads every provider
  /// report's anchor hash and fails the build if it does not
  /// equal [AnchorRegistry.currentHash]. The combination is the
  /// structural proof of Postulate 3.
  WirePrompt assemble({
    Map<String, Object?> inputs = const {},
    bool anchored = true,
  }) {
    // The per-run anchoring toggle (`session_configuration.md` § 3.4, plan
    // step 9 / SCP-36). Anchored (the default) is the Postulate-3 path: the
    // scaffold leads with `${role.anchor}` and `ensurePrefix` guarantees it
    // structurally. Un-anchored is the deliberate escape for a small set of
    // profiles (the passthrough relay): the scaffold renders with an empty
    // anchor slot AND `ensurePrefix` is skipped, so the anchor is genuinely
    // absent — never re-prepended — and the prompt records the un-anchored
    // sentinel so the trail can flag the run (SCP-37).
    final composed = _composeSystem(anchored: anchored);
    if (!anchored) {
      return WirePrompt(
        system: composed,
        user: _composeUser(inputs),
        anchorHash: AnchorRegistry.unanchoredHash,
        roleId: id,
        templateSha: null,
      );
    }
    // `ensurePrefix`, not `wrap`. The shared `wrap` keys idempotency on
    // `contains(text)`, giving only the *contains-anchor* guarantee — if
    // the system scaffold happened to include the anchor text mid-string,
    // `wrap` would leave it unmoved and the channel would start with
    // `PERSONA:`, violating the anchor-leads-`system` invariant.
    // `ensurePrefix` keys idempotency on `startsWith` and so always
    // produces the strict starts-with guarantee. One anchor mechanism,
    // owned by the shared primitive, used everywhere.
    final system = AssistantDedicationAnchor.ensurePrefix(composed);
    final user = _composeUser(inputs);
    return WirePrompt(
      system: system,
      user: user,
      anchorHash: AnchorRegistry.currentHash,
      roleId: id,
      // templateSha stays null until the file-backed loader assigns a git
      // sha (Q-B.22.3). Documented on the field.
      templateSha: null,
    );
  }

  /// Builds the system channel by rendering the shared [SystemScaffold]
  /// template with this role's persona, objective, and optional
  /// output-schema section.
  ///
  /// The scaffold layout (the `PERSONA:` / `OBJECTIVE:` / `OUTPUT SCHEMA:`
  /// framing and the `${role.anchor}` lead) lives in [SystemScaffold.template]
  /// as placeholder-bearing text (plan step 6 / `prompt_configuration.md`
  /// § 13.1) — this method only supplies the injected values. The rendered
  /// text already leads with the anchor (via `${role.anchor}`); [assemble]
  /// still runs it through [AssistantDedicationAnchor.ensurePrefix], which is
  /// idempotent here, so the anchor cannot be defeated by editing the
  /// scaffold. The test suite at `b23_anchor_injection_test.dart` pins the
  /// individual sections (persona present, objective present, output-schema
  /// marker present iff `outputSchema != null`) and
  /// `system_scaffold_test.dart` pins the exact assembled layout.
  String _composeSystem({bool anchored = true}) => SystemScaffold.render(
    persona: personaText,
    objective: objective,
    outputSchemaSection: outputSchema == null
        ? ''
        : _outputSchemaSection(outputSchema!),
    anchored: anchored,
  );

  /// The fully composed `OUTPUT SCHEMA:` section for a role that declares an
  /// [outputSchema], including its own leading `\n\n` separator so the
  /// [SystemScaffold] can append it directly after the objective with no
  /// intervening blank-line placeholder.
  ///
  /// Embeds the *actual* schema, not a meta-reference to it. A model can only
  /// emit the declared key names (e.g. `questions`) when the schema body is in
  /// the prompt; a dangling "match this role's outputSchema" sentence left the
  /// model to guess the shape and it answered with the wrong keys (and inside
  /// markdown fences). This mirrors the `StrictFormatAdapter` re-emit block,
  /// which already `jsonEncode`s the schema — one structured-output
  /// convention, used on both the first emit and the format retry.
  static String _outputSchemaSection(Map<String, Object?> schema) =>
      '\n\nOUTPUT SCHEMA:\n'
      'Respond with a single JSON object — and nothing else: no prose, no '
      'markdown code fences, no commentary — that conforms to this JSON '
      'schema:\n'
      '${jsonEncode(schema)}';

  /// Builds the user channel: the caller-supplied [inputs], one
  /// `key: value` line per entry, in declaration (insertion) order.
  ///
  /// An empty [inputs] map produces an empty string — a legal empty user
  /// half for a system-only prompt. Each value is rendered via
  /// `Object?.toString()`; the role layer does not trim values (a
  /// whitespace-only value renders verbatim) and `null` stringifies as the
  /// literal `null`.
  String _composeUser(Map<String, Object?> inputs) {
    if (inputs.isEmpty) return '';
    return inputs.entries
        .map((entry) => '${entry.key}: ${entry.value}')
        .join('\n');
  }

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
  String toString() =>
      'RoleTemplate('
      'id: $id, '
      'personaText: "${textPreview(personaText, limit: 37, ellipsis: '...')}", '
      'objective: "${textPreview(objective, limit: 37, ellipsis: '...')}", '
      'allowedActions: ${allowedActions.map((a) => a.token).toList()}, '
      'forbiddenActions: ${forbiddenActions.map((a) => a.token).toList()}, '
      'outputSchema: ${outputSchema == null ? 'null' : '<set>'}, '
      'budgetDefaults: $budgetDefaults)';
}
