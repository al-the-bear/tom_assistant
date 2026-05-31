// B.22 — bootstrap of the five prototype roles.
//
// Plan-step text (verbatim):
//   "B.22 Implement template registry with at least these roles for the
//    prototype: `assistant_to_user`, `analyser`, `sub_thinker`,
//    `recaller`, `evaluator`."
//
// `substrate_specification.md` § 6.2 names the five prototype roles and
// the procedures / loop stages each one is used by:
//
//   | Role               | Used by                                                                  |
//   |--------------------|---------------------------------------------------------------------------|
//   | `assistant_to_user`| The final answer in `answer_with_memory_v1`. The only role the user sees. |
//   | `analyser`         | The thinking loop's analyse stage (later phases).                         |
//   | `sub_thinker`      | Sub-question dispatch.                                                    |
//   | `recaller`         | Re-ranking and answer composition over memory recall.                     |
//   | `evaluator`        | The self-critique stage.                                                  |
//
// Why bootstrap *in code* (not loaded from disk) at B.22:
//
//   * Spec § 6.1 names `<workspace>/_ai/prompts/<role>.system.md` as
//     the eventual on-disk source plus a `roles_registry.yaml`
//     metadata file. Both paths require a yaml-loader + filesystem
//     IO + git-sha resolution layer that is not in scope at B.22 (the
//     SubstrateConfig YAML loader is the dedicated B.36 step).
//
//   * The plan text for B.22 names *only* the five role ids; it does
//     not require file loading. The minimum that satisfies "template
//     registry with at least these roles" is a registry whose roster
//     materialises the five `RoleTemplate` instances, regardless of
//     where the persona / objective text comes from.
//
//   * Bootstrap-in-code keeps B.22 testable without a fixture-tree on
//     disk. The tests pin the registry's structural contract
//     (`length == 5`, all five ids present, allowed-action shapes
//     respect spec § 6.2) without an `_ai/prompts/` directory.
//
//   * The file-backed loader at B.36 will produce `RoleTemplate`
//     instances through the same `RoleTemplate` factory; the registry
//     accepts the list, the persona / objective / allowedActions
//     contracts are the same shape. The bootstrap path will then be
//     either retired or kept as a fallback for in-process tests
//     (Q-B.22.1 and Q-B.22.2 record the deferred decision).
//
// What this file deliberately does NOT own:
//
//   * The `templateRef` / git sha. Templates assembled in code have
//     no git sha to point at; the field is omitted from the bootstrap
//     instances. When the B.36 loader replaces this path, every
//     produced template gets a sha; downstream consumers
//     (`LlmCallReport.templateSha`) tolerate the null today and will
//     pick up the value when the loader lands.
//
//   * The persona / objective *prose* polish. The bootstrap strings
//     are short, role-bound, and structurally correct for what B.23's
//     assemble path needs (non-empty after trim; written first-person
//     present-tense per the anchor's identity-framing pattern). They
//     are not the final user-facing copy — that lands when the on-
//     disk `_ai/prompts/<role>.system.md` files are authored at B.36
//     (or by an authoring procedure once the procedure runtime is up).
//
//   * The dispatcher-side gate. The `allowedActions` set per role
//     declares *what is allowed*; the dispatcher (Phase D) enforces.
//     The roles below name only the actions each role legitimately
//     needs for the prototype path; expanding an action set later is
//     a deliberate role-config change, not a runtime grant.

import 'allowed_action.dart';
import 'role_budget_defaults.dart';
import 'role_registry.dart';
import 'role_template.dart';

/// The five prototype role ids, in canonical insertion order.
///
/// Iteration order of `RoleRegistry.ids` follows this list verbatim
/// when the registry is constructed via [bootstrapRoleRegistry] — used
/// by tests that assert "registry has exactly these five ids, in this
/// order" so the trail / observability layer can rely on a stable
/// iteration ordering for diagnostic dumps.
const List<String> prototypeRoleIds = <String>[
  'assistant_to_user',
  'analyser',
  'sub_thinker',
  'recaller',
  'evaluator',
];

