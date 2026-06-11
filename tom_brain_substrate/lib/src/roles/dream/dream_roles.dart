// The seven dreaming-agent roles (`memory_specification.md` § 9, the eight
// dreaming cognitive agents).
//
// The dream procedures (`scripts/system/dream_*_v1.dart`) each run one
// dedicated role, one per agent, to do the single LLM judgement at the heart
// of the agent's pass:
//
//   | Role id                | Agent / dream procedure          | LLM judgement |
//   |------------------------|----------------------------------|---------------|
//   | `extractor`            | dream_extract_v1                 | distil an Event into an atomic Claim statement |
//   | `connector`            | dream_connect_v1                 | per-Claim: does a derived_from link to its Events hold? |
//   | `synthesiser`          | dream_synthesise_v1              | fold recalled Claims into one Conclusion |
//   | `inquisitor`           | dream_inquisitor_v1              | surface the open Question the Claims do not answer |
//   | `pruner`               | dream_prune_v1                   | per-Claim: is it redundant against the canonical one? |
//   | `reconsolidator`       | dream_reconsolidate_v1           | name the conflict between two Claims |
//   | `repetition_detector`  | dream_repetition_detect_v1       | name the recurring activity across recalled Events |
//
// (The eighth dreaming agent, the long-running `restructure_tree_*` migration,
// has no per-pass LLM role — it advances a structural migration, not a text
// judgement — so it is not in this roster.)
//
// All seven carry the assistant-dedication anchor — `assemble()` injects it
// exactly as for every other role, like the core / procedure / creation /
// planning rosters.
//
// ── Capability shape: pure text transformers ─────────────────────────
//
// Every dreaming role is a *pure text transformer*: the host dream procedure
// recalls from memory, hands the recalled statements to the role inline as the
// prompt, and the role returns plain text (a yes/no verdict or a synthesised
// phrase) which the procedure consumes as `completion['text']`. The role itself
// neither reads nor writes memory, calls no tool, speaks to no user, and spawns
// no sub-thinking — the procedure does every persist / demote / edge / stack
// push under the agent's scoped memory identity (the store's `AgentRegistry`
// confines those writes, not the role's allow-list). So each role is
// `llmCall`-only, mirroring the planning `estimator`, and forbids everything
// else. None declares an `outputSchema`: the procedures read free text, not a
// structured verdict object.
//
// ── Why a *separate* roster ──────────────────────────────────────────
//
// Same rationale as the retrieval / procedure / creation / planning rosters:
// `bootstrapRoleRegistry()` is pinned at exactly six core roles. The seven
// dreaming roles are a distinct, optional roster — a deployment that never
// dreams (the `dream:` config is off by default) need not register them.
// Composing them onto the full live roster is the job of
// [bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningAndDream].

import '../allowed_action.dart';
import '../planning/planning_roles.dart'
    show bootstrapRoleRegistryWithRetrievalProcedureCreationAndPlanning;
import '../role_budget_defaults.dart';
import '../role_registry.dart';
import '../role_template.dart';

/// The seven dreaming-agent role ids, in canonical pipeline order
/// (`memory_specification.md` § 9): extract → connect → synthesise →
/// inquire, then the maintenance agents prune → reconsolidate →
/// detect-repetition.
///
/// Iteration order of [dreamRoleTemplates] and [bootstrapDreamRoleRegistry]
/// follows this list verbatim, so the trail / observability layer sees a
/// stable ordering.
const List<String> dreamRoleIds = <String>[
  'extractor',
  'connector',
  'synthesiser',
  'inquisitor',
  'pruner',
  'reconsolidator',
  'repetition_detector',
];

/// The actions every dreaming role forbids. None speaks to the user (its
/// output is consumed by the host procedure), reads or writes memory (the
/// procedure recalls inline and persists under the agent's scoped identity),
/// calls a tool, or spawns sub-thinking — each is a single `llmCall` text
/// transform.
const Set<AllowedAction> _dreamForbidden = <AllowedAction>{
  AllowedAction.userFacingAnswer,
  AllowedAction.memoryRead,
  AllowedAction.memoryWrite,
  AllowedAction.toolCall,
  AllowedAction.subThinking,
};

