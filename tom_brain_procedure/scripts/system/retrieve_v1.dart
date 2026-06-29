/// @procedure
/// id: retrieve_v1
/// version: 1
/// summary: Zero-LLM diagnostic retrieval — pure lexical (bm25) memory recall
///   returned verbatim as the answer; no embedding, no synthesis, no
///   persistence. The retrieval-mode profile selects this entry procedure.
/// successCriterion: returns the formatted recalled context under `answer`
///   (and the raw recalled nodes under `nodes`) after exactly one `mem.recall`,
///   having issued no substrate call.
/// budget: { wallClockMs: 14400000, toolCalls: 0, memoryWrites: 0 }
/// # A diagnostic read (procedure spec § 24.9 / SC-Q4): no orchestration and no
/// # synthesis. The only count dimensions available are tool calls and memory
/// # writes, both pinned to 0 (this body makes neither — `mem.recall` is a read,
/// # not a write, and runs no `tool.*`), so any tool call or memory write is a
/// # runaway-stop. There is no llmCalls dimension; "zero LLM" is enforced
/// # structurally by the absent substrate import (see below), not by a budget
/// # cap. wallClockMs is the spec's external default (§ 5.4) — the runaway-stop
/// # for a genuinely hung read, not a throttle.
/// inputs:
///   - { name: text, type: String, required: true }
/// outputs:
///   - { name: answer, type: String }
///   - { name: nodes, type: List }
/// requires: [ run ]
//
// retrieve_v1 — the zero-LLM diagnostic retrieval procedure
// (`tom_brain_procedure_specification.md` § 24.9; SC-Q4).
//
// `mode: retrieval` selects this procedure. It is the inspection counterpart of
// the answer procedures: it recalls from memory and returns *what it found*,
// raw, with no model in the loop. Its purpose is diagnostics — "show me what the
// store surfaces for this prompt" — not answering. It recalls, formats the hits
// as a plain-text block, and returns; it persists nothing and re-enters nothing.
//
// ── The zero-LLM guarantee is structural (overview principle 7) ──
//
// This body imports ONLY the two host-injected libraries it touches —
// `procedure_inputs` (so `inputs.get('text')` dispatches onto the native bag)
// and `memory_bridge` (so `mem.recall(...)` resolves). It deliberately does
// **not** import `substrate_bridge.dart`, so `sub` is never in scope and a
// `sub.*` call cannot be written. The d4rt `SandboxValidator` allow-lists
// exactly the imports a script declares (PE-1); the absent substrate import is
// what makes "retrieval issues no LLM call" a property the sandbox *enforces*
// rather than a convention the body merely honours. This mirrors, in the
// opposite direction, `passthrough_v1`'s structural no-memory guarantee (the
// relay imports the substrate bridge but not the memory bridge).
//
// ── Why bm25-only (no embedding callout, principle 11) ──
//
// `mem.recall` defaults to `modes: ['bm25', 'vector']`; the `vector` mode makes
// an embedding callout inside memory's hot path. This procedure passes
// `modes: ['bm25']` — pure FTS lexical match — so the read needs no embedding
// model at all. That keeps "zero-LLM" honest in the strongest sense (not even
// the embedding model is touched), makes the retrieval deterministic, and lets
// it survive a total substrate/embedding outage (PE-6). `countsAsAccess: false`
// keeps a diagnostic inspection from perturbing the recency/frequency signal the
// decay pass reads.
//
// ── Distinct from `retrieve_for_prompt_v1` (§ 23) ──
//
// The § 23 conductor is an LLM-augmented four-mode retrieval *system*: it spends
// substrate budget on HyDE / semantic / lexical seeds and fuses them. This is a
// profile *mode* — one cheap non-LLM recall, surfaced for inspection. The two
// share neither code nor intent; this body never delegates to the conductor.
import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure/src/bridges/memory_bridge.dart';

Future<Map<String, Object?>> run(ProcedureInputs inputs) async {
  final text = inputs.get('text');
  final queryText = text is String ? text : '';

  // The single recall: bm25 only (no embedding callout), read-only (does not
  // count as access), capped at a generous diagnostic window.
  final result = await mem.recall(
    queryText,
    modes: const <String>['bm25'],
    k: 16,
    countsAsAccess: false,
  );

  final rawNodes = result['nodes'];
  final nodes = rawNodes is List ? rawNodes : const <Object?>[];

  return <String, Object?>{
    'answer': _formatNodes(queryText, nodes),
    'nodes': nodes,
  };
}

/// Renders the recalled [nodes] as a plain-text diagnostic block — the raw
/// retrieval surface, one line per hit, no synthesis. An empty recall yields an
/// explicit "no matches" line so the caller can tell "nothing matched" apart
/// from a failure.
String _formatNodes(String queryText, List nodes) {
  final buffer = StringBuffer()
    ..write('Retrieved ')
    ..write(nodes.length)
    ..write(nodes.length == 1 ? ' memory for: ' : ' memories for: ')
    ..writeln(queryText);
  if (nodes.isEmpty) {
    buffer.writeln('(no matches)');
    return buffer.toString();
  }
  for (var i = 0; i < nodes.length; i++) {
    final node = nodes[i];
    final map = node is Map ? node : const <Object?, Object?>{};
    final typeName = map['typeName'];
    buffer
      ..write(i + 1)
      ..write('. [')
      ..write(typeName is String ? typeName : 'node')
      ..write('] ')
      ..writeln(_summaryOf(map));
  }
  return buffer.toString();
}

/// The best human-readable one-liner for a recalled node map — its `summary` /
/// `statement` / `text` / `title` value, falling back to the type name. Mirrors
/// `recall_conductor_v1`'s `_summaryOf` so the two retrieval surfaces describe a
/// node identically.
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
