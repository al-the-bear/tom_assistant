/// @procedure
/// id: plan_v1
/// version: 1
/// summary: The planning loop — classify a goal, decompose it into ordered
///   steps, critique the graph, and commit an inspectable Plan + PlanStep graph;
///   re-plan surgically when an observation invalidates a live plan.
/// successCriterion: A Plan node and its PlanStep nodes are persisted with
///   part_of step→plan edges and part_of[kind=depends_on] dependency edges, the
///   plan id is returned and produced, and a PlanningEvent trail is emitted; a
///   re-plan supersedes the replaced steps (structural, never destructive).
/// budget: { wallClockMs: 120000, tokenSpend: 40000, toolCalls: 64, memoryWrites: 128 }
/// inputs:
///   - { name: goal, type: String, required: true }
///   - { name: context, type: String, required: false }
///   - { name: maxIterations, type: int, required: false }
///   - { name: plan, type: String, required: false }
///   - { name: observation, type: String, required: false }
/// outputs:
///   - { name: plan, type: String }
///   - { name: status, type: String }
/// requires: [ recall, llm, embed, persist, edge, note ]
//
// plan_v1 — planning as a procedure, not a project (Todo 8 / G-P1…G-P6;
// `planning_specification.md` § 4.1 the loop, § 4.7 re-planning, § 5.3 the edge
// model, § 7.4 the typed reads, § 10 the trail vocabulary). There is no
// `tom_brain_planning` project: the planning loop *is* this d4rt procedure,
// running over the five planning roles in `tom_brain_substrate`
// (`planner` / `decomposer` / `estimator` / `plan_evaluator` / `re_planner`)
// and writing the Plan + PlanStep graph through the memory bridge.
//
// ── The loop (§ 4.1) ────────────────────────────────────────────────
//
//   1. Recall prior work as context (the only read in the planning path).
//   2. classify the goal (`planner`) → a PlanKind token.
//   3. decompose it into steps with inline `<- n,m` dependency markers
//      (`decomposer`).
//   4. order the steps (`estimator`); an unorderable graph (a cycle) is a
//      rejected iteration, not a silent drop.
//   5. critique the ordered graph (`plan_evaluator`): `accept` commits;
//      anything else re-enters the loop.
//   6. on accept, persist an `active` Plan + its `pending` PlanStep nodes,
//      `part_of` step→plan edges, and `part_of[kind=depends_on]` dependency
//      edges. If the loop is exhausted without an accept but an orderable graph
//      was seen, commit the best effort at `draft` rather than throwing; if no
//      orderable graph ever existed, fail loudly (the run closes `errored`).
//
// ── Re-planning (§ 4.7) ─────────────────────────────────────────────
//
// When called with an existing `plan` id and an `observation`, the loop is not
// re-run: the `re_planner` role proposes replacement steps and the ids they
// supersede. The replacements are persisted under the existing plan and the
// superseded steps are linked to the first replacement with a `superseded_by`
// edge — structural retention, never deletion (umbrella overview hard
// principle 6). Unaffected branches are left untouched.
//
// ── Sandbox discipline ──────────────────────────────────────────────
//
// The body runs through the real d4rt sandbox (PE-1), so it uses only simple
// string operations (split / trim / indexOf / substring / contains /
// concatenation) and `int.tryParse` — no RegExp, no dart:convert, no
// StringBuffer. The pure parsing helpers are top-level (they touch no bridged
// globals); every `mem` / `sub` / `note` effect stays inside `run`. The
// `depends_on` marker and the PlanningEvent categories are written as literals
// (a sandboxed body cannot import `tom_brain_shared`); the acceptance suite pins
// those literals against the shared `dependsOnEdgeKind` / `planningEventKinds`
// so the two can never drift.
import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure/src/bridges/memory_bridge.dart';
import 'package:tom_brain_procedure/src/bridges/substrate_bridge.dart';
import 'package:tom_brain_procedure/src/primitives_native/primitives_native.dart';

