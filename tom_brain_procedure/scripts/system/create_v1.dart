/// @procedure
/// id: create_v1
/// version: 1
/// summary: The creation branch — observe, optionally draft a test first, then
///   per iteration draft an artifact, write it to the file-scope sandbox,
///   re-observe and run the analyze/test check against the written file,
///   self-critique against the success criterion + the check, and either keep
///   the write or roll it back and re-enter within a bounded budget; persist the
///   request (Question) and the accepted Artifact with a satisfied_by linkage.
/// successCriterion: a creation request carrying an intent, an observable
///   success criterion, and a target path produces exactly one artifact — left
///   on disk only when a critique accepts it AND the check is satisfied, and
///   rolled back (file.delete) on every rejected iteration so no rejected draft
///   survives; the request is recorded as a Question and the produced file as an
///   Artifact satisfied_by that Question. A request missing intent or the
///   success criterion is refused (vagueIntent) before any draft is composed.
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
// create_v1 — the creation branch (`creation_specification.md` § 4, § 5, § 7,
// § 9, § 10; `tom_brain_completion_plan_2.md` item 2). The Todo-9 skeleton
// realised this as *write-on-accept-only* and deferred the § 4.4
// write → re-observe → check → rollback cycle (plus the test-first branch) until
// the engine wired a `ToolProcessSurface` and a reversible-write primitive
// existed. Both now exist (`ProcessRunToolSurface` on every run `ToolContext`,
// `file.delete` in the basic set), so this body realises the full loop.
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
// ── Stage B — Test-first (§ 4.3, P4) ────────────────────────────────────
//
// When the artifact is code and the caller has not opted out (`_shouldTestFirst`),
// the `tester` role drafts the success-check first. It is written to a derived
// test target and run via `test.run` *before* any artifact exists; the run is
// expected to fail or be skipped (the "right kind of failure", § 4.3) and its
// outcome is noted. The staged test is rolled back along with the artifact if
// the loop never accepts (§ 4.3).
//
// ── The creation loop (§ 4.1, § 4.4–§ 4.7) ──────────────────────────────
//
// One pass through the `while` is one creation iteration:
//
//   draft     — `sub.llm(role: 'creator')` composes the artifact from the
//               intent, kind, success criterion, context, constraints, recalled
//               memory, the test (if any), and (on a re-entry) the prior
//               rejected draft + its critique + check.
//   write     — the draft is written to `target` (§ 4.4: "There is no in-memory
//               draft we never wrote. Writes are observable.").
//   re-observe+check — for code the written file is re-observed by running the
//               allow-listed `analyze.dart` check tool against it (§ 4.5); the
//               check is satisfied when the analyzer exits clean. Non-code kinds
//               carry no analyzer check, so the check is trivially satisfied.
//   critique  — `sub.llm(role: 'reviewer')` judges the draft against the success
//               criterion *and* the check result and returns a verdict
//               (`accept | revise`); `_isAccept` parses it.
//   accept / rollback — the write is kept only when the reviewer accepts AND the
//               check is satisfied (§ 4.6 `accept requires successSatisfied`).
//               Otherwise the written draft is rolled back (`file.delete`,
//               § 4.7) and the loop re-enters carrying the rejection forward.
//
// So a rejected draft never survives on disk (rolled back the same iteration),
// and an accepted draft is the one the run leaves in place — "no silent writes"
// (P6) holds even though every draft is written, because every rejected write is
// observably undone.
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
// `tool.invoke(...)` write / delete / check), and `primitives_native` (the
// engine-native `note`). The `analyze.*` / `test.*` / `file.*` tools are reached
// through the single `tool.invoke` primitive, so they add no new bridge to the
// declared capability surface — the check has no general-shell reach (§ 5.4: the
// allow-listed `ToolProcessSurface`, not this body, runs the executable). Every
// completion names a `role` and supplies the prompt as that role template's
// *input*, so the assistant-dedication anchor is always prepended at substrate
// assembly time.
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
  // Code artifacts carry an analyzer check (§ 4.5) and, unless opted out, a
  // test-first stage (§ 4.3). Other kinds (text / doc / config) have no
  // analyzer, so their check is trivially satisfied and the loop reduces to
  // draft → write → critique → keep-or-rollback.
  final checks = kind == 'code';
  final testFirst = checks && !_optsOutOfTestFirst(constraints);

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

  // Stage B — test-first (§ 4.3). The tester role drafts the success-check, it
  // is written to a derived test target, and `test.run` runs it before any
  // artifact exists. The run is expected to fail or be skipped; its outcome is
  // noted. The staged test is rolled back with the artifact if the loop never
  // accepts. A blank/whitespace test draft is not written.
  final testTarget = testFirst ? _deriveTestTarget(target) : '';
  var testStaged = false;
  if (testFirst) {
    final testCompletion = await sub.llm(
      _testPrompt(intent, successCriterion, kind, context, constraints, recall),
      role: 'tester',
    );
    final testDraft = (testCompletion['text'] ?? '').toString();
    if (testDraft.trim().isNotEmpty) {
      await tool.invoke('file.write', <String, Object?>{
        'path': testTarget,
        'content': testDraft,
      });
      testStaged = true;
      final testInvoke =
          await tool.invoke('test.run', <String, Object?>{'path': '.'});
      note('progress', {
        'procedure': 'create_v1',
        'stage': 'test_first',
        'testTarget': testTarget,
        // The test should not pass before the artifact exists (§ 4.3).
        'failedOrSkipped': !_invokeCheckPassed(testInvoke),
      });
    }
  }

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
    // composition; the write is the explicit step that follows.
    final draftCompletion = await sub.llm(
      _draftPrompt(intent, kind, successCriterion, context, constraints, recall,
          testFirst, revisionContext),
      role: 'creator',
    );
    draft = draftCompletion['text'];

    // Write the draft (§ 4.4: writes are observable — no in-memory-only draft).
    // `file.write` resolves `target` under the run's file-scope root and raises
    // FileScopeViolation for an escaping path before any byte moves, which
    // propagates and closes the run errored (the sandbox is not negotiable).
    await tool.invoke('file.write', <String, Object?>{
      'path': target,
      'content': draft,
    });

    // Re-observe + check (§ 4.5): for code, run the allow-listed analyzer over
    // the written file. The check is satisfied when the analyzer exits clean.
    // For non-code kinds there is no analyzer, so the check is satisfied.
    var checkPassed = true;
    Object? checkResult;
    if (checks) {
      final checkInvoke =
          await tool.invoke('analyze.dart', <String, Object?>{'path': target});
      checkResult = _invokeResult(checkInvoke);
      checkPassed = _invokeCheckPassed(checkInvoke);
    }

    // Self-critique against the success criterion AND the check (reviewer role;
    // verdict alphabet `accept | revise`).
    final critiqueCompletion = await sub.llm(
      _critiquePrompt(intent, successCriterion, draft, checks, checkResult),
      role: 'reviewer',
    );
    final verdict = critiqueCompletion['text'];

    // Accept requires the reviewer's ACCEPT *and* a satisfied check (§ 4.6:
    // `accept requires successSatisfied`). Otherwise roll the write back
    // (§ 4.7) and re-enter carrying the rejection forward.
    if (_isAccept(verdict) && checkPassed) {
      accepted = true;
    } else {
      await tool.invoke('file.delete', <String, Object?>{'path': target});
      revisionContext = _revisionContext(draft, verdict, checkResult);
    }
  }

  note('progress', {
    'procedure': 'create_v1',
    'iterations': iteration,
    'accepted': accepted,
    'target': target,
  });

  // On exhaustion the artifact was rolled back on its final rejected iteration,
  // so nothing survives on disk — "writes artifacts only on success" (P6). Roll
  // back the staged test too, then return incomplete. The request stays recorded
  // as the Question so the dreaming process can revisit the still-open creation.
  if (!accepted) {
    if (testStaged) {
      await tool.invoke('file.delete', <String, Object?>{'path': testTarget});
    }
    return <String, Object?>{
      'written': false,
      'target': target,
      'incomplete': true,
      'producedNodeIds': [questionId],
    };
  }

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

