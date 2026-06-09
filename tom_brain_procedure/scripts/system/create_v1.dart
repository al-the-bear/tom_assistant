/// @procedure
/// id: create_v1
/// version: 1
/// summary: The creation branch — observe, draft a single artifact,
///   self-critique against the success criterion, and re-enter on revision
///   within a bounded budget; write the artifact to the file-scope sandbox only
///   once a critique accepts, then persist the request (Question) and the
///   produced Artifact with a satisfied_by linkage.
/// successCriterion: a creation request carrying an intent, an observable
///   success criterion, and a target path produces exactly one artifact —
///   written to disk only on the first accept and never on a rejected draft;
///   the request is recorded as a Question and the produced file as an Artifact
///   satisfied_by that Question. A request missing intent or the success
///   criterion is refused (vagueIntent) before any draft is composed.
/// budget: { wallClockMs: 300000 }
/// # A wall-clock backstop only (§ 7.4): 300000 ms (5 min) is the spec's default
/// # runaway-stop for a genuinely hung run, not a throttle. The creation
/// # re-entry is bounded separately by `maxIterations` (a literal in the body,
/// # § 4.1), so the loop terminates long before the wall clock fires.
/// inputs:
///   - { name: intent, type: String, required: true }
///   - { name: successCriterion, type: String, required: true }
///   - { name: target, type: String, required: true }
///   - { name: kind, type: String, required: false }
///   - { name: context, type: String, required: false }
///   - { name: constraints, type: String, required: false }
/// outputs:
///   - { name: written, type: bool }
///   - { name: target, type: String }
///   - { name: incomplete, type: bool }
/// requires: [ recall, embed, llm, persist, edge, note, tool.invoke ]
//
// create_v1 — the creation branch (`tom_brain_completion_plan.md` Todo 9, gaps
// G-C1…G-C6; `creation_specification.md` § 4, § 5, § 7, § 10, § 12.1). It
// supersedes the Todo-4 clear-error stub: the `create()` sugar verb and the
// `procedure.create` tool now reach a real loop instead of a loud failure.
//
// ── How it is reached (§ 4-as-router) ───────────────────────────────────
//
// Creation is never selected directly. `prompt_analyzer_v1`
// (`thinking_specification.md` § 4-as-router) classifies a prompt as a creation
// goal and issues a `create()` call with the caller-supplied intent + kind +
// target + successCriterion + context + constraints (§ 10). There is no
// creation *persona* (dropped, Q-3) — creation is a procedure, not a chat role.
//
// ── Entry validation (§ 10, G-C5) ───────────────────────────────────────
//
// Creation writes to the filesystem, so it refuses to start on a vague request:
// a blank or absent intent OR success criterion is a `vagueIntent` refusal,
// raised *before any draft is composed* — a vague request is routed through
// thinking + planning first, never straight into a file write. The check lives
// in the body because the engine does not enforce header `required` at runtime
// (the header `required: true` is documentation; the body is the gate).
//
// ── The creation loop (§ 4.1) ───────────────────────────────────────────
//
// One pass through the `while` is one creation iteration:
//
//   observe   — `mem.recall(intent)` grounds the draft in memory (HP4, the
//               second author). Dispatched *once* before the loop: the recalled
//               context is stable across iterations; only the draft and the
//               critique change.
//   draft     — `sub.llm(role: 'creator')` composes the artifact from the
//               intent, kind, success criterion, context, constraints, recalled
//               memory, and (on a re-entry) the prior rejected draft + its
//               critique. Deliberately *no* `tools` argument: the draft is pure
//               composition; the single write happens once, on accept.
//   critique  — `sub.llm(role: 'reviewer')` judges the draft against the
//               success criterion and returns a verdict (alphabet
//               `accept | revise`); `_isAccept` parses it.
//   re-enter  — on `revise` the rejected draft + critique are carried forward as
//               `revisionContext` and the loop re-enters; on `accept` it exits.
//
// ── Write-on-accept-only (§ 12.1 decision 5, P6) ────────────────────────
//
// The skeleton realises the loop as *write-on-accept-only*: a draft reaches disk
// only once a critique accepts it. The § 4.4 "write each draft → re-observe →
// run analyze/test check → roll back a rejected write" cycle defers until the
// engine wires a `ToolProcessSurface` into the run's `ToolContext` (so the
// `analyze.*` / `test.*` check tools can run) and a reversible write/stage
// primitive exists (there is no `file.delete` to undo a rejected write). Until
// then, writing only the accepted draft is the faithful realisation of "writes
// artifacts only on success" — no rejected draft is ever written, so "no silent
// writes" holds *by construction* and no rollback is needed. The `tester` role
// is registered (G-C4) but the test-first *execution* branch defers on the same
// process-surface wiring.
//
// ── The trail (§ 9, § 12.1 decision 4) ──────────────────────────────────
//
// The typed `CreationEvent` family is deferred (no consumer exists yet); the
// observable trail is realised as memory nodes plus the run's effect trail:
//
//   • a `Question` carrying the creation request (intent + success criterion) —
//     the durable "what was asked", persisted the moment the request arrives so
//     the trail records it even if no draft is ever accepted;
//   • on accept, an `Artifact` (`kind` / `summary` / `content_ref` = the written
//     target) — the durable "what was produced";
//   • an `Artifact → satisfied_by → Question` edge (the realised-store direction
//     of the spec's "satisfied-by linkage", § 9.2);
//   • `note('progress', …)` markers for the per-stage observability § 9.1 lists.
//
// The body has no run id, so its writes carry the procedure id as the producer
// (Q-D.39.3); the authoritative `produced_by` edges are the recorder's job, fed
// by the reserved `producedNodeIds` channel the engine splits off the returned
// map and strips before surfacing outputs. Embeddings are supplied before each
// persist because the real store does not embed lazily.
//
// ── Imports / anchor (PE-1 / PE-7) ──────────────────────────────────────
//
// Only the host-injected libraries this body touches are imported, and the
// SandboxValidator allow-lists exactly these: `procedure_inputs`
// (`inputs.getOrNull(...)`), `memory_bridge` (`mem.recall` / `mem.persist` /
// `mem.edge`), `substrate_bridge` (`sub.llm` / `sub.embed`), `tool_bridge` (the
// `tool.invoke('file.write', …)` write), and `primitives_native` (the
// engine-native `note`). Every completion names a `role` and supplies the prompt
// as that role template's *input*, so the assistant-dedication anchor is always
// prepended at substrate assembly time.
import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure/src/bridges/memory_bridge.dart';
import 'package:tom_brain_procedure/src/bridges/substrate_bridge.dart';
import 'package:tom_brain_procedure/src/bridges/tool_bridge.dart';
import 'package:tom_brain_procedure/src/primitives_native/primitives_native.dart';

