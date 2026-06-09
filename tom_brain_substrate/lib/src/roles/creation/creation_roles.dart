// Todo 9 (G-C4) — the three creation-subsystem roles
// (`creation_specification.md` § 6).
//
// The creation loop authors, tests, and reviews a single artifact with three
// dedicated roles (spec § 6):
//
//   | Role       | Purpose                                              |
//   |------------|------------------------------------------------------|
//   | `creator`  | The artifact author.                                 |
//   | `tester`   | Test / success-check author when test-first applies. |
//   | `reviewer` | The critic.                                          |
//
// All three carry the assistant-dedication anchor (§ 6) — `assemble()` injects
// it like every other role.
//
// Why a *separate* group from `bootstrapRoleRegistry()` — the same rationale as
// the Extension-H retrieval roster and the Todo-7 procedure roster
// (`procedure/procedure_roles.dart`):
//
//   * `bootstrapRoleRegistry()` is pinned at exactly six core roles by
//     `b22_role_registry_test.dart`. The three creation roles are a distinct,
//     optional roster — a deployment that never runs the creation loop need not
//     register them. Composing the full live roster (core + retrieval +
//     procedure + creation) is the job of
//     [bootstrapRoleRegistryWithRetrievalProcedureAndCreation], which the run
//     assembly uses in place of the procedure-only roster.
//
//   * Bootstrap *in code*, mirroring `bootstrap_roles.dart`,
//     `retrieval_roles.dart`, and `procedure_roles.dart`: the persona /
//     objective / output schema live in code; the `<role>.system.md` on-disk
//     override is the same future seam the core roles will gain (Plan-2 item
//     11). The per-`kind` style guide the `creator` role is parameterised by
//     (§ 6 — `creator-code` / `creator-doc` / `creator-config`) is supplied at
//     call time as the prompt body the role wraps, not baked into the template.
//
// Capability surface (§ 5 tool families, § 6 roles):
//
//   * `creator` — authors one artifact draft. Runs file / analyze / format /
//     test tools (`toolCall`) and reads memory for context (`memoryRead`). It
//     does not persist (the host `create_v1` procedure does), does not speak to
//     the user, and does not decompose into sub-questions.
//   * `tester` — authors the test / success check and runs it. Same capability
//     shape as `creator`: it drafts a test file and exercises it through the
//     test tool, so it carries `memoryRead` + `toolCall`.
//   * `reviewer` — a structured-verdict role (`accept | revise`), sibling to the
//     thinking-loop `evaluator` and the `procedure_critic`. It judges the draft
//     against the success criterion using the analyzer / test signals fed as
//     inputs; it reads memory to cite prior conclusions but runs no tools of its
//     own, never persists, never speaks to the user, never decomposes.

import '../allowed_action.dart';
import '../procedure/procedure_roles.dart'
    show bootstrapRoleRegistryWithRetrievalAndProcedure;
import '../role_budget_defaults.dart';
import '../role_registry.dart';
import '../role_template.dart';

/// The three creation-subsystem role ids, in canonical order
/// (`creation_specification.md` § 6, top-to-bottom of the role table).
///
/// Iteration order of [creationRoleTemplates] and
/// [bootstrapCreationRoleRegistry] follows this list verbatim, so the trail /
/// observability layer sees a stable ordering.
const List<String> creationRoleIds = <String>[
  'creator',
  'tester',
  'reviewer',
];

/// The actions every creation role forbids. None of the three speaks to the
/// user (their output is internal to the loop), persists (the host `create_v1`
/// procedure does), or decomposes into sub-questions.
const Set<AllowedAction> _creationForbidden = <AllowedAction>{
  AllowedAction.userFacingAnswer,
  AllowedAction.memoryWrite,
  AllowedAction.subThinking,
};

/// Builds the three creation `RoleTemplate` instances, in [creationRoleIds]
/// order. Pure factory — no IO, no global state.
List<RoleTemplate> creationRoleTemplates() => <RoleTemplate>[
      _creator(),
      _tester(),
      _reviewer(),
    ];

/// A [RoleRegistry] holding exactly the three creation roles.
///
/// Use this when only the creation roster is needed (e.g. a creation-loop eval
/// harness). The full live roster is
/// [bootstrapRoleRegistryWithRetrievalProcedureAndCreation].
RoleRegistry bootstrapCreationRoleRegistry() =>
    RoleRegistry(templates: creationRoleTemplates());