/// Builds the seven dreaming `RoleTemplate` instances, in [dreamRoleIds]
/// order. Pure factory — no IO, no global state.
List<RoleTemplate> dreamRoleTemplates() => <RoleTemplate>[
      _extractor(),
      _connector(),
      _synthesiser(),
      _inquisitor(),
      _pruner(),
      _reconsolidator(),
      _repetitionDetector(),
    ];

/// A [RoleRegistry] holding exactly the seven dreaming roles.
///
/// Use this when only the dreaming roster is needed (e.g. a dream-agent eval
/// harness). The full live roster is
/// [bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningAndDream].
RoleRegistry bootstrapDreamRoleRegistry() =>
    RoleRegistry(templates: dreamRoleTemplates());

/// The full live roster: the twenty-three roles of
/// [bootstrapRoleRegistryWithRetrievalProcedureCreationAndPlanning] (core +
/// retrieval + procedure + creation + planning) plus the seven dreaming roles
/// (thirty total), in that layer order.
///
/// This is the registry the run assembly composes once dreaming is enabled —
/// every role any system procedure dispatches must be registered (the boot's
/// `open()` validates that each *routed* role is in the registry, and
/// `complete()` resolves it). It extends the planning roster with the
/// `extractor` / `connector` / `synthesiser` / `inquisitor` / `pruner` /
/// `reconsolidator` / `repetition_detector` roles the `dream_*_v1` procedures
/// dispatch; the bootstrap roster is unchanged — `bootstrapRoleRegistry()`
/// still returns exactly the six core roles, so the b22 contract holds.
RoleRegistry
    bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningAndDream() {
  final withPlanning =
      bootstrapRoleRegistryWithRetrievalProcedureCreationAndPlanning();
  return RoleRegistry(
    templates: <RoleTemplate>[
      ...withPlanning.templates,
      ...dreamRoleTemplates(),
    ],
  );
}

// ----- `extractor` -----
//
// dream_extract_v1: distils each recalled episodic Event into an atomic
// factual Claim — the move from raw experience to a reusable assertion. Reads
// the event text inline from the prompt; emits the claim statement as plain
// text (the procedure embeds and persists it as a `Claim` node).
RoleTemplate _extractor() {
  return RoleTemplate(
    id: 'extractor',
    personaText: 'I am the extractor. I read a single thing that happened and '
        'distil it into one durable, reusable fact — for the user I exist to '
        'help.',
    objective: 'Read the given event and write the single atomic claim it '
        'establishes: one self-contained factual statement, present tense, no '
        'narrative framing and no speculation beyond what the event states. '
        'Emit the statement only — the surrounding agent embeds and records it.',
    allowedActions: const {AllowedAction.llmCall},
    forbiddenActions: const {..._dreamForbidden},
    budgetDefaults: RoleBudgetDefaults.empty,
  );
}

// ----- `connector` -----
//
// dream_connect_v1: judges, per recalled Claim, whether a `derived_from` link
// back to the episodic Events recalled alongside it holds. Emits a yes/no
// verdict as plain text (the procedure draws the edge only on an affirmative).
RoleTemplate _connector() {
  return RoleTemplate(
    id: 'connector',
    personaText: 'I am the connector. I decide whether a recorded fact truly '
        'follows from the experiences it sits beside, so the knowledge graph '
        'links only what is genuinely connected.',
    objective: 'Given a claim and the events it is recalled beside, decide '
        'whether the claim is genuinely derived from those events. Answer with '
        'a clear yes or no — yes only when the events actually support the '
        'claim. Do not link by mere topical proximity.',
    allowedActions: const {AllowedAction.llmCall},
    forbiddenActions: const {..._dreamForbidden},
    budgetDefaults: RoleBudgetDefaults.empty,
  );
}

// ----- `synthesiser` -----
//
// dream_synthesise_v1: folds the Claims recalled around a topic into a single
// Conclusion — the move from many assertions to one position. Emits the
// conclusion statement as plain text (the procedure embeds it and ties it back
// to the source Claims with `derived_from` edges).
RoleTemplate _synthesiser() {
  return RoleTemplate(
    id: 'synthesiser',
    personaText: 'I am the synthesiser. I read a set of recorded facts about '
        'one topic and fold them into a single coherent conclusion — for the '
        'user I exist to help.',
    objective: 'Read the given claims and write one conclusion that they '
        'jointly support: a single position that captures what the claims add '
        'up to, without contradicting any of them and without introducing a '
        'fact none of them states. Emit the conclusion statement only — the '
        'agent records it and ties it to its evidence.',
    allowedActions: const {AllowedAction.llmCall},
    forbiddenActions: const {..._dreamForbidden},
    budgetDefaults: RoleBudgetDefaults.empty,
  );
}

