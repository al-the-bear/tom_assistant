/// @procedure
/// id: dream_repetition_detect_v1
/// version: 1
/// summary: Spot a recurring Pattern in recalled Events and queue an idea.
/// successCriterion: A Pattern node summarising the recurrence is persisted
///   (embedded), an AutomationIdea is persisted (embedded) and pushed onto the
///   automation_ideas stack, and both ids are returned.
/// budget: { wallClockMs: 86400000, tokenSpend: 100000000, toolCalls: 800, memoryWrites: 1000000 }
/// inputs:
///   - { name: source, type: String, required: true }
/// outputs:
///   - { name: patternId, type: String }
///   - { name: ideaId, type: String }
/// requires: [ recall, llm, embed, persist, stack.push, note ]
//
// dream_repetition_detect_v1 — the Repetition-detector cognitive agent (memory
// § 9, the eight dreaming agents; `prototype_implementation_plan_2.md` item
// 22).
//
// This agent watches episodic memory for things that keep happening: it reads
// the recalled Events, asks the substrate (role `repetition_detector`) to name
// the recurring activity, records it as a `Pattern` node, and turns that
// pattern into a candidate `AutomationIdea` queued on the bootstrap
// `automation_ideas` stack — the brain's backlog of "this repeats, maybe it
// should be automated", which a later planning pass picks up.
//
// ── Scope (memory § 9.5) ────────────────────────────────────────────
//
// The engine binds this agent's identity onto the memory bridge, so every
// write carries it and the store's `AgentRegistry` confines the run to its
// declared write scopes — `node:Pattern`, `node:AutomationIdea`, and
// `stack:automation_ideas`. A write outside that set is rejected with
// `AgentScopeViolation` before the row is written.
//
// ── Why each node is embedded here ──────────────────────────────────
//
// The bootstrap `Pattern` and `AutomationIdea` types embed their text fields;
// the store stores the vector the writer supplies rather than embedding lazily,
// so the body computes each embedding through `sub.embed` and hands it to
// `persist`.
import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure/src/bridges/memory_bridge.dart';
import 'package:tom_brain_procedure/src/bridges/substrate_bridge.dart';
import 'package:tom_brain_procedure/src/primitives_native/primitives_native.dart';

Future<Map<String, Object?>> run(ProcedureInputs inputs) async {
  final source = inputs.get('source');

  // 1. Recall the episodic Events to scan for repetition.
  final recall = await mem.recall(source, modes: ['bm25', 'vector'], k: 32);
  final summaries = <String>[];
  final nodes = recall['nodes'];
  if (nodes is List) {
    for (final node in nodes) {
      if (node is Map && node['typeName'] == 'Event') {
        final values = node['values'];
        if (values is Map) {
          final summary = values['summary'];
          if (summary is String) summaries.add(summary);
        }
      }
    }
  }

  // Repetition needs at least two events to recur across. With fewer there is
  // nothing to detect.
  if (summaries.length < 2) {
    note('progress', {'agent': 'dream_repetition_detect_v1', 'patterns': 0});
    return <String, Object?>{'patternId': null, 'ideaId': null};
  }

  // 2. Name the recurring activity. The body supplies only the role id and the
  //    joined summaries as the role-template prompt (PE-7 — never a raw wire
  //    prompt).
  const producer = 'dream_repetition_detect_v1';
  final completion = await sub.llm(
    'These recorded events may describe a recurring activity. Name the '
    'repeating pattern: ${summaries.join(" | ")}',
    role: 'repetition_detector',
  );
  final description = completion['text'];

  // 3. Record the Pattern (embedded).
  final patternEmbedding = await sub.embed('$source $description');
  final patternId = await mem.persist(
    'Pattern',
    {'signature': '$source', 'description': description},
    producer: producer,
    embedding: patternEmbedding['vec'],
  );

  // 4. Turn the Pattern into a candidate AutomationIdea (embedded) and queue it.
  final motivation = 'Observed repeating across ${summaries.length} events.';
  final ideaEmbedding = await sub.embed('$description $motivation');
  final ideaId = await mem.persist(
    'AutomationIdea',
    {'description': description, 'motivation': motivation},
    producer: producer,
    embedding: ideaEmbedding['vec'],
  );
  await mem.stackPush('automation_ideas', ideaId, producer: producer);

  note('progress', {
    'agent': 'dream_repetition_detect_v1',
    'patterns': 1,
    'ideas': 1,
  });

  // Neither Pattern nor AutomationIdea carries a `produced_by` outgoing edge in
  // the bootstrap schema, so neither is returned as a produced node (that would
  // fail with EdgeNotPermitted); the ids are the run's structured output only.
  return <String, Object?>{
    'patternId': patternId,
    'ideaId': ideaId,
  };
}
