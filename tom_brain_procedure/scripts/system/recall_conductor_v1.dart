/// @procedure
/// id: recall_conductor_v1
/// version: 1
/// summary: Agentic pre-answer recall curation (memory § 6.7). Seeds a
///   recency-boosted, read-only recall, lets the cheap local LLM judge
///   sufficiency and re-search via the typed recall variants, and returns a
///   small curated id set with a one-line per-node rationale under a hard
///   volume + tool-call + round budget. Degrades to the seed recall when the
///   budget is spent or the local route is unavailable.
/// successCriterion: returns a curated id set no larger than volumeCap, drawn
///   only from nodes the loop surfaced, each carrying a rationale; every recall
///   the conductor issues runs read-only (countsAsAccess:false); on a failed
///   conductor call or an exhausted budget the result degrades to the
///   volume-capped seed recall with `degraded:true`.
/// budget: { wallClockMs: 86400000, tokenSpend: 100000000, toolCalls: 800, memoryWrites: 1000000 }
/// inputs:
///   - { name: text, type: String, required: true }
///   - { name: seedK, type: int, required: false }
///   - { name: searchK, type: int, required: false }
///   - { name: volumeCap, type: int, required: false }
///   - { name: maxRounds, type: int, required: false }
///   - { name: maxSearches, type: int, required: false }
///   - { name: conductorPromptId, type: String, required: false }
/// outputs:
///   - { name: curatedIds, type: List }
///   - { name: rationale, type: Map }
///   - { name: degraded, type: bool }
///   - { name: searches, type: int }
/// requires: [ recall, recallOld, recallCold, recallPrompts, recallAnswers, recallMulti, run, runProcedure, note ]
//
// recall_conductor_v1 — the agentic pre-answer recall loop (memory § 6.7).
//
// ── What it is (and is NOT) ──────────────────────────────────────────
//
// This is the *cheap-LLM* curation loop that runs *before* the answer step:
// it surfaces candidate memory, asks the cheap local route whether what it has
// is enough, lets it re-search the cold/old/prompt/answer corners the default
// ranking buries, and hands back a *small, deliberately curated* id set with a
// one-line rationale per node. It does not produce the answer and it does not
// touch the corpus — the answer layer (§ 16, separate todo) consumes the
// curated set and is the only place a used node is marked. So this body never
// promotes or demotes (mem.promote is answer-only by intent, § 6.6).
//
// It is distinct from `retrieve_for_prompt_v1` (the § 23.2 retrieval
// conductor — a non-LLM BM25/symbolic pass fused with the `recall_*`
// sub-procedures). That one *fuses* seeds; this one *judges sufficiency* and
// *curates*. Different procedures, different role.
//
// ── Read-only invariant (§ 6.7) ──────────────────────────────────────
//
// Every recall the conductor issues is an inspection, not a use: the seed
// `mem.recall` passes `countsAsAccess: false` explicitly, and the typed
// re-search variants (`recallOld` / `recallCold` / `recallPrompts` /
// `recallAnswers` / `recallMulti`) are structurally read-only — none exposes a
// countsAsAccess knob, so none can perturb the recency / frequency signal the
// decay pass later reads. Curation must not warm the memory it inspects;
// only the answer layer's accepted use does that.
//
// ── How the LLM talks to this d4rt body ───────────────────────────────
//
// The sandbox does not import `dart:convert`, so the conductor LLM cannot
// reply in JSON the body parses. Instead the conductor prompt
// (`conductorPromptId`, default `assist_user.recall_conductor.curate`, owned
// by § 16) is asked to answer in a line directive format the body parses with
// plain String ops, exactly as `prompt_analyzer_v1` parses its verdict token:
//
//   SUFFICIENT: yes|no            (informational; KEEP/SEARCH drive the loop)
//   SEARCH: <kind> <query>        kind ∈ old|cold|prompts|answers|multi|recall
//   KEEP: <nodeId> | <rationale>
//
// A KEEP block ends the loop and curates; a SEARCH block runs the named
// re-searches (within budget) and re-enters; anything else ends the loop and
// degrades to the seed set.
//
// ── Budget + degrade (§ 6.7) ──────────────────────────────────────────
//
// Three hard caps bound the loop: `maxRounds` LLM turns, `maxSearches` total
// re-search tool calls, and `volumeCap` curated ids. When the conductor call
// throws (the local route is unavailable) or the loop produces no keeps, the
// body degrades to the volume-capped seed recall and flags `degraded: true` —
// a curated set is always returned, never an exception.
import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure/src/bridges/memory_bridge.dart';
import 'package:tom_brain_procedure/src/bridges/substrate_bridge.dart';
import 'package:tom_brain_procedure/src/primitives_native/primitives_native.dart';