/// Constructs the five prototype `RoleTemplate` instances and returns
/// a `RoleRegistry` populated with them, in the order declared by
/// [prototypeRoleIds].
///
/// Pure factory — no IO, no global state, no caching. Each call
/// produces a fresh registry; the registry itself is immutable so
/// holding the returned value across calls is fine, but callers that
/// want process-wide singleton semantics must arrange that themselves
/// (the substrate's `TomBrainSubstrate` facade — B.40 / spec § 3 —
/// will own that singleton; bootstrap here intentionally does not).
///
/// Why a function and not a `static const` on `RoleRegistry`:
///
///   * The `RoleTemplate` factory does validation at construction
///     (non-empty fields, allow/forbid overlap, etc.); the validation
///     can throw, and a `static const` cannot run a body. A `final`
///     initialised with a non-const expression would work but would
///     hide the construction cost on first reference, defeating the
///     "construct fresh on demand" property the tests rely on.
///
///   * Two test files that each construct a registry and tamper with
///     it (e.g. wrapping it in a test-double) want independent
///     instances; a singleton would leak mutation-across-tests when a
///     mutable wrapper is added later.
RoleRegistry bootstrapRoleRegistry() {
  return RoleRegistry(
    templates: <RoleTemplate>[
      _assistantToUser(),
      _analyser(),
      _subThinker(),
      _recaller(),
      _evaluator(),
    ],
  );
}

// ----- `assistant_to_user` -----
//
// Spec § 6.2: "The final answer in `answer_with_memory_v1`. The only
// role the user directly sees." This is the user-facing voice; it is
// the ONE role that carries `user_facing_answer` in its allowed set
// (every other prototype role forbids it — see each role's
// `forbiddenActions` declaration). It does not carry `sub_thinking`
// — the user-facing answer is the terminal step of the thinking loop,
// not a step that spawns sub-questions. Memory read is allowed (the
// answer is composed over memory). Memory write is *not* — the answer
// path does not persist; the procedure that surrounds it persists.
RoleTemplate _assistantToUser() {
  return RoleTemplate(
    id: 'assistant_to_user',
    personaText: 'I am the assistant. I speak directly to the user I '
        'exist to help. My voice is the user-facing voice of Tom Brain.',
    objective: 'Compose the final answer to the user, drawing on the '
        'thinking trail, the recalled memory context, and the user\'s '
        'most recent prompt. Speak in the user\'s register; do not '
        'narrate internal process unless the user explicitly asked for '
        'it; do not invent facts beyond what the trail and memory '
        'support.',
    allowedActions: const {
      AllowedAction.llmCall,
      AllowedAction.userFacingAnswer,
      AllowedAction.memoryRead,
    },
    forbiddenActions: const {
      // This role is defined by not writing to memory — the surrounding
      // procedure is responsible for persisting the exchange.
      AllowedAction.memoryWrite,
      // The user-facing answer is terminal; it does not spawn further
      // sub-questions itself (the analyser / sub_thinker chain did
      // that already, upstream).
      AllowedAction.subThinking,
    },
    budgetDefaults: RoleBudgetDefaults.empty,
  );
}

// ----- `analyser` -----
//
// Spec § 6.2: "The thinking loop's analyse stage (later phases)."
// Decomposes the incoming question, identifies sub-questions worth
// delegating, and produces the structured plan the loop iterates on.
// Carries `sub_thinking` (this is the role that asks for sub-thinker
// runs) and `memory_read` (decomposition looks at related prior
// thoughts). Forbids `user_facing_answer` — the analyser's output is
// internal, consumed by the next loop stage, never shown to the user
// verbatim.
RoleTemplate _analyser() {
  return RoleTemplate(
    id: 'analyser',
    personaText: 'I am the analyser. I read the user\'s question, '
        'identify what it really asks, and break it into sub-questions '
        'the thinking loop can dispatch independently.',
    objective: 'Decompose the prompt into a small set of well-formed '
        'sub-questions plus a short rationale for the decomposition. '
        'Surface any ambiguity that should be resolved before the loop '
        'spends tokens on it. Do not answer the user; the analyser\'s '
        'output is consumed by the next loop stage.',
    allowedActions: const {
      AllowedAction.llmCall,
      AllowedAction.subThinking,
      AllowedAction.memoryRead,
    },
    forbiddenActions: const {
      AllowedAction.userFacingAnswer,
      AllowedAction.memoryWrite,
    },
    budgetDefaults: RoleBudgetDefaults.empty,
  );
}