/// Whether the caller opted creation out of the test-first stage via a
/// `constraints` marker (§ 4.3 is "when applicable"). A free-text constraint
/// containing `no-test-first` / `no test first` / `skip-test-first` turns it off.
bool _optsOutOfTestFirst(String constraints) {
  final c = constraints.toLowerCase();
  return c.contains('no-test-first') ||
      c.contains('no test first') ||
      c.contains('skip-test-first') ||
      c.contains('skip test first');
}

/// Derives a test target alongside the artifact target (§ 4.3). A Dart target
/// `foo.dart` yields `foo_first_test.dart`; any other target appends a suffix.
/// Deterministic so the staged test can be rolled back by the same path.
String _deriveTestTarget(String target) {
  if (target.endsWith('.dart')) {
    return '${target.substring(0, target.length - 5)}_first_test.dart';
  }
  return '$target.first_test';
}

/// Extracts the inner tool result map from a `tool.invoke` envelope
/// (`{ok: true, result: <toolResult>}`), or `null` when the invoke did not
/// succeed.
Object? _invokeResult(Object? invoke) {
  if (invoke is Map && invoke['ok'] == true) {
    return invoke['result'];
  }
  return null;
}

/// Whether a `tool.invoke` of an `analyze.*` / `test.*` check tool reports a
/// clean run: the invoke succeeded and the wrapped process result exited 0
/// (`_processResultMap`'s `ok`). Anything else — a failed invoke, a non-zero
/// exit, or a malformed shape — is a non-passing check.
bool _invokeCheckPassed(Object? invoke) {
  final result = _invokeResult(invoke);
  return result is Map && result['ok'] == true;
}