Future<Map<String, Object?>> run(ProcedureInputs inputs) async {
  // Entry validation (§ 10, G-C5): intent + an observable success criterion are
  // mandatory before any draft. `getOrNull` returns null on absence; a blank
  // string is treated the same as absent so a whitespace request is refused.
  final intent = (inputs.getOrNull<String>('intent') ?? '').trim();
  final successCriterion =
      (inputs.getOrNull<String>('successCriterion') ?? '').trim();
  final target = (inputs.getOrNull<String>('target') ?? '').trim();
  if (intent.isEmpty || successCriterion.isEmpty) {
    throw ArgumentError(
      'create_v1: vagueIntent — creation needs a concrete intent and an '
      'observable success criterion before any artifact is written '
      '(intent="$intent", successCriterion="$successCriterion"). Route a vague '
      'request through thinking and planning first.',
    );
  }
  if (target.isEmpty) {
    throw ArgumentError(
      'create_v1: vagueIntent — creation needs a target path to write the '
      'artifact to.',
    );
  }

  final kind = (inputs.getOrNull<String>('kind') ?? 'code').trim();
  final context = inputs.getOrNull<String>('context') ?? '';
  final constraints = inputs.getOrNull<String>('constraints') ?? '';
  final producer = 'create_v1';

  // Observe (§ 4.1): recall memory context once before the loop — the second
  // author (HP4). Stable across iterations, so dispatched once and reused.
  final recall = await mem.recall(intent, k: 8);

  // The request is durable the moment it arrives: persist it as a Question so
  // the produced Artifact has something to be `satisfied_by`, and the trail
  // records what was asked even if no draft is ever accepted.
  final questionText =
      'Create ($kind): $intent\nSuccess criterion: $successCriterion';
  final questionEmbedding = await sub.embed(questionText);
  final questionId = await mem.persist(
    'Question',
    {'text': questionText},
    producer: producer,
    embedding: questionEmbedding['vec'],
  );

  // Bounded re-entry (§ 4.1): at most three creation passes. The bound is a
  // literal — a d4rt body cannot import the domain-free re-entry vocabulary, so
  // the loop enforces the cap inline. The accept test is folded into the guard
  // rather than using `break` (the d4rt interpreter rejects `break` in this
  // async `while`).
  const maxIterations = 3;
  var iteration = 0;
  var accepted = false;
  var draft = '';
  var revisionContext = '';

  while (iteration < maxIterations && !accepted) {
    iteration++;

    // Draft the artifact (creator role). No `tools`: the draft is pure
    // composition; the single write happens once, on accept.
    final draftCompletion = await sub.llm(
      _draftPrompt(intent, kind, successCriterion, context, constraints, recall,
          revisionContext),
      role: 'creator',
    );
    draft = draftCompletion['text'];

    // Self-critique against the success criterion (reviewer role; verdict
    // alphabet `accept | revise`).
    final critiqueCompletion = await sub.llm(
      _critiquePrompt(intent, successCriterion, draft),
      role: 'reviewer',
    );
    final verdict = critiqueCompletion['text'];

    if (_isAccept(verdict)) {
      accepted = true;
    } else {
      revisionContext = _revisionContext(draft, verdict);
    }
  }

  note('progress', {
    'procedure': 'create_v1',
    'iterations': iteration,
    'accepted': accepted,
    'target': target,
  });

  // Write-on-accept-only (§ 12.1 decision 5): on exhaustion nothing is written —
  // "writes artifacts only on success" holds by construction (no rejected draft
  // was ever written, so no rollback is needed). The request stays recorded as
  // the Question so the dreaming process can revisit the still-open creation.
  if (!accepted) {
    return <String, Object?>{
      'written': false,
      'target': target,
      'incomplete': true,
      'producedNodeIds': [questionId],
    };
  }

  // The single, announced write (P6: no silent writes). `file.write` resolves
  // `target` under the run's file-scope root and raises FileScopeViolation for
  // an escaping path before any byte moves — which propagates and closes the run
  // errored (the sandbox is not negotiable; a write that escapes is a bug, not a
  // soft result).
  await tool.invoke('file.write', <String, Object?>{
    'path': target,
    'content': draft,
  });

  // Persist the produced Artifact and tie it to the request it satisfies
  // (Artifact → satisfied_by → Question, § 9.2). A skipped persist returns the
  // empty-id sentinel; gate the edge on real ids.
  final summary = 'Created $kind for: $intent';
  final artifactEmbedding = await sub.embed(summary);
  final artifactId = await mem.persist(
    'Artifact',
    {'kind': kind, 'summary': summary, 'content_ref': target},
    producer: producer,
    embedding: artifactEmbedding['vec'],
  );
  if (artifactId.isNotEmpty && questionId.isNotEmpty) {
    await mem.edge(artifactId, 'satisfied_by', questionId, producer: producer);
  }

  return <String, Object?>{
    'written': true,
    'target': target,
    'incomplete': false,
    'producedNodeIds': [questionId, artifactId],
  };
}

