// Todo 7 (G-PR2/G-PR3) — the three procedure-subsystem roles
// (`procedure_specification.md` § 8.2 / § 10.3).
//
// The procedure subsystem authors, gates, and selects procedures with three
// dedicated roles. Per spec § 10.3:
//
//   | Role                 | Used in                                          |
//   |----------------------|--------------------------------------------------|
//   | `procedure_author`   | The authoring branch (§ 8).                      |
//   | `procedure_critic`   | Post-draft / post-run critique of a procedure.   |
//   | `procedure_selector` | A tiebreak when retrieval returns several         |
//   |                      | plausible candidates.                            |
//
// All three carry the assistant-dedication anchor (§ 10.3) — `assemble()`
// injects it like every other role (§ 6.3).
//
// Why a *separate* group from `bootstrapRoleRegistry()` (and not added into
// it) — the same rationale as the Extension-H retrieval roster
// (`retrieval/retrieval_roles.dart`):
//
//   * `bootstrapRoleRegistry()` is pinned at exactly six core roles by
//     `b22_role_registry_test.dart` (`length == 6`). The three procedure
//     roles are a distinct, optional roster — a deployment that never runs
//     the procedure subsystem need not register them. Composing them is the
//     job of `bootstrapRoleRegistryWithProcedure()`, which a procedure-
//     enabled facade uses in place of the core-role bootstrap.
//
//   * Bootstrap *in code*, mirroring `bootstrap_roles.dart` and
//     `retrieval_roles.dart`: the persona / objective / output schema live in
//     code; the `<role>.system.md` on-disk form is the same future override
//     the core roles will gain (Plan-2 item 11). The authoring brief itself
//     (header shape, bridged-API subset, constraints) is supplied at call
//     time as the prompt body the role wraps — the template carries the
//     persona and the structured policy, not the full brief.
//
// Capability surface (§ 8.2 / § 10.3):
//
//   * `procedure_author` — drafts one d4rt source file. Reads past procedures
//     via recall (`memoryRead`) and runs the dry-run validator, a tool
//     (`toolCall`). It does not persist (the host procedure does), does not
//     speak to the user, and does not decompose into sub-questions.
//   * `procedure_critic` — a structured-verdict role (`accept | revise`),
//     sibling to the thinking-loop `evaluator`. Reads memory to cite prior
//     conclusions; never persists, never speaks to the user, never decomposes.
//   * `procedure_selector` — an `llmCall`-only evaluator over a caller-supplied
//     candidate list. Memory is LLM-free, so the candidates are fed as inputs,
//     not read here — hence no `memoryRead`.

import '../allowed_action.dart';
import '../bootstrap_roles.dart' show bootstrapRoleRegistry;
import '../retrieval/retrieval_roles.dart' show retrievalRoleTemplates;
import '../role_budget_defaults.dart';
import '../role_registry.dart';
import '../role_template.dart';

/// The three procedure-subsystem role ids, in canonical order
/// (`procedure_specification.md` § 10.3, top-to-bottom of the role table).
///
/// Iteration order of [procedureRoleTemplates] and
/// [bootstrapProcedureRoleRegistry] follows this list verbatim, so the trail /
/// observability layer sees a stable ordering.
const List<String> procedureRoleIds = <String>[
  'procedure_author',
  'procedure_critic',
  'procedure_selector',
];

/// The actions every procedure role forbids. None of the three speaks to the
/// user (their output is internal) or persists (the host procedure does).
const Set<AllowedAction> _procedureForbidden = <AllowedAction>{
  AllowedAction.userFacingAnswer,
  AllowedAction.memoryWrite,
};

/// Builds the three procedure `RoleTemplate` instances, in [procedureRoleIds]
/// order. Pure factory — no IO, no global state.
List<RoleTemplate> procedureRoleTemplates() => <RoleTemplate>[
      _procedureAuthor(),
      _procedureCritic(),
      _procedureSelector(),
    ];

/// A [RoleRegistry] holding exactly the three procedure roles.
///
/// Use this when only the procedure roster is needed (e.g. an authoring eval
/// harness). The full thinking + procedure roster is
/// [bootstrapRoleRegistryWithProcedure].
RoleRegistry bootstrapProcedureRoleRegistry() =>
    RoleRegistry(templates: procedureRoleTemplates());

/// A [RoleRegistry] holding the six core roles ([bootstrapRoleRegistry]) plus
/// the three procedure roles, in that order (nine roles total).
///
/// A procedure-enabled substrate facade composes its registry from this
/// factory in place of the core-role bootstrap. The bootstrap roster is
/// unchanged — `bootstrapRoleRegistry()` still returns exactly the six core
/// roles, so the b22 contract holds.
RoleRegistry bootstrapRoleRegistryWithProcedure() {
  final bootstrap = bootstrapRoleRegistry();
  return RoleRegistry(
    templates: <RoleTemplate>[
      ...bootstrap.templates,
      ...procedureRoleTemplates(),
    ],
  );
}

/// The full live roster: the six core roles, the six Extension-H retrieval
/// roles, and the three procedure roles (fifteen total), in that order.
///
/// This is the registry the prototype's run assembly composes — every role any
/// system procedure dispatches must be registered (the boot's `open()`
/// validates that each *routed* role is in the registry, and `complete()`
/// resolves it). Registering only the retrieval-enabled roster left the
/// authoring branch's `procedure_author` / `procedure_critic` /
/// `procedure_selector` calls unroutable; this factory adds them. The bootstrap
/// roster is unchanged — `bootstrapRoleRegistry()` still returns exactly the
/// six core roles, so the b22 contract holds.
RoleRegistry bootstrapRoleRegistryWithRetrievalAndProcedure() {
  final bootstrap = bootstrapRoleRegistry();
  return RoleRegistry(
    templates: <RoleTemplate>[
      ...bootstrap.templates,
      ...retrievalRoleTemplates(),
      ...procedureRoleTemplates(),
    ],
  );
}

