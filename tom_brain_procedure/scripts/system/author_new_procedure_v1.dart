/// @procedure
/// id: author_new_procedure_v1
/// version: 1
/// summary: Author a new procedure for an intent — draft, validate, critique,
///   and persist it as a Procedure node.
/// successCriterion: A Procedure node is persisted carrying the validated draft
///   source and its lifecycle status, and (on a valid, critic-gated draft) its
///   id is returned and produced.
/// budget: { wallClockMs: 120000, tokenSpend: 20000, toolCalls: 16, memoryWrites: 8 }
/// inputs:
///   - { name: intent, type: String, required: true }
///   - { name: predecessor, type: String, required: false }
///   - { name: revision, type: int, required: false }
/// outputs:
///   - { name: procedure, type: String }
///   - { name: status, type: String }
/// requires: [ recall, llm, embed, validate, persist, edge, note ]
//
// author_new_procedure_v1 — the authoring loop (the brain writing its own
// procedures), itself a fixed root procedure (`procedure_specification.md`
// § 8.3, Todo 7 / G-PR1). A *dedicated, separate* procedure — not folded into
// `create_v1` (revised C-3): valid structured-header emission, bridged-API
// subset selection, validator satisfaction, and lifecycle registration are
// specific enough to need their own prompt scaffolding (`procedure_author`,
// `procedure_critic`) and their own loop.
//
// ── The loop (§ 8.3) ────────────────────────────────────────────────
//
//   1. Recall past procedures as drafting context — recall is the only read.
//   2. Draft with the `procedure_author` role; the LLM's *text is the candidate
//      d4rt source* (PE-7: the body supplies role + inputs, never a wire
//      prompt).
//   3. Validate the draft deterministically through the engine-native
//      `validate(source)` (LLM-free, never executes the candidate, § 9.4) and
//      re-draft once against the findings on failure.
//   4. If still invalid, register the work at `authored` (never lose it) and
//      throw — a script signals failure by throwing, so the run closes loudly
//      `errored` carrying the findings rather than silently dropping the draft.
//   5. Critique the valid draft with the `procedure_critic` role: `accept`
//      stamps `draft`, anything else (`revise …`) stamps `authored` (recorded
//      but not greenlit to run).
//   6. Persist the `Procedure` node. Its `name` / `summary` / `requires` come
//      from the parsed header the validator surfaced — the validator is the one
//      parser, so the node never disagrees with a second one. A revision links
//      to its predecessor with a `superseded_by` edge (structural, never
//      destructive — umbrella overview hard principle 6).
//
// ── Scope (memory § 9.5) ────────────────────────────────────────────
//
// The engine binds this run's identity onto the memory bridge; against the live
// store the `AgentRegistry` must grant it `node:Procedure`, `edge:superseded_by`
// and `edge:produced_by`. The bootstrap revision is human-authored (it cannot
// author itself); later revisions can be authored by the brain calling this
// version.
import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure/src/bridges/memory_bridge.dart';
import 'package:tom_brain_procedure/src/bridges/substrate_bridge.dart';
import 'package:tom_brain_procedure/src/primitives_native/primitives_native.dart';

Future<Map<String, Object?>> run(ProcedureInputs inputs) async {
  const producer = 'author_new_procedure_v1';
  final intent = inputs.get('intent');
  final predecessor = inputs.getOrNull('predecessor');
  final revisionInput = inputs.getOrNull('revision');
  final revision = revisionInput is int ? revisionInput : 1;

  // 1. Look at past procedures as starting points (recall is the only read).
  //    The hits are drafting context; the draft text is what matters next.
  await mem.recall(intent, modes: ['bm25', 'vector'], k: 8);

  // 2. Draft. The procedure_author role's prompt carries the authoring brief;
  //    its returned text is the candidate procedure's d4rt source.
  var draft = await sub.llm(
    'Draft a procedure for: $intent',
    role: 'procedure_author',
  );
  var source = draft['text'];

  // 3. Deterministic, LLM-free validation. Re-draft once against the findings.
  var validation = await validate(source);
  if (validation['ok'] != true) {
    draft = await sub.llm(
      'Fix these validation findings: ${validation['findings']}',
      role: 'procedure_author',
    );
    source = draft['text'];
    validation = await validate(source);
  }

  // The validator already parsed the header to run its header-dependent checks;
  // it hands the facts back so this loop does not need a second parser. Fall
  // back to the intent when the header itself was unparseable.
  final header = validation['header'];
  final name = _headerString(header, 'id', intent);
  final summary = _headerString(header, 'summary', intent);
  final requires = header is Map && header['requires'] is List
      ? header['requires']
      : <String>[];

  final embedding = await sub.embed('$name $summary');
  final valid = validation['ok'] == true;

  // 5. Critique the (valid) draft. `accept` greenlights it to `draft`; any
  //    other verdict records it at `authored` (not yet trusted to run).
  var status = 'authored';
  if (valid) {
    final critique = await sub.llm(
      'Critique this procedure draft against the intent: $intent',
      role: 'procedure_critic',
    );
    final verdict = critique['text'];
    final lower = verdict is String ? verdict.toLowerCase() : '';
    final accepted = lower.contains('accept') && !lower.contains('revise');
    status = accepted ? 'draft' : 'authored';
  }

  // 6. Persist the Procedure node. This happens for the invalid case too, so
  //    the work is never lost — the loud failure below still leaves a record.
  final nodeId = await mem.persist(
    'Procedure',
    {
      'name': name,
      'summary': summary,
      'code': source,
      'status': status,
      'revision': revision,
      'requires': requires,
    },
    producer: producer,
    embedding: embedding['vec'],
  );

  // A new revision links back to its predecessor — structural (superseded_by),
  // never destructive (hard principle 6).
  if (predecessor != null) {
    await mem.edge(predecessor, 'superseded_by', nodeId, producer: producer);
  }

  note('progress', {
    'procedure': 'author_new_procedure_v1',
    'status': status,
    'valid': valid,
  });

  // 4. Loud failure: the body could not be made valid. The node was registered
  //    at `authored` above (work preserved); the throw closes the run `errored`
  //    with the findings so the caller sees why.
  if (!valid) {
    throw StateError(
      'author_new_procedure_v1: draft did not validate: '
      '${validation['findings']}',
    );
  }

  // The new Procedure is this run's produced node — the engine threads it into
  // the recorder's `produced_by` edge.
  return <String, Object?>{
    'procedure': nodeId,
    'status': status,
    'producedNodeIds': [nodeId],
  };
}

/// Reads a String field [key] from the validator-parsed [header], or [fallback]
/// when the header was unparseable or the field is absent / non-String. The
/// intent-fallback policy for the persisted node's identity fields lives here,
/// in one place, rather than being repeated per field.
String _headerString(Object? header, String key, String fallback) {
  if (header is Map && header[key] is String) return header[key] as String;
  return fallback;
}
