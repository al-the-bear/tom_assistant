// Todo 8 (G-P3) — the five planning-subsystem roles
// (`planning_specification.md` § 8).
//
// The planning loop (the `plan_v1` procedure) runs five dedicated roles, one
// per loop stage (spec § 4.1, § 8):
//
//   | Role id          | Stage / purpose                                      |
//   |------------------|------------------------------------------------------|
//   | `planner`        | A — goal classification + top-level plan framing.    |
//   | `decomposer`     | B — step decomposition; the workhorse stage.         |
//   | `estimator`      | C — ordering / critical-path (cost roll-up deferred).|
//   | `plan_evaluator` | D — the critic (`accept | revise`).                  |
//   | `re_planner`     | Re-planning on a shaking event; minimal disruption.  |
//
// Spec naming note: § 8 writes the fifth role `re-planner`. The codebase keys
// roles by snake_case identifiers (`plan_evaluator`, `procedure_author`, …), so
// the registered id is `re_planner`. The mapping is one-to-one and documented
// here so the spec and the registry never drift.
//
// All five carry the assistant-dedication anchor (§ 8 last line) — `assemble()`
// injects it exactly as for every other role, like the procedure and creation
// rosters.
//
// Why a *separate* group from `bootstrapRoleRegistry()` — the same rationale as
// the retrieval / procedure / creation rosters: `bootstrapRoleRegistry()` is
// pinned at exactly six core roles by `b22_role_registry_test.dart`. The five
// planning roles are a distinct, optional roster — a deployment that never runs
// the planning loop need not register them. Composing them onto the full live
// roster is the job of
// [bootstrapRoleRegistryWithRetrievalProcedureCreationAndPlanning].
//
// Capability surface (§ 8, cross-checked against the loop's stages):
//
//   * `planner` — classifies the goal and frames the plan. Reads memory
//     (`memoryRead`) to ground the framing in related prior plans/conclusions.
//     Does not persist (the host `plan_v1` procedure does), is not the
//     user-facing voice, and does not spawn sub-questions.
//   * `decomposer` — turns the framed goal into a step set. Same capability
//     shape as `planner` (`llmCall` + `memoryRead`); emits the steps, does not
//     persist / speak to the user / decompose into sub-questions.
//   * `estimator` — orders the decomposed steps and names their dependencies.
//     The canonical topological order is re-derived natively on read
//     (`tom_core_agentic.orderPlanSteps`); this role supplies the dependency
//     structure and execution-order hint the loop persists. The step set is fed
//     as inputs, so the role is `llmCall`-only — no `memoryRead`.
//   * `plan_evaluator` — the critic. A structured-verdict role like the
//     thinking-loop `evaluator` and the `procedure_critic`, verdict alphabet
//     `accept | revise`. Reads memory to cite prior conclusions; never
//     persists, never speaks to the user, never decomposes.
//   * `re_planner` — surgically rewrites a sub-graph when an intermediate
//     observation invalidates part of an active plan (§ 4.7). Reads the
//     existing plan and the triggering observation (`memoryRead`); biased
//     toward minimal disruption. Emits the replacement steps; the host marks
//     the superseded ones (`superseded_by`, never destructive).

import '../allowed_action.dart';
import '../creation/creation_roles.dart'
    show bootstrapRoleRegistryWithRetrievalProcedureAndCreation;
import '../role_budget_defaults.dart';
import '../role_registry.dart';
import '../role_template.dart';

/// The five planning-subsystem role ids, in canonical loop order
/// (`planning_specification.md` § 8, top-to-bottom of the role table).
///
/// Iteration order of [planningRoleTemplates] and
/// [bootstrapPlanningRoleRegistry] follows this list verbatim, so the trail /
/// observability layer sees a stable ordering.
const List<String> planningRoleIds = <String>[
  'planner',
  'decomposer',
  'estimator',
  'plan_evaluator',
  're_planner',
];

/// The actions every planning role forbids. None of the five speaks to the
/// user (their output is internal), persists (the host `plan_v1` procedure
/// does), or spawns sub-questions (decomposition into *steps* is the loop's
/// job, not recursive sub-thinking).
const Set<AllowedAction> _planningForbidden = <AllowedAction>{
  AllowedAction.userFacingAnswer,
  AllowedAction.memoryWrite,
  AllowedAction.subThinking,
};

/// Builds the five planning `RoleTemplate` instances, in [planningRoleIds]
/// order. Pure factory — no IO, no global state.
List<RoleTemplate> planningRoleTemplates() => <RoleTemplate>[
      _planner(),
      _decomposer(),
      _estimator(),
      _planEvaluator(),
      _rePlanner(),
    ];