Future<Map<String, Object?>> run(ProcedureInputs inputs) async {
  final text = inputs.get<String>('text');

  // Inline policy with config-supplied overrides — the cheap-LLM loop's caps.
  final seedK = _intArg(inputs, 'seedK', 8);
  final searchK = _intArg(inputs, 'searchK', 8);
  final volumeCap = _intArg(inputs, 'volumeCap', 8);
  final maxRounds = _intArg(inputs, 'maxRounds', 2);
  final maxSearches = _intArg(inputs, 'maxSearches', 4);
  final conductorPromptId =
      _strArg(inputs, 'conductorPromptId', 'assist_user.recall_conductor.curate');

  // Seed: recency-boosted, read-only. recencyBoosted surfaces what is fresh
  // (the loop reaches the cold/old corners on demand via re-search);
  // countsAsAccess:false keeps the inspection from warming the recency signal.
  final seed = await mem.recall(
    text,
    modes: <String>['bm25', 'vector'],
    k: seedK,
    ranking: 'recencyBoosted',
    countsAsAccess: false,
  );

  // The de-duped, insertion-ordered catalogue of everything surfaced so far —
  // the seed plus every re-search hit. `summaries` is the id → one-line digest
  // the LLM judges and KEEP rationales attach to; iterating `surfacedIds`
  // fixes a stable order for the catalogue and the degrade fallback.
  final surfacedIds = <String>[];
  final summaries = <String, String>{};
  _absorb(seed['nodes'], surfacedIds, summaries);

  final curatedIds = <String>[];
  final rationale = <String, String>{};
  var degraded = false;
  var searches = 0;

  // A `for` loop over the round budget — d4rt supports `break` inside `for`
  // (the decay/prune agents rely on it) but not inside `while`, so the
  // sufficiency loop is bounded by the loop counter, not a `while` guard.
  for (var round = 1; round <= maxRounds; round++) {
    // Render the surfaced catalogue for the conductor to judge.
    var catalogue = '';
    for (final id in surfacedIds) {
      catalogue += '$id :: ${summaries[id]}\n';
    }

    // Ask the cheap local route whether this is enough / what else to fetch.
    // A failed call (local route unavailable) degrades to the seed set.
    var verdictText = '';
    var failed = false;
    try {
      final completion = await sub.run(
        conductorPromptId,
        inputs: <String, Object?>{
          'prompt': text,
          'surfaced': catalogue,
          'round': round,
        },
      );
      final answer = completion['answer'];
      verdictText = answer is String ? answer : '';
    } on Object catch (_) {
      failed = true;
    }
    if (failed) {
      degraded = true;
      break;
    }

    // Parse the line directives (plain String ops — no JSON in the sandbox).
    final keepLines = <String>[];
    final searchLines = <String>[];
    for (final raw in verdictText.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final lower = line.toLowerCase();
      if (lower.startsWith('keep:')) {
        keepLines.add(line.substring(5).trim());
      } else if (lower.startsWith('search:')) {
        searchLines.add(line.substring(7).trim());
      }
    }

    // A KEEP block ends the loop: curate the named ids (those the loop
    // actually surfaced), de-duped and capped at the volume budget.
    if (keepLines.isNotEmpty) {
      for (final keep in keepLines) {
        if (curatedIds.length >= volumeCap) break;
        final bar = keep.indexOf('|');
        final id = (bar >= 0 ? keep.substring(0, bar) : keep).trim();
        final why = bar >= 0 ? keep.substring(bar + 1).trim() : '';
        if (id.isEmpty) continue;
        if (!summaries.containsKey(id)) continue; // only surfaced ids curate
        if (rationale.containsKey(id)) continue; // de-dup
        curatedIds.add(id);
        rationale[id] = why;
      }
      break;
    }

    // No keeps and no searches → nothing more to do; degrade below.
    if (searchLines.isEmpty) break;

    // Run the requested re-searches (within the tool-call budget), merging
    // every hit into the surfaced catalogue for the next round to judge.
    var ranAny = false;
    for (final spec in searchLines) {
      if (searches >= maxSearches) break;
      final sp = spec.indexOf(' ');
      final kind = (sp >= 0 ? spec.substring(0, sp) : spec).trim().toLowerCase();
      final query = sp >= 0 ? spec.substring(sp + 1).trim() : text;
      if (query.isEmpty) continue;
      searches++;
      ranAny = true;

      // Every variant here is structurally read-only (no countsAsAccess knob);
      // the plain `recall` fallback passes countsAsAccess:false explicitly.
      Map<String, Object?> res = const <String, Object?>{};
      if (kind == 'old') {
        res = await mem.recallOld(query, k: searchK);
      } else if (kind == 'cold') {
        res = await mem.recallCold(query, k: searchK);
      } else if (kind == 'prompts') {
        res = await mem.recallPrompts(query, k: searchK);
      } else if (kind == 'answers') {
        res = await mem.recallAnswers(query, k: searchK);
      } else if (kind == 'multi') {
        res = await mem.recallMulti(
          <Object?>[
            <String, Object?>{'mode': 'bm25', 'text': query},
            <String, Object?>{'mode': 'vector', 'text': query},
          ],
          k: searchK,
        );
      } else {
        res = await mem.recall(query, k: searchK, countsAsAccess: false);
      }
      _absorb(res['nodes'], surfacedIds, summaries);
    }
    if (!ranAny) break;
  }

  // Degrade: a spent budget or a no-keep loop falls back to the seed recall,
  // volume-capped. A curated set is always returned (§ 6.7).
  if (curatedIds.isEmpty) {
    degraded = true;
    for (final id in surfacedIds) {
      if (curatedIds.length >= volumeCap) break;
      curatedIds.add(id);
      rationale[id] = 'seed recall (conductor degraded)';
    }
  }

  note('progress', {
    'agent': 'recall_conductor_v1',
    'curated': curatedIds.length,
    'searches': searches,
    'degraded': degraded,
  });

  return <String, Object?>{
    'curatedIds': curatedIds,
    'rationale': rationale,
    'degraded': degraded,
    'searches': searches,
  };
}

