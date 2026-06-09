// Plan Extension-H step #29 — the six retrieval roles (substrate § 6.2a).
//
// Extension H (hub spec § 23) adds the LLM-bearing half of the
// memory-retrieval system. Per spec § 6.2a these are *roles, not new
// code* — each a template + registry entry, anchor-carrying like every
// other role (§ 6.3), routed by the same router. They are the only place
// an LLM touches retrieval; memory and its MCP server stay LLM-free
// (Q-H.1). The procedure-layer `recall_*` procedures invoke them and hand
// the results to memory's non-LLM `recall.multi` as seeds.
//
// Why a *separate* group from `bootstrapRoleRegistry()` (and not added
// into it):
//
//   * `bootstrapRoleRegistry()` is pinned at exactly the six core
//     roles by `b22_role_registry_test.dart` (`length == 6`,
//     `prototypeRoleIds` exactly those six). The six retrieval roles are a
//     distinct, optional roster — a deployment that never enables
//     Extension-H retrieval need not register them. Composing them is the
//     job of `bootstrapRoleRegistryWithRetrieval()`, which a retrieval-
//     enabled facade uses in place of the core-role bootstrap.
//
// Why bootstrap *in code* (mirroring `bootstrap_roles.dart`):
//
//   * Spec § 6.1 names `<workspace>/_ai/prompts/<role>.system.md` as the
//     eventual on-disk source. No `.system.md` mechanism ships for *any*
//     role today — the six core roles are bootstrap-in-code and the
//     file-backed loader (Plan-2 item 11) only re-voices an existing
//     core role's `personaText`. The retrieval roles follow the same
//     pattern: their voice / objective / output schema live in code, the
//     `<role>.system.md` form is the same future on-disk override the
//     core roles will gain. The plan's "<role>.system.md template"
//     phrasing is satisfied by the in-code template that the loader would
//     later re-voice, exactly as for the bootstrap core roles.
//
// Capability surface (all six identical, per § 6.2a — retrieval-internal
// transforms): each role allows `llmCall` only and forbids
// `userFacingAnswer`, `memoryWrite`, and `subThinking`. They never speak
// to the user, never write memory, and never spawn sub-questions — they
// read a prompt (plus, for some, a caller-supplied candidate list) and
// emit one structured result the procedure layer consumes. The candidate
// lists are fed as `assemble` inputs by the procedure, not read from
// memory here (memory is LLM-free), so `memoryRead` is not granted.

import '../allowed_action.dart';
import '../role_budget_defaults.dart';
import '../bootstrap_roles.dart' show bootstrapRoleRegistry;
import '../role_registry.dart';
import '../role_template.dart';

/// The six Extension-H retrieval role ids, in canonical order
/// (substrate spec § 6.2a, top-to-bottom of the role table).
///
/// Iteration order of [retrievalRoleTemplates] and
/// [bootstrapRetrievalRoleRegistry] follows this list verbatim, so the
/// trail / observability layer sees a stable ordering.
const List<String> retrievalRoleIds = <String>[
  'recall_planner',
  'hypothesis_writer',
  'query_term_writer',
  'category_selector',
  'retrieval_reranker',
  'profile_selector',
];

/// The actions every retrieval role forbids. Retrieval roles are
/// internal transforms: they never speak to the user, never write
/// memory, and never spawn sub-questions.
const Set<AllowedAction> _retrievalForbidden = <AllowedAction>{
  AllowedAction.userFacingAnswer,
  AllowedAction.memoryWrite,
  AllowedAction.subThinking,
};

/// JSON-schema fragment for a required array-of-strings property.
Map<String, Object?> _stringArray() => const <String, Object?>{
      'type': 'array',
      'items': <String, Object?>{'type': 'string'},
    };

/// Builds the six retrieval `RoleTemplate` instances, in
/// [retrievalRoleIds] order. Pure factory — no IO, no global state.
List<RoleTemplate> retrievalRoleTemplates() => <RoleTemplate>[
      _recallPlanner(),
      _hypothesisWriter(),
      _queryTermWriter(),
      _categorySelector(),
      _retrievalReranker(),
      _profileSelector(),
    ];