/// Whether the reviewer's verdict is an acceptance. Conservative: anything that
/// is not an explicit ACCEPT — a `revise`, or an unparseable / non-string
/// verdict — keeps the loop iterating (bounded by `maxIterations`), so an
/// ambiguous critique never short-circuits into a write.
bool _isAccept(Object? verdict) {
  if (verdict is! String) return false;
  return verdict.toUpperCase().contains('ACCEPT');
}

/// Builds the `creator`-role draft prompt. Folds the intent, kind, success
/// criterion, caller context, constraints, recalled memory, and (on a re-entry)
/// the prior rejection into one composition instruction. Emits *only* the
/// artifact content — the surrounding loop critiques, writes, and records it.
String _draftPrompt(
  String intent,
  String kind,
  String successCriterion,
  String context,
  String constraints,
  Map recall,
  String revisionContext,
) {
  final memory = _renderRecall(recall);
  final ctx = context.isEmpty ? '' : 'Context:\n$context\n\n';
  final cons = constraints.isEmpty ? '' : 'Constraints:\n$constraints\n\n';
  return '${revisionContext}Produce a single $kind artifact that satisfies the '
      'intent and meets the success criterion exactly. Output only the artifact '
      'content — no commentary, no code fences.\n'
      '\n'
      'Intent:\n$intent\n'
      '\n'
      'Success criterion:\n$successCriterion\n'
      '\n'
      '$ctx$cons$memory';
}

/// Builds the `reviewer`-role critique prompt. Asks for a verdict the body can
/// parse: a leading ACCEPT or REVISE judged against the success criterion.
String _critiquePrompt(String intent, String successCriterion, String draft) {
  return 'Review the draft artifact below against the intent and its success '
      'criterion. Decide whether it meets the criterion and is fit to write.\n'
      '\n'
      'Reply with ACCEPT or REVISE on the first line, then a one-line reason. '
      'Use REVISE if the draft misses the criterion, is incomplete, or is '
      'wrong.\n'
      '\n'
      'Intent:\n$intent\n'
      '\n'
      'Success criterion:\n$successCriterion\n'
      '\n'
      'Draft artifact:\n$draft';
}

/// Renders the rejected draft + its critique as a re-entry preamble, or `''` on
/// the first pass (no prior rejection).
String _revisionContext(String draft, Object? verdict) {
  return 'A previous draft was sent back for revision by self-critique. Address '
      'the critique; do not repeat the same mistakes.\n'
      'Previous draft:\n$draft\n'
      'Critique:\n$verdict\n'
      '\n';
}

/// Renders the recalled nodes' `text` values as a "Relevant recalled memory"
/// block, or `''` when the recall is empty (mirrors `answer_with_thinking_v1`).
String _renderRecall(Map recall) {
  var context = '';
  final nodes = recall['nodes'];
  if (nodes is List) {
    for (final node in nodes) {
      if (node is Map) {
        final values = node['values'];
        if (values is Map && values['text'] != null) {
          context += '- ${values['text']}\n';
        }
      }
    }
  }
  return context.isEmpty ? '' : 'Relevant recalled memory:\n$context\n';
}