/// Whether the reviewer's verdict is an acceptance. Conservative: anything that
/// is not an explicit ACCEPT — a `revise`, or an unparseable / non-string
/// verdict — keeps the loop iterating (bounded by `maxIterations`), so an
/// ambiguous critique never short-circuits into a kept write.
bool _isAccept(Object? verdict) {
  if (verdict is! String) return false;
  return verdict.toUpperCase().contains('ACCEPT');
}

/// Builds the `tester`-role test-first prompt (§ 4.3). Asks for an executable
/// success-check that fails before the artifact exists. Emits only the test
/// content — the surrounding loop writes and runs it.
String _testPrompt(
  String intent,
  String successCriterion,
  String kind,
  String context,
  String constraints,
  Map recall,
) {
  final memory = _renderRecall(recall);
  final ctx = context.isEmpty ? '' : 'Context:\n$context\n\n';
  final cons = constraints.isEmpty ? '' : 'Constraints:\n$constraints\n\n';
  return 'Write a single $kind test that checks the success criterion below '
      'before the artifact exists. The test must fail (or skip with a clear '
      'reason) until the artifact is created. Output only the test content — no '
      'commentary, no code fences.\n'
      '\n'
      'Intent:\n$intent\n'
      '\n'
      'Success criterion:\n$successCriterion\n'
      '\n'
      '$ctx$cons$memory';
}

/// Builds the `creator`-role draft prompt. Folds the intent, kind, success
/// criterion, caller context, constraints, recalled memory, the test-first note,
/// and (on a re-entry) the prior rejection into one composition instruction.
/// Emits *only* the artifact content — the surrounding loop critiques, writes,
/// and records it.
String _draftPrompt(
  String intent,
  String kind,
  String successCriterion,
  String context,
  String constraints,
  Map recall,
  bool testFirst,
  String revisionContext,
) {
  final memory = _renderRecall(recall);
  final ctx = context.isEmpty ? '' : 'Context:\n$context\n\n';
  final cons = constraints.isEmpty ? '' : 'Constraints:\n$constraints\n\n';
  final test = testFirst
      ? 'A test was written first and must pass once the artifact exists.\n\n'
      : '';
  return '$revisionContext${test}Produce a single $kind artifact that satisfies '
      'the intent and meets the success criterion exactly. Output only the '
      'artifact content — no commentary, no code fences.\n'
      '\n'
      'Intent:\n$intent\n'
      '\n'
      'Success criterion:\n$successCriterion\n'
      '\n'
      '$ctx$cons$memory';
}

/// Builds the `reviewer`-role critique prompt. Asks for a verdict the body can
/// parse: a leading ACCEPT or REVISE judged against the success criterion and
/// (when one ran) the automated check result.
String _critiquePrompt(
  String intent,
  String successCriterion,
  String draft,
  bool checks,
  Object? checkResult,
) {
  final check = checks ? 'Automated check result:\n${_renderCheck(checkResult)}\n\n' : '';
  return 'Review the draft artifact below against the intent and its success '
      'criterion. Decide whether it meets the criterion and is fit to keep.\n'
      '\n'
      'Reply with ACCEPT or REVISE on the first line, then a one-line reason. '
      'Use REVISE if the draft misses the criterion, is incomplete, is wrong, or '
      'the automated check did not pass.\n'
      '\n'
      'Intent:\n$intent\n'
      '\n'
      'Success criterion:\n$successCriterion\n'
      '\n'
      '${check}Draft artifact:\n$draft';
}

/// Renders the rejected draft + its critique (+ the failed check, if any) as a
/// re-entry preamble (§ 4.7).
String _revisionContext(String draft, Object? verdict, Object? checkResult) {
  final check = checkResult is Map
      ? 'Check result:\n${_renderCheck(checkResult)}\n'
      : '';
  return 'A previous draft was sent back for revision by self-critique. Address '
      'the critique; do not repeat the same mistakes.\n'
      'Previous draft:\n$draft\n'
      'Critique:\n$verdict\n'
      '$check'
      '\n';
}

/// Renders a check tool's process-result map as a short reviewable verdict.
/// Reports the clean/failed status and the exit code only — the captured output
/// streams are intentionally not surfaced here (their map keys collide with the
/// sandbox's banned process-stream identifiers, so the reviewer is given the
/// pass/fail signal it gates on rather than the raw stream text).
String _renderCheck(Object? checkResult) {
  if (checkResult is Map) {
    final ok = checkResult['ok'] == true ? 'clean' : 'FAILED';
    final code = checkResult['exitCode'];
    return code == null ? ok : '$ok (exit $code)';
  }
  return 'not run';
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