/// A [RoleRegistry] holding exactly the five planning roles.
///
/// Use this when only the planning roster is needed (e.g. a planning-loop eval
/// harness). The full live roster is
/// [bootstrapRoleRegistryWithRetrievalProcedureCreationAndPlanning].
RoleRegistry bootstrapPlanningRoleRegistry() =>
    RoleRegistry(templates: planningRoleTemplates());

/// The full live roster: the six core roles, the six Extension-H retrieval
/// roles, the three procedure roles, the three creation roles, and the five
/// planning roles (twenty-three total), in that layer order.
///
/// This is the registry the run assembly composes once the planning loop is
/// enabled — every role any system procedure dispatches must be registered (the
/// boot's `open()` validates that each *routed* role is in the registry, and
/// `complete()` resolves it). It extends
/// [bootstrapRoleRegistryWithRetrievalProcedureAndCreation] (the Todo-9 roster)
/// with the `planner` / `decomposer` / `estimator` / `plan_evaluator` /
/// `re_planner` roles `plan_v1` dispatches; the bootstrap roster is unchanged —
/// `bootstrapRoleRegistry()` still returns exactly the six core roles, so the
/// b22 contract holds.
RoleRegistry bootstrapRoleRegistryWithRetrievalProcedureCreationAndPlanning() {
  final withCreation = bootstrapRoleRegistryWithRetrievalProcedureAndCreation();
  return RoleRegistry(
    templates: <RoleTemplate>[
      ...withCreation.templates,
      ...planningRoleTemplates(),
    ],
  );
}