// ----- `sub_thinker` -----
//
// Spec § 6.2: "Sub-question dispatch." Each sub-question identified by
// the analyser dispatches under this role. Carries `sub_thinking`
// because sub-thinking is recursive (a sub-question may itself decompose
// into further sub-questions; recursion depth and budget are enforced by
// the procedure runtime, not the role layer). Carries `memory_read` for
// the same reason as analyser. Forbids `user_facing_answer` — sub-
// thinker output is consumed by the synthesis stage, never shown
// verbatim.
RoleTemplate _subThinker() {
  return RoleTemplate(
    id: 'sub_thinker',
    personaText: 'I am the sub-thinker. I take one sub-question handed '
        'to me by the analyser (or by a recursive sub-thinker run) and '
        'produce a focused answer for that sub-question alone.',
    objective: 'Answer the single sub-question presented, using memory '
        'recall and recursive sub-thinking as needed. Stay scoped to the '
        'sub-question; do not address the user\'s overall prompt. The '
        'output is consumed by the synthesis stage; brevity and '
        'specificity are higher value than narrative completeness.',
    allowedActions: const {
      AllowedAction.llmCall,
      AllowedAction.subThinking,
      AllowedAction.memoryRead,
    },
    forbiddenActions: const {
      AllowedAction.userFacingAnswer,
      AllowedAction.memoryWrite,
    },
    budgetDefaults: RoleBudgetDefaults.empty,
  );
}

// ----- `recaller` -----
//
// Spec § 6.2: "Re-ranking and answer composition over memory recall."
// The role that sits between raw retrieval (four-mode retrieval in the
// memory layer, RRF + MMR fused) and the assistant_to_user prompt
// assembly — it re-ranks recalled items by relevance to the current
// thinking trail and composes a recall summary the answer stage
// consumes. Carries `tool_call` because the recaller may invoke
// retrieval-side tools (MCP `memory.recall_*` calls) over and above
// the raw recall its host procedure already ran. Forbids
// `user_facing_answer` and `memory_write` — it summarises and ranks,
// it does not write back.
RoleTemplate _recaller() {
  return RoleTemplate(
    id: 'recaller',
    personaText: 'I am the recaller. I read a batch of memory-recall '
        'results and shape them into the recall context the assistant '
        'voice will speak from.',
    objective: 'Re-rank the recalled items by relevance to the current '
        'thinking trail, drop low-signal items, and compose a concise '
        'recall summary the answer stage can quote from. Do not add '
        'facts beyond what the recalled items support; preserve every '
        'citation back to the source node so the trail layer can '
        'attribute the answer.',
    allowedActions: const {
      AllowedAction.llmCall,
      AllowedAction.memoryRead,
      AllowedAction.toolCall,
    },
    forbiddenActions: const {
      AllowedAction.userFacingAnswer,
      AllowedAction.memoryWrite,
    },
    budgetDefaults: RoleBudgetDefaults.empty,
  );
}

// ----- `evaluator` -----
//
// Spec § 6.2: "The self-critique stage." Reads a proposed answer
// (typically the assistant_to_user draft or a sub_thinker output) and
// emits a verdict (`accept | revise | escalate`) plus a critique. The
// only role with a non-null `outputSchema` in the bootstrap roster —
// the verdict surface is structured. Carries `memory_read` because
// the critique can cite relevant prior conclusions. Forbids
// `user_facing_answer` — the verdict is consumed by the loop's
// re-enter step, not shown to the user.
RoleTemplate _evaluator() {
  return RoleTemplate(
    id: 'evaluator',
    personaText: 'I am the evaluator. I read proposed answers and '
        'critique them against the criteria the procedure declares.',
    objective: 'Read the proposed answer and the success criterion. '
        'Decide between `accept` (the answer satisfies the criterion), '
        '`revise` (the answer is close but needs another pass), or '
        '`escalate` (the answer is not on the right track and the '
        'procedure should re-plan). Cite the part of the proposed '
        'answer that drove the decision; do not invent failure modes '
        'the answer does not exhibit.',
    allowedActions: const {
      AllowedAction.llmCall,
      AllowedAction.memoryRead,
    },
    forbiddenActions: const {
      AllowedAction.userFacingAnswer,
      AllowedAction.memoryWrite,
      AllowedAction.subThinking,
    },
    outputSchema: const <String, Object?>{
      'type': 'object',
      'required': <String>['verdict'],
      'properties': <String, Object?>{
        'verdict': <String, Object?>{
          'type': 'string',
          'enum': <String>['accept', 'revise', 'escalate'],
        },
        'critique': <String, Object?>{
          'type': 'string',
        },
        'cited_span': <String, Object?>{
          'type': 'string',
        },
      },
    },
    budgetDefaults: RoleBudgetDefaults.empty,
  );
}
