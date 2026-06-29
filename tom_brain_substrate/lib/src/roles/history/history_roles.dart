// The single conversation-history role (`tom_brain_procedure_specification.md`
// § 22.4, hub-spec history compaction).
//
// The engine-side `HistoryCompactor` folds a session's pending verbatim turns
// into a running summary so older turns can leave the verbatim window without
// losing load-bearing state (decisions, commitments, named entities, open
// threads). That fold is a single LLM judgement — and like every other LLM
// judgement it runs under a named, anchored role. `history_compactor` is that
// role: the dedicated first-class home for the compaction completion, replacing
// the earlier stopgap that borrowed the `recaller` role (HC-81).
//
// ── Capability shape: a pure text transformer ────────────────────────
//
// `history_compactor` mirrors the dreaming roster's shape exactly — it is a
// *pure text transformer*. `SubstrateHistoryCompaction` resolves the
// `compact_history_v1` scaffolds (the running summary + the new batch) into a
// single `prompt` input and hands it to the role inline; the role returns the
// rewritten summary as plain text, which the compactor persists. The role
// itself neither reads nor writes memory, calls no tool, speaks to no user, and
// spawns no sub-thinking — so it is `llmCall`-only and forbids everything else,
// exactly like the dreaming roles and the planning `estimator`. It declares no
// `outputSchema`: the compactor reads free summary text, not a structured object.
//
// ── Why a *separate* roster ──────────────────────────────────────────
//
// Same rationale as the retrieval / procedure / creation / planning / dream
// rosters: `bootstrapRoleRegistry()` is pinned at exactly six core roles. The
// history role is a distinct, optional roster — composing it onto the full live
// roster is the job of
// [bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningDreamAndHistory].
// The anchor is injected on every assembled prompt exactly as for every other
// role (`assemble()` wraps the body via `AssistantDedicationAnchor.wrap`).

import '../allowed_action.dart';
import '../dream/dream_roles.dart'
    show bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningAndDream;
import '../role_budget_defaults.dart';
import '../role_registry.dart';
import '../role_template.dart';

/// The conversation-history role ids — currently the single `history_compactor`.
///
/// Iteration order of [historyRoleTemplates] and [bootstrapHistoryRoleRegistry]
/// follows this list verbatim, so the trail / observability layer sees a stable
/// ordering.
const List<String> historyRoleIds = <String>[
  'history_compactor',
];

/// The actions the history role forbids. It speaks to no user (its output is
/// consumed by the host `HistoryCompactor`), reads or writes no memory (the
/// compactor owns the summary persistence), calls no tool, and spawns no
/// sub-thinking — it is a single `llmCall` text transform.
const Set<AllowedAction> _historyForbidden = <AllowedAction>{
  AllowedAction.userFacingAnswer,
  AllowedAction.memoryRead,
  AllowedAction.memoryWrite,
  AllowedAction.toolCall,
  AllowedAction.subThinking,
};

/// Builds the history `RoleTemplate` instances, in [historyRoleIds] order.
/// Pure factory — no IO, no global state.
List<RoleTemplate> historyRoleTemplates() => <RoleTemplate>[
      _historyCompactor(),
    ];

/// A [RoleRegistry] holding exactly the history roles.
///
/// Use this when only the history roster is needed (e.g. a compaction eval
/// harness). The full live roster is
/// [bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningDreamAndHistory].
RoleRegistry bootstrapHistoryRoleRegistry() =>
    RoleRegistry(templates: historyRoleTemplates());

/// The full live roster: the thirty-one roles of
/// [bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningAndDream] (core +
/// retrieval + procedure + creation + planning + dream) plus the history role
/// (thirty-two total), in that layer order.
///
/// This is the registry the run assembly composes: every role any system
/// procedure or the history compactor dispatches must be registered (the boot's
/// `open()` validates that each *routed* role is in the registry, and
/// `complete()` resolves it). It extends the dream roster with the
/// `history_compactor` role the engine-side `HistoryCompactor` dispatches; the
/// bootstrap roster is unchanged — `bootstrapRoleRegistry()` still returns
/// exactly the six core roles, so the b22 contract holds.
RoleRegistry
    bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningDreamAndHistory() {
  final withDream =
      bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningAndDream();
  return RoleRegistry(
    templates: <RoleTemplate>[
      ...withDream.templates,
      ...historyRoleTemplates(),
    ],
  );
}

// ----- `history_compactor` -----
//
// The engine-side `HistoryCompactor` (hub spec § 22.4) folds a session's
// pending verbatim turns into the running summary so older turns can leave the
// verbatim window. This role supplies the persona/objective wrapper around the
// `compact_history_v1` instruction scaffolds: faithfulness over brevity — the
// fold must preserve every decision, commitment, named entity, and open thread,
// and must never invent facts the turns do not support.
RoleTemplate _historyCompactor() {
  return RoleTemplate(
    id: 'history_compactor',
    personaText: 'I am the history compactor. I keep a long conversation usable '
        'by folding its older turns into a faithful running summary, so the '
        'assistant never loses what the user said even after the verbatim turns '
        'scroll out of the window.',
    objective: 'Fold the new turns into the current summary and return the '
        'rewritten summary only — no preamble, no commentary. Preserve every '
        'decision, commitment, named entity, instruction, and still-open '
        'question; drop pleasantries and superseded intermediate steps once '
        'their outcome is captured. Add nothing the turns do not state; when the '
        'turns contradict the current summary, prefer the newer turns and keep '
        'the summary internally consistent. Be as short as fidelity allows.',
    allowedActions: const {AllowedAction.llmCall},
    forbiddenActions: const {..._historyForbidden},
    budgetDefaults: RoleBudgetDefaults.empty,
  );
}