/// A [RoleRegistry] holding exactly the six retrieval roles.
///
/// Use this when only the retrieval roster is needed (e.g. a retrieval
/// eval harness). The full thinking + retrieval roster is
/// [bootstrapRoleRegistryWithRetrieval].
RoleRegistry bootstrapRetrievalRoleRegistry() =>
    RoleRegistry(templates: retrievalRoleTemplates());

/// A [RoleRegistry] holding the six core roles
/// ([bootstrapRoleRegistry]) plus the six retrieval roles, in that order
/// (twelve roles total).
///
/// A retrieval-enabled substrate facade composes its registry from this
/// factory in place of the core-role bootstrap. The bootstrap roster is
/// unchanged — `bootstrapRoleRegistry()` still returns exactly the six
/// core roles, so the b22 contract holds.
RoleRegistry bootstrapRoleRegistryWithRetrieval() {
  final bootstrap = bootstrapRoleRegistry();
  return RoleRegistry(
    templates: <RoleTemplate>[
      ...bootstrap.templates,
      ...retrievalRoleTemplates(),
    ],
  );
}

// ----- `recall_planner` -----
//
// § 6.2a: "the clarifying questions whose answers would help handle the
// prompt" → `recall_hyde_v1` `vector.questions` seeds.
RoleTemplate _recallPlanner() {
  return RoleTemplate(
    id: 'recall_planner',
    personaText: 'I am the recall planner. I read the user\'s prompt and '
        'name the clarifying questions whose answers would most help the '
        'brain handle it.',
    objective: 'Produce a small set of well-formed clarifying questions '
        'whose answers, if recalled from memory, would most help address '
        'the prompt. Each question stands alone; do not answer them. The '
        'questions seed the HyDE vector-recall path.',
    allowedActions: const {AllowedAction.llmCall},
    forbiddenActions: _retrievalForbidden,
    outputSchema: <String, Object?>{
      'type': 'object',
      'required': const <String>['questions'],
      'properties': <String, Object?>{'questions': _stringArray()},
    },
    budgetDefaults: RoleBudgetDefaults.empty,
  );
}

// ----- `hypothesis_writer` -----
//
// § 6.2a: "one or more plausible sample answers (HyDE) to each question"
// → `recall_hyde_v1` `vector.hypothetical_answers` seeds.
RoleTemplate _hypothesisWriter() {
  return RoleTemplate(
    id: 'hypothesis_writer',
    personaText: 'I am the hypothesis writer. I draft plausible sample '
        'answers to a question so their embeddings can seed vector recall '
        '(HyDE).',
    objective: 'Write one or more plausible sample answers to the question '
        'presented. The answers are not shown to the user and need not be '
        'correct — they exist so their embeddings retrieve memory phrased '
        'like a real answer. Favour answers that read unlike the question.',
    allowedActions: const {AllowedAction.llmCall},
    forbiddenActions: _retrievalForbidden,
    outputSchema: <String, Object?>{
      'type': 'object',
      'required': const <String>['answers'],
      'properties': <String, Object?>{'answers': _stringArray()},
    },
    budgetDefaults: RoleBudgetDefaults.empty,
  );
}

// ----- `query_term_writer` -----
//
// § 6.2a: "a focused FTS/boolean query + synonym expansions" →
// `recall_lexical_v1` `bm25.llm_query_terms` / `synonym_expansion` seeds.
RoleTemplate _queryTermWriter() {
  return RoleTemplate(
    id: 'query_term_writer',
    personaText: 'I am the query-term writer. I turn a prompt into a '
        'focused full-text query and a set of synonym expansions for '
        'lexical recall.',
    objective: 'Produce one focused FTS/boolean query plus a set of '
        'synonym expansions that broaden lexical recall without drifting '
        'off-topic. The query seeds BM25; the synonyms seed query '
        'expansion. Keep the query tight; keep synonyms relevant.',
    allowedActions: const {AllowedAction.llmCall},
    forbiddenActions: _retrievalForbidden,
    outputSchema: <String, Object?>{
      'type': 'object',
      'required': const <String>['query', 'synonyms'],
      'properties': <String, Object?>{
        'query': const <String, Object?>{'type': 'string'},
        'synonyms': _stringArray(),
      },
    },
    budgetDefaults: RoleBudgetDefaults.empty,
  );
}