// ----- `procedure_author` -----
//
// § 8.2: drafts a single d4rt source file with the structured header. Its
// tools are `recall` (look at past procedures), `read_api_reference`, and
// `validate_procedure` (the dry-run validator) — so it carries `memoryRead`
// (recall) and `toolCall` (the validator / api-reference pseudo-tools). It
// emits one source file; it does not decompose into sub-questions, does not
// persist (the host `author_new_procedure_v1` procedure does), and is not the
// user-facing voice.
RoleTemplate _procedureAuthor() {
  return RoleTemplate(
    id: 'procedure_author',
    personaText: 'I am the procedure author. I write a new cognitive '
        'procedure — a d4rt script over the bridged primitive-act API — when '
        'no existing procedure fits the request I exist to help with.',
    objective: 'Draft one d4rt source file with a valid structured header '
        '(id, version, summary, successCriterion, budget, inputs, outputs, '
        'requires) and a body that calls only the bridged-API subset the '
        'header declares. Look at past procedures as starting points; satisfy '
        'the dry-run validator; keep the procedure scoped to the stated '
        'intent. Emit the source only — the surrounding procedure validates, '
        'critiques, and records it.',
    allowedActions: const {
      AllowedAction.llmCall,
      AllowedAction.memoryRead,
      AllowedAction.toolCall,
    },
    forbiddenActions: const {
      ..._procedureForbidden,
      // The author emits one source file; it does not spawn sub-questions.
      AllowedAction.subThinking,
    },
    outputSchema: const <String, Object?>{
      'type': 'object',
      'required': <String>['source'],
      'properties': <String, Object?>{
        'source': <String, Object?>{'type': 'string'},
        // The author may volunteer a one-line rationale for the trail; the
        // body of the procedure cares only about `source`.
        'rationale': <String, Object?>{'type': 'string'},
      },
    },
    budgetDefaults: RoleBudgetDefaults.empty,
  );
}

// ----- `procedure_critic` -----
//
// § 8.3 step 5 / § 10.3: gates a (now-valid) draft, and critiques a run's
// outcome. A structured-verdict role like the thinking-loop `evaluator`, but
// its verdict alphabet is `accept | revise` (there is no `escalate` — an
// un-makeable-valid procedure is recorded at `authored` by the loop, not
// escalated by the critic). Reads memory to cite prior conclusions; never
// persists, never speaks to the user, never decomposes.
RoleTemplate _procedureCritic() {
  return RoleTemplate(
    id: 'procedure_critic',
    personaText: 'I am the procedure critic. I read a procedure draft (or a '
        'completed run) and judge whether it serves the stated intent well '
        'enough to record and use.',
    objective: 'Read the procedure draft and the intent it claims to serve. '
        'Decide between `accept` (the procedure is sound and fit for the '
        'intent) and `revise` (it is close but needs another authoring pass). '
        'Name the specific weakness that drove a `revise`; do not invent '
        'faults the draft does not exhibit.',
    allowedActions: const {
      AllowedAction.llmCall,
      AllowedAction.memoryRead,
    },
    forbiddenActions: const {
      ..._procedureForbidden,
      AllowedAction.subThinking,
    },
    outputSchema: const <String, Object?>{
      'type': 'object',
      'required': <String>['verdict'],
      'properties': <String, Object?>{
        'verdict': <String, Object?>{
          'type': 'string',
          'enum': <String>['accept', 'revise'],
        },
        'critique': <String, Object?>{'type': 'string'},
      },
    },
    budgetDefaults: RoleBudgetDefaults.empty,
  );
}

// ----- `procedure_selector` -----
//
// § 10.3: a small evaluator used when retrieval returns several plausible
// candidates and the runtime needs a tiebreak. The deterministic re-rank
// (`tom_core_agentic.scoreProcedureCandidate`) does the bulk of the ordering;
// this role is the LLM tiebreak over the top candidates. The candidate list is
// fed as inputs (memory is LLM-free, Q-H.1), so the role allows `llmCall` only
// — no `memoryRead`, no `toolCall`, no `subThinking`.
RoleTemplate _procedureSelector() {
  return RoleTemplate(
    id: 'procedure_selector',
    personaText: 'I am the procedure selector. From a short list of candidate '
        'procedures I pick the one most fit to handle the request.',
    objective: 'Given the request and a candidate list of procedures (each '
        'with its intent, summary, and track record), select the single most '
        'appropriate candidate and report a confidence in [0, 1]. Pick only '
        'from the candidates offered; do not invent a procedure. When no '
        'candidate is a good fit, say so with a low confidence so the runtime '
        'can take the authoring branch instead.',
    allowedActions: const {AllowedAction.llmCall},
    forbiddenActions: const {
      ..._procedureForbidden,
      AllowedAction.memoryRead,
      AllowedAction.toolCall,
      AllowedAction.subThinking,
    },
    outputSchema: const <String, Object?>{
      'type': 'object',
      'required': <String>['selected', 'confidence'],
      'properties': <String, Object?>{
        'selected': <String, Object?>{'type': 'string'},
        'confidence': <String, Object?>{
          'type': 'number',
          'minimum': 0,
          'maximum': 1,
        },
      },
    },
    budgetDefaults: RoleBudgetDefaults.empty,
  );
}