Future<Map<String, Object?>> run(ProcedureInputs inputs) async {
  const producer = 'plan_v1';
  final goal = inputs.get('goal');
  final goalText = goal.toString();
  final observation = inputs.getOrNull('observation');
  final planArg = inputs.getOrNull('plan');
  final maxArg = inputs.getOrNull('maxIterations');
  final maxIterations = maxArg is int ? maxArg : 3;

  note('planning.requested', {'goal': goal});

  // ── Re-planning branch (§ 4.7): an observation against a live plan ──
  if (observation != null && planArg != null) {
    final replanOut = await sub.llm(
      'Re-plan. Goal: ' + goalText + ' Observation: ' + observation.toString(),
      role: 're_planner',
    );
    final replanRaw = replanOut['text'];
    final replanText = replanRaw is String ? replanRaw : '';
    final supersedes = _parseSupersedes(replanText);
    final steps = _parseSteps(_stripSupersedesLine(replanText));
    if (steps.isEmpty) {
      throw StateError('plan_v1 re-plan: no replacement steps produced');
    }

    final stepIds = <String>[];
    final idByLine = {};
    for (var i = 0; i < steps.length; i++) {
      final desc = steps[i]['description'].toString();
      final stepId = await mem.persist('PlanStep', {
        'description': desc,
        'plan_id': planArg,
        'step_index': i,
        'kind': 'think',
        'status': 'pending',
        'success_criterion': 'Done when: ' + desc,
      }, producer: producer);
      stepIds.add(stepId);
      idByLine[i + 1] = stepId;
      await mem.edge(stepId, 'part_of', planArg, producer: producer);
    }
    await _wireDependencies(mem, steps, idByLine, producer);

    final replacement = stepIds[0];
    for (var si = 0; si < supersedes.length; si++) {
      await mem.edge(supersedes[si], 'superseded_by', replacement,
          producer: producer);
      note('planning.revised', {
        'planId': planArg,
        'supersededId': supersedes[si],
        'replacementId': replacement,
      });
    }

    return {'plan': planArg, 'status': 'revised', 'producedNodeIds': stepIds};
  }

  // ── Initial planning loop (§ 4.1) ──
  await mem.recall(goalText, modes: ['bm25', 'vector'], k: 8);

  var lastKind = 'composite';
  var lastSteps = [];
  var lastOrder = [];
  var haveOrderable = false;
  var commit = false;
  var commitStatus = 'draft';

  // Each awaited LLM result is hoisted into its own statement before any local
  // is read from it: the d4rt sandbox does not preserve a block-local that is
  // referenced in an argument evaluated *after* a preceding awaited argument in
  // the same call, so the await and the local read never share an expression.
  for (var iter = 0; iter < maxIterations; iter++) {
    final classifyOut = await sub.llm(
      'Classify and frame this goal: ' + goalText,
      role: 'planner',
    );
    final kind = _parseKind(classifyOut['text']);
    note('planning.goal-classified', {'planKind': kind});

    final decomposeOut = await sub.llm(
      'Decompose this goal into steps: ' + goalText,
      role: 'decomposer',
    );
    final steps = _parseSteps(decomposeOut['text']);
    note('planning.steps-decomposed', {'stepCount': steps.length});

    final rendered = _renderSteps(steps);
    final estimateOut =
        await sub.llm('Order these steps: ' + rendered, role: 'estimator');
    final order = _parseOrder(estimateOut['text'], steps.length);
    if (order == null) {
      note('planning.critique-produced', {'accepted': false, 'iteration': iter});
      note('planning.rejected', {'iteration': iter, 'reason': 'unorderable'});
      continue;
    }

    lastKind = kind;
    lastSteps = steps;
    lastOrder = order;
    haveOrderable = true;
    note('planning.graph-estimated',
        {'stepCount': steps.length, 'edgeCount': _edgeCount(steps)});

    final evaluateOut = await sub.llm(
      'Evaluate this plan for goal: ' + goalText,
      role: 'plan_evaluator',
    );
    final accepted = _accepted(evaluateOut['text']);
    note('planning.critique-produced', {'accepted': accepted, 'iteration': iter});
    if (accepted) {
      commit = true;
      commitStatus = 'active';
      break;
    }
    note('planning.rejected', {'iteration': iter, 'reason': 'critique'});
  }

  // No accept. If an orderable graph was ever seen, commit the best effort at
  // `draft`; otherwise there is nothing to commit — fail loudly.
  if (!commit) {
    if (!haveOrderable) {
      throw StateError('plan_v1: no orderable plan graph after ' +
          maxIterations.toString() + ' iterations');
    }
    commitStatus = 'draft';
  }

  // ── Commit the chosen graph (single persist site) ──
  final summary = _summaryFor(goalText);
  final emb = await sub.embed(goalText + ' ' + summary);
  final planId = await mem.persist('Plan', {
    'goal': goal,
    'summary': summary,
    'kind': lastKind,
    'status': commitStatus,
    'confidence': 0.7,
    'created_by': 'plan_v1',
  }, producer: producer, embedding: emb['vec']);

  final stepKind = _stepKindFor(lastKind);
  final stepIds = <String>[];
  final idByLine = {};
  for (var i = 0; i < lastSteps.length; i++) {
    final desc = lastSteps[i]['description'].toString();
    final stepId = await mem.persist('PlanStep', {
      'description': desc,
      'plan_id': planId,
      'step_index': _orderIndexOf(lastOrder, i + 1, i),
      'kind': stepKind,
      'status': 'pending',
      'success_criterion': 'Done when: ' + desc,
    }, producer: producer);
    stepIds.add(stepId);
    idByLine[i + 1] = stepId;
    await mem.edge(stepId, 'part_of', planId, producer: producer);
  }
  await _wireDependencies(mem, lastSteps, idByLine, producer);

  note('planning.accepted', {'planId': planId, 'stepCount': lastSteps.length});

  final produced = <String>[];
  produced.add(planId);
  for (var i = 0; i < stepIds.length; i++) {
    produced.add(stepIds[i]);
  }
  return {'plan': planId, 'status': commitStatus, 'producedNodeIds': produced};
}