// ----- `category_selector` -----
//
// § 6.2a: "the relevant node-types / edge-types / Concept names picked
// from a candidate list" → `recall_semantic_v1`
// `symbolic.type_filter_by_llm`, `graphWalk.seed_from_llm_picked`,
// `edge_type_selection_by_llm`.
RoleTemplate _categorySelector() {
  return RoleTemplate(
    id: 'category_selector',
    personaText: 'I am the category selector. From a candidate list of '
        'node-types, edge-types, and Concept names, I pick the ones '
        'relevant to the prompt.',
    objective: 'Given the prompt and a candidate list of node-types, '
        'edge-types, and Concept names, select the subset relevant to the '
        'prompt. Pick only from the candidates offered; do not invent new '
        'types or names. The selection seeds the semantic graph-walk path.',
    allowedActions: const {AllowedAction.llmCall},
    forbiddenActions: _retrievalForbidden,
    outputSchema: <String, Object?>{
      'type': 'object',
      'required': const <String>['node_types', 'edge_types', 'concept_names'],
      'properties': <String, Object?>{
        'node_types': _stringArray(),
        'edge_types': _stringArray(),
        'concept_names': _stringArray(),
      },
    },
    budgetDefaults: RoleBudgetDefaults.empty,
  );
}

// ----- `retrieval_reranker` -----
//
// § 6.2a: "a scored ordering of the fused candidate set" → the fusion
// step (hub § 23.3) when `rerank.enabled`.
RoleTemplate _retrievalReranker() {
  return RoleTemplate(
    id: 'retrieval_reranker',
    personaText: 'I am the retrieval reranker. I read a fused candidate '
        'set and score each item by relevance to the prompt.',
    objective: 'Given the prompt and a fused candidate set, emit a scored '
        'ordering of the candidates by relevance. Each entry carries the '
        'candidate id and a score; higher means more relevant. Score every '
        'candidate offered; do not add candidates not in the set.',
    allowedActions: const {AllowedAction.llmCall},
    forbiddenActions: _retrievalForbidden,
    outputSchema: <String, Object?>{
      'type': 'object',
      'required': const <String>['ranking'],
      'properties': <String, Object?>{
        'ranking': <String, Object?>{
          'type': 'array',
          'items': <String, Object?>{
            'type': 'object',
            'required': const <String>['id', 'score'],
            'properties': <String, Object?>{
              'id': const <String, Object?>{'type': 'string'},
              'score': const <String, Object?>{'type': 'number'},
            },
          },
        },
      },
    },
    budgetDefaults: RoleBudgetDefaults.empty,
  );
}

// ----- `profile_selector` -----
//
// § 6.2a: "a memory-profile name + confidence for the first prompt" →
// the access-layer `MemoryProfileSelector` (access spec § 7.4).
RoleTemplate _profileSelector() {
  return RoleTemplate(
    id: 'profile_selector',
    personaText: 'I am the profile selector. From the first prompt of a '
        'session I pick the memory profile the brain should recall '
        'against, with a confidence.',
    objective: 'Given the prompt and the candidate profile names, pick the '
        'single most appropriate memory profile and report a confidence in '
        '[0, 1]. Pick `default` when no candidate clearly fits. The '
        'access layer uses the confidence to decide whether to commit to '
        'the profile or re-check on a later turn.',
    allowedActions: const {AllowedAction.llmCall},
    forbiddenActions: _retrievalForbidden,
    outputSchema: <String, Object?>{
      'type': 'object',
      'required': const <String>['profile', 'confidence'],
      'properties': <String, Object?>{
        'profile': const <String, Object?>{'type': 'string'},
        'confidence': const <String, Object?>{
          'type': 'number',
          'minimum': 0,
          'maximum': 1,
        },
      },
    },
    budgetDefaults: RoleBudgetDefaults.empty,
  );
}