// ----- `planner` -----
//
// § 4.2 / § 8: classifies the goal into a `PlanKind` and frames the plan.
// Reads memory to ground the framing in related prior plans / conclusions
// (`memoryRead`); emits the classification and a one-line framing. Does not
// persist, speak to the user, or decompose.
RoleTemplate _planner() {
  return RoleTemplate(
    id: 'planner',
    personaText: 'I am the planner. I read an incoming goal and frame how to '
        'pursue it — what kind of goal it is and what the plan is broadly for — '
        'in service of the user I exist to help.',
    objective: 'Classify the goal into exactly one kind — `creation` (produce '
        'an artifact), `research` (find something out), `decision` (choose '
        'between options), or `composite` (a goal that needs several of these) '
        '— and write a one-line framing of what the plan must achieve. Ground '
        'the framing in related prior plans where memory offers them. Emit the '
        'classification only; the surrounding loop decomposes, orders, '
        'critiques, and records the plan.',
    allowedActions: const {
      AllowedAction.llmCall,
      AllowedAction.memoryRead,
    },
    forbiddenActions: const {..._planningForbidden},
    outputSchema: const <String, Object?>{
      'type': 'object',
      'required': <String>['planKind'],
      'properties': <String, Object?>{
        'planKind': <String, Object?>{
          'type': 'string',
          'enum': <String>['creation', 'research', 'decision', 'composite'],
        },
        'summary': <String, Object?>{'type': 'string'},
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

// ----- `decomposer` -----
//
// § 4.3 / § 8: the workhorse stage — turns the framed goal into a step set.
// Reads memory for context (`memoryRead`). Emits the steps in a newline format
// the sandboxed `plan_v1` body can parse without a JSON decoder (the procedure
// sandbox allow-list excludes `dart:convert`), so the output contract is a
// `steps` string, one step per line, with an inline dependency marker.
RoleTemplate _decomposer() {
  return RoleTemplate(
    id: 'decomposer',
    personaText: 'I am the decomposer. I break a framed goal into the concrete '
        'steps that, done in order, achieve it — for the user I exist to help.',
    objective: 'Produce the smallest set of steps that fully covers the goal. '
        'Write one step per line as a short imperative phrase. When a step '
        'depends on earlier ones, append " <- " and the comma-separated '
        '1-based line numbers of those steps. Every step must be necessary and '
        'the set must be sufficient; do not leave a gap and do not pad. Emit '
        'the step lines only — the loop orders, critiques, and records them.',
    allowedActions: const {
      AllowedAction.llmCall,
      AllowedAction.memoryRead,
    },
    forbiddenActions: const {..._planningForbidden},
    outputSchema: const <String, Object?>{
      'type': 'object',
      'required': <String>['steps'],
      'properties': <String, Object?>{
        'steps': <String, Object?>{
          'type': 'string',
          'description': 'One step per line; optional " <- n,m" dependency '
              'marker referencing earlier line numbers.',
        },
      },
    },
    budgetDefaults: RoleBudgetDefaults.empty,
  );
}

// ----- `estimator` -----
//
// § 4.4 / § 8: orders the decomposed steps and names their dependencies. The
// canonical topological order is re-derived natively on read
// (`tom_core_agentic.orderPlanSteps`); this role supplies the execution-order
// hint and any dependency edges the decomposer missed. The step set is fed as
// inputs, so the role is `llmCall`-only — no `memoryRead`. (Cost roll-up /
// critical-path scoring is deferred — see
// `deferred.tom_brain.md`, `rollUpStepCost` — so the estimator's
// numeric-cost remit is not yet wired.)
RoleTemplate _estimator() {
  return RoleTemplate(
    id: 'estimator',
    personaText: 'I am the estimator. Given a set of steps I settle the order '
        'they must run in and which of them depend on which.',
    objective: 'Read the decomposed steps and produce their execution order as '
        'the comma-separated 1-based line numbers, dependencies first. Add any '
        'dependency the decomposition missed and flag a cycle if the steps '
        'cannot be ordered. Do not invent new steps or drop existing ones — '
        'order only what you are given.',
    allowedActions: const {AllowedAction.llmCall},
    forbiddenActions: const {
      ..._planningForbidden,
      AllowedAction.memoryRead,
      AllowedAction.toolCall,
    },
    outputSchema: const <String, Object?>{
      'type': 'object',
      'required': <String>['order'],
      'properties': <String, Object?>{
        'order': <String, Object?>{
          'type': 'string',
          'description': 'Comma-separated 1-based step line numbers in '
              'execution order (dependencies first).',
        },
        'rationale': <String, Object?>{'type': 'string'},
      },
    },
    budgetDefaults: RoleBudgetDefaults.empty,
  );
}

// ----- `plan_evaluator` -----
//
// § 4.5 / § 8: the critic. A structured-verdict role like the thinking-loop
// `evaluator` and the `procedure_critic`, verdict alphabet `accept | revise`.
// Reads memory to cite prior conclusions; never persists, never speaks to the
// user, never decomposes.
RoleTemplate _planEvaluator() {
  return RoleTemplate(
    id: 'plan_evaluator',
    personaText: 'I am the plan evaluator. I read a drafted plan — its goal, '
        'its ordered steps, and their dependencies — and judge whether it '
        'covers the goal well enough to commit.',
    objective: 'Decide between `accept` (the plan fully and soundly covers the '
        'goal) and `revise` (it has a gap, a redundant step, or a wrong '
        'dependency). Name the specific weakness that drove a `revise` so the '
        'loop can re-enter with it; do not invent faults the plan does not '
        'exhibit.',
    allowedActions: const {
      AllowedAction.llmCall,
      AllowedAction.memoryRead,
    },
    forbiddenActions: const {
      ..._planningForbidden,
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

// ----- `re_planner` -----
//
// § 4.7 / § 8: surgical re-planning on a shaking event. When an intermediate
// observation invalidates part of an active plan, this role rewrites just the
// affected sub-graph — biased toward minimal disruption. Reads the existing
// plan and the triggering observation (`memoryRead`); emits replacement steps
// (same newline contract as the decomposer) and names which existing steps the
// host should mark superseded. Never persists / speaks to the user / decomposes.
RoleTemplate _rePlanner() {
  return RoleTemplate(
    id: 're_planner',
    personaText: 'I am the re-planner. When something observed mid-plan breaks '
        'part of an active plan, I rewrite only the part that broke — changing '
        'as little as possible — for the user I exist to help.',
    objective: 'Read the active plan and the observation that invalidated part '
        'of it. Produce the replacement steps (one per line, with the same '
        '" <- n,m" dependency markers as decomposition) and name the existing '
        'step ids the change supersedes. Preserve every step the observation '
        'did not touch; minimise disruption. Emit the replacement only — the '
        'host marks the superseded steps and records the revision.',
    allowedActions: const {
      AllowedAction.llmCall,
      AllowedAction.memoryRead,
    },
    forbiddenActions: const {..._planningForbidden},
    outputSchema: const <String, Object?>{
      'type': 'object',
      'required': <String>['steps'],
      'properties': <String, Object?>{
        'steps': <String, Object?>{
          'type': 'string',
          'description': 'Replacement steps, one per line, with optional '
              '" <- n,m" dependency markers.',
        },
        'supersedes': <String, Object?>{
          'type': 'string',
          'description': 'Comma-separated ids of the existing steps this '
              'revision supersedes.',
        },
      },
    },
    budgetDefaults: RoleBudgetDefaults.empty,
  );
}