/// The full live roster: the six core roles, the six Extension-H retrieval
/// roles, the three procedure roles, and the three creation roles (eighteen
/// total), in that layer order.
///
/// This is the registry the run assembly composes once the creation loop is
/// enabled — every role any system procedure dispatches must be registered (the
/// boot's `open()` validates that each *routed* role is in the registry, and
/// `complete()` resolves it). It extends
/// [bootstrapRoleRegistryWithRetrievalAndProcedure] (the Todo-7 roster) with the
/// `creator` / `tester` / `reviewer` roles `create_v1` dispatches; the bootstrap
/// roster is unchanged — `bootstrapRoleRegistry()` still returns exactly the six
/// core roles, so the b22 contract holds.
RoleRegistry bootstrapRoleRegistryWithRetrievalProcedureAndCreation() {
  final withProcedure = bootstrapRoleRegistryWithRetrievalAndProcedure();
  return RoleRegistry(
    templates: <RoleTemplate>[
      ...withProcedure.templates,
      ...creationRoleTemplates(),
    ],
  );
}

// ----- `creator` -----
//
// § 6 / § 5: the artifact author. Drafts one artifact and runs the file /
// analyze / format tool families to observe and write it (`toolCall`); reads
// memory for context (`memoryRead`). It emits the draft; it does not persist
// (the host procedure does), is not the user-facing voice, and does not spawn
// sub-questions.
RoleTemplate _creator() {
  return RoleTemplate(
    id: 'creator',
    personaText: 'I am the artifact creator. I produce a single artifact — a '
        'code file, a document, or a config — that satisfies the stated intent '
        'and its observable success criterion, in service of the user I exist '
        'to help.',
    objective: 'Observe the environment with the file and code-understanding '
        'tools, then draft and write the one artifact the intent names. Stay '
        'within the file-scope sandbox; honour the success criterion exactly; '
        'follow the style guide for the artifact kind. Emit the artifact — the '
        'surrounding loop tests, reviews, and records it.',
    allowedActions: const {
      AllowedAction.llmCall,
      AllowedAction.memoryRead,
      AllowedAction.toolCall,
    },
    forbiddenActions: const {..._creationForbidden},
    outputSchema: const <String, Object?>{
      'type': 'object',
      'required': <String>['artifact'],
      'properties': <String, Object?>{
        'artifact': <String, Object?>{'type': 'string'},
        // The creator may volunteer a one-line rationale for the trail; the
        // loop cares only about `artifact`.
        'rationale': <String, Object?>{'type': 'string'},
      },
    },
    budgetDefaults: RoleBudgetDefaults.empty,
  );
}

// ----- `tester` -----
//
// § 4 (test-first) / § 6: authors the test or success check before the artifact
// exists, then runs it through the test tool. Same capability shape as the
// creator — drafts a file and exercises it — so it carries `memoryRead` +
// `toolCall`. It does not persist, speak to the user, or decompose.
RoleTemplate _tester() {
  return RoleTemplate(
    id: 'tester',
    personaText: 'I am the artifact tester. I turn the success criterion into '
        'an executable check — a test, an analyzer signal, or a schema '
        'validation — that fails before the artifact exists and passes once it '
        'is correct.',
    objective: 'Author the test / success check that encodes the criterion, '
        'within the file-scope sandbox, and run it through the test tool. '
        'Confirm it fails first (test-first) and reports a clear signal the '
        'loop can check the draft against. Emit the test — the loop drives it.',
    allowedActions: const {
      AllowedAction.llmCall,
      AllowedAction.memoryRead,
      AllowedAction.toolCall,
    },
    forbiddenActions: const {..._creationForbidden},
    outputSchema: const <String, Object?>{
      'type': 'object',
      'required': <String>['test'],
      'properties': <String, Object?>{
        'test': <String, Object?>{'type': 'string'},
        'rationale': <String, Object?>{'type': 'string'},
      },
    },
    budgetDefaults: RoleBudgetDefaults.empty,
  );
}

// ----- `reviewer` -----
//
// § 4 (critique) / § 6: the critic. A structured-verdict role like the
// thinking-loop `evaluator` and the `procedure_critic`, verdict alphabet
// `accept | revise`. It judges the draft against the criterion using the
// analyzer / test signals fed as inputs, reads memory to cite prior
// conclusions, but runs no tools of its own — so no `toolCall`. Never persists,
// never speaks to the user, never decomposes.
RoleTemplate _reviewer() {
  return RoleTemplate(
    id: 'reviewer',
    personaText: 'I am the artifact reviewer. I read a draft artifact and the '
        'success criterion it claims to meet, and judge whether it is fit to '
        'accept.',
    objective: 'Read the draft, the intent, and the test / analyzer signals. '
        'Decide between `accept` (the artifact meets the criterion and is sound) '
        'and `revise` (it is close but needs another pass). Name the specific '
        'weakness that drove a `revise`; do not invent faults the draft does '
        'not exhibit.',
    allowedActions: const {
      AllowedAction.llmCall,
      AllowedAction.memoryRead,
    },
    forbiddenActions: const {
      ..._creationForbidden,
      AllowedAction.toolCall,
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