/// Draws the `part_of[kind=depends_on]` dependency edges for [steps], oriented
/// `dependent → dependency` (§ 5.3). [memory] is the injected `mem` bridge,
/// passed in rather than referenced as a global so this helper does not depend
/// on global resolution inside a top-level function. [idByLine] maps a 1-based
/// step line to its persisted id; dependency markers naming an unknown line are
/// skipped. Shared by the initial commit and the re-plan path.
Future<void> _wireDependencies(
    memory, List steps, Map idByLine, String producer) async {
  for (var i = 0; i < steps.length; i++) {
    final deps = steps[i]['deps'];
    if (deps is List) {
      for (var di = 0; di < deps.length; di++) {
        final depId = idByLine[deps[di]];
        if (depId != null) {
          await memory.edge(idByLine[i + 1], 'part_of', depId,
              producer: producer, attrs: {'kind': 'depends_on'});
        }
      }
    }
  }
}

/// Maps the `planner` role's free text to a PlanKind token (creation / research
/// / decision / composite), defaulting to `composite` when none is named.
String _parseKind(Object? raw) {
  final s = raw is String ? raw.toLowerCase() : '';
  if (s.contains('creation')) return 'creation';
  if (s.contains('research')) return 'research';
  if (s.contains('decision')) return 'decision';
  return 'composite';
}

/// Parses the `decomposer` role's one-step-per-line output into a list of
/// `{description, deps}` maps. A trailing ` <- n,m` marks 1-based dependencies;
/// a leading list number (`1.` / `1)`) is stripped from the description.
List _parseSteps(Object? raw) {
  final out = [];
  final s = raw is String ? raw : '';
  final lines = s.split('\n');
  for (var li = 0; li < lines.length; li++) {
    var line = lines[li].trim();
    if (line.isEmpty) continue;
    final deps = <int>[];
    final marker = line.indexOf('<-');
    if (marker >= 0) {
      final depPart = line.substring(marker + 2).trim();
      line = line.substring(0, marker).trim();
      final parts = depPart.split(',');
      for (var pi = 0; pi < parts.length; pi++) {
        final n = int.tryParse(parts[pi].trim());
        if (n != null) deps.add(n);
      }
    }
    line = _stripLeadingNumber(line);
    if (line.isEmpty) continue;
    out.add({'description': line, 'deps': deps});
  }
  return out;
}