// ----- `inquisitor` -----
//
// dream_inquisitor_v1: reads the recalled Claims and surfaces the open
// question the body of knowledge does not yet answer. Emits the question as
// plain text (the procedure persists it as a `Question` node and pushes it onto
// the `questions_open` stack).
RoleTemplate _inquisitor() {
  return RoleTemplate(
    id: 'inquisitor',
    personaText: 'I am the inquisitor. I read what is known and notice what is '
        'missing — the question the knowledge does not yet answer — so the '
        'brain can go and find out, in service of the user I exist to help.',
    objective: 'Read the given claims and write the single most useful open '
        'question they leave unanswered: a concrete, answerable question whose '
        'answer would extend the knowledge, not a rhetorical or unanswerable '
        'one. Emit the question only — the agent records it and queues it.',
    allowedActions: const {AllowedAction.llmCall},
    forbiddenActions: const {..._dreamForbidden},
    budgetDefaults: RoleBudgetDefaults.empty,
  );
}

// ----- `pruner` -----
//
// dream_prune_v1: judges, per recalled Claim, whether it is redundant against
// the first (canonical) Claim. Emits a yes/no verdict as plain text (the
// procedure demotes — never deletes — a Claim judged redundant).
RoleTemplate _pruner() {
  return RoleTemplate(
    id: 'pruner',
    personaText: 'I am the pruner. I keep memory from drowning in duplicates '
        'by deciding whether a fact merely repeats one already kept.',
    objective: 'Given a canonical claim and a candidate claim, decide whether '
        'the candidate is redundant against the canonical one — i.e. it adds no '
        'information the canonical claim does not already carry. Answer with a '
        'clear yes or no. Say yes only for genuine redundancy, not for a claim '
        'that refines, qualifies, or extends the canonical one.',
    allowedActions: const {AllowedAction.llmCall},
    forbiddenActions: const {..._dreamForbidden},
    budgetDefaults: RoleBudgetDefaults.empty,
  );
}

// ----- `reconsolidator` -----
//
// dream_reconsolidate_v1: reads two conflicting Claims and names the conflict
// between them. Emits the conflict summary as plain text (the procedure records
// it as a `Contradiction` node tied to the Claims and demotes the superseded
// one).
RoleTemplate _reconsolidator() {
  return RoleTemplate(
    id: 'reconsolidator',
    personaText: 'I am the reconsolidator. When two recorded facts cannot both '
        'be true, I name the conflict precisely so memory can be made coherent '
        'again — for the user I exist to help.',
    objective: 'Read the given claims and write a single short summary of the '
        'conflict between them: what they disagree on and why both cannot hold. '
        'Name the contradiction precisely; do not invent a conflict where the '
        'claims are merely different. Emit the summary only — the agent records '
        'the contradiction and demotes the superseded claim.',
    allowedActions: const {AllowedAction.llmCall},
    forbiddenActions: const {..._dreamForbidden},
    budgetDefaults: RoleBudgetDefaults.empty,
  );
}

// ----- `repetition_detector` -----
//
// dream_repetition_detect_v1: reads the recalled Events and names the recurring
// activity across them. Emits the description as plain text (the procedure
// records it as a `Pattern` node and turns it into an `AutomationIdea` queued
// on the `automation_ideas` stack).
RoleTemplate _repetitionDetector() {
  return RoleTemplate(
    id: 'repetition_detector',
    personaText: 'I am the repetition detector. I watch what keeps happening '
        'and name the pattern, so the brain can notice "this repeats — maybe it '
        'should be automated" on behalf of the user I exist to help.',
    objective: 'Read the given events and name the single recurring activity '
        'they share: a concise description of what repeats across them. Identify '
        'a real recurrence — do not manufacture a pattern from unrelated '
        'events. Emit the description only — the agent records the pattern and '
        'queues an automation idea.',
    allowedActions: const {AllowedAction.llmCall},
    forbiddenActions: const {..._dreamForbidden},
    budgetDefaults: RoleBudgetDefaults.empty,
  );
}