/// Merges every node in [nodes] into the surfaced catalogue, preserving
/// insertion order in [surfacedIds] and de-duping by id. A non-list, a
/// non-map entry, or a node without a String id is skipped.
void _absorb(
  Object? nodes,
  List<String> surfacedIds,
  Map<String, String> summaries,
) {
  if (nodes is! List) return;
  for (final node in nodes) {
    if (node is! Map) continue;
    final id = node['id'];
    if (id is! String) continue;
    if (summaries.containsKey(id)) continue;
    surfacedIds.add(id);
    summaries[id] = _summaryOf(node);
  }
}

/// One-line digest of a node for the conductor catalogue: the first present
/// of the common content fields, else the type name.
String _summaryOf(Map node) {
  final values = node['values'];
  if (values is Map) {
    final s = values['summary'] ??
        values['statement'] ??
        values['text'] ??
        values['title'];
    if (s is String && s.isNotEmpty) return s;
  }
  final typeName = node['typeName'];
  return typeName is String ? typeName : 'node';
}

/// Reads an int-valued input named [name], or [fallback] when absent /
/// non-numeric — the inline policy is robust to a missing override.
int _intArg(ProcedureInputs inputs, String name, int fallback) {
  if (!inputs.has(name)) return fallback;
  final v = inputs.get(name);
  return v is num ? v.toInt() : fallback;
}

/// Reads a non-empty String-valued input named [name], or [fallback].
String _strArg(ProcedureInputs inputs, String name, String fallback) {
  if (!inputs.has(name)) return fallback;
  final v = inputs.get(name);
  return v is String && v.isNotEmpty ? v : fallback;
}