/// Strips a leading `1.` / `1)` list marker from [line], leaving the prose.
String _stripLeadingNumber(String line) {
  var i = 0;
  while (i < line.length && _isDigit(line.substring(i, i + 1))) {
    i++;
  }
  if (i == 0) return line;
  if (i < line.length) {
    final sep = line.substring(i, i + 1);
    if (sep == '.' || sep == ')') {
      return line.substring(i + 1).trim();
    }
  }
  return line;
}

/// Whether [c] is a single ASCII digit.
bool _isDigit(String c) =>
    c == '0' ||
    c == '1' ||
    c == '2' ||
    c == '3' ||
    c == '4' ||
    c == '5' ||
    c == '6' ||
    c == '7' ||
    c == '8' ||
    c == '9';

/// Parses the `estimator` role's order line (comma-separated 1-based indices)
/// into a deduplicated, in-bounds order. Returns null when the estimator flags
/// a `cycle` or yields no usable index — an unorderable graph the loop rejects.
List? _parseOrder(Object? raw, int stepCount) {
  final s = raw is String ? raw : '';
  final lines = s.split('\n');
  var first = '';
  for (var li = 0; li < lines.length; li++) {
    final t = lines[li].trim();
    if (t.isNotEmpty) {
      first = t;
      break;
    }
  }
  if (first.isEmpty) return null;
  if (first.toLowerCase().contains('cycle')) return null;
  final parts = first.split(',');
  final order = <int>[];
  for (var pi = 0; pi < parts.length; pi++) {
    final n = int.tryParse(parts[pi].trim());
    if (n == null) continue;
    if (n < 1 || n > stepCount) continue;
    if (!order.contains(n)) order.add(n);
  }
  if (order.isEmpty) return null;
  return order;
}

/// Whether the `plan_evaluator` verdict accepts the plan (`accept` and not
/// `revise`).
bool _accepted(Object? raw) {
  final s = raw is String ? raw.toLowerCase() : '';
  return s.contains('accept') && !s.contains('revise');
}

/// The leaf-step kind for a plan of [planKind] (§ 4.3): a creation plan's steps
/// are `create`, a research plan's `research`, a decision plan's `decide`, and
/// a composite plan's `think`.
String _stepKindFor(String planKind) {
  if (planKind == 'creation') return 'create';
  if (planKind == 'research') return 'research';
  if (planKind == 'decision') return 'decide';
  return 'think';
}

/// Renders [steps] as a 1-based numbered list for the estimator prompt.
String _renderSteps(List steps) {
  var out = '';
  for (var i = 0; i < steps.length; i++) {
    out = out + (i + 1).toString() + '. ' + steps[i]['description'].toString();
    out = out + '\n';
  }
  return out;
}

/// The total number of dependency edges across [steps] (for the estimated-graph
/// trail note).
int _edgeCount(List steps) {
  var c = 0;
  for (var i = 0; i < steps.length; i++) {
    final deps = steps[i]['deps'];
    if (deps is List) c = c + deps.length;
  }
  return c;
}

/// The position of 1-based [line] in [order], or [fallback] when [order] does
/// not mention it.
int _orderIndexOf(List order, int line, int fallback) {
  final idx = order.indexOf(line);
  return idx >= 0 ? idx : fallback;
}

/// The `supersedes:` ids the `re_planner` named — the steps the revision
/// replaces (§ 4.7).
List _parseSupersedes(String text) {
  final out = [];
  final lines = text.split('\n');
  for (var li = 0; li < lines.length; li++) {
    final line = lines[li].trim();
    if (line.toLowerCase().startsWith('supersedes:')) {
      final colon = line.indexOf(':');
      final parts = line.substring(colon + 1).split(',');
      for (var pi = 0; pi < parts.length; pi++) {
        final id = parts[pi].trim();
        if (id.isNotEmpty) out.add(id);
      }
    }
  }
  return out;
}

/// [text] with any `supersedes:` line removed, leaving only the replacement
/// step lines for `_parseSteps`.
String _stripSupersedesLine(String text) {
  final lines = text.split('\n');
  var out = '';
  for (var li = 0; li < lines.length; li++) {
    if (lines[li].trim().toLowerCase().startsWith('supersedes:')) continue;
    out = out + lines[li] + '\n';
  }
  return out;
}

/// A short plan summary derived from the goal.
String _summaryFor(String goal) => 'Plan for: ' + goal;
