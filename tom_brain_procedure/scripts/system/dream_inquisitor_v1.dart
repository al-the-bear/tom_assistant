/// @procedure
/// id: dream_inquisitor_v1
/// version: 1
/// summary: Raise open Questions from recalled Claims and queue them.
/// successCriterion: For the recalled Claims, a Question node is persisted (its
///   text embedded) and pushed onto the questions_open stack, and the persisted
///   Question ids are returned.
/// budget: { wallClockMs: 86400000, tokenSpend: 100000000, toolCalls: 800, memoryWrites: 1000000 }
/// inputs:
///   - { name: source, type: String, required: true }
/// outputs:
///   - { name: questionIds, type: List }
/// requires: [ recall, llm, embed, persist, stack.push, note ]
//
// dream_inquisitor_v1 — the Inquisitor cognitive agent (memory § 9, the eight
// dreaming agents; `prototype_implementation_plan_2.md` item 22).
//
// Where the Extractor turns episodes into Claims and the Synthesiser folds
// Claims into Conclusions, the Inquisitor reads the recalled Claims and asks
// what the knowledge is *missing*: it hands them to the substrate (role
// `inquisitor`), which surfaces the open question the body of knowledge does
// not yet answer. That question becomes a `Question` node and is pushed onto
// the bootstrap `questions_open` stack — the brain's backlog of things it has
// noticed it does not know, which the Researcher later picks up.
//
// ── Scope (memory § 9.5) ────────────────────────────────────────────
//
// The engine binds this agent's identity onto the memory bridge, so every
// write carries it and the store's `AgentRegistry` confines the run to its
// declared write scopes — `node:Question` and `stack:questions_open`. A write
// to any other node type, or a push onto any other stack, is rejected with
// `AgentScopeViolation` before the row is written.
//
// ── Why the Question is embedded here ───────────────────────────────
//
// The bootstrap `Question` type embeds its `text`; the store stores the vector
// the writer supplies rather than embedding lazily, so the body computes the
// embedding through `sub.embed` and hands it to `persist`, keeping the Question
// immediately recallable.
import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure/src/bridges/memory_bridge.dart';
import 'package:tom_brain_procedure/src/bridges/substrate_bridge.dart';
import 'package:tom_brain_procedure/src/primitives_native/primitives_native.dart';

Future<Map<String, Object?>> run(ProcedureInputs inputs) async {
  final source = inputs.get('source');

  // 1. Recall the Claims to interrogate.
  final recall = await mem.recall(source, modes: ['bm25', 'vector'], k: 32);
  final statements = <String>[];
  final nodes = recall['nodes'];
  if (nodes is List) {
    for (final node in nodes) {
      if (node is Map && node['typeName'] == 'Claim') {
        final values = node['values'];
        if (values is Map) {
          final statement = values['statement'];
          if (statement is String) statements.add(statement);
        }
      }
    }
  }

  // Nothing recalled — no Claims to question. Return empty rather than raising
  // a context-free Question.
  if (statements.isEmpty) {
    note('progress', {'agent': 'dream_inquisitor_v1', 'questions': 0});
    return <String, Object?>{'questionIds': <String>[]};
  }

  // 2. Ask the substrate (role `inquisitor`) for the open question these Claims
  //    leave unanswered. The body supplies only the role id and the joined
  //    statements as the role-template prompt (PE-7 — never a raw wire prompt).
  const producer = 'dream_inquisitor_v1';
  final completion = await sub.llm(
    'Given these recorded claims, what open question do they leave '
    'unanswered? ${statements.join(" | ")}',
    role: 'inquisitor',
  );
  final text = completion['text'];

  // 3. Persist the Question (embedded) and queue it on questions_open.
  final embedding = await sub.embed('$text');
  final questionId = await mem.persist(
    'Question',
    {'text': text},
    producer: producer,
    embedding: embedding['vec'],
  );
  await mem.stackPush('questions_open', questionId, producer: producer);

  note('progress', {'agent': 'dream_inquisitor_v1', 'questions': 1});

  // The Question carries no `produced_by` outgoing edge in the bootstrap
  // schema, so it is *not* returned as a produced node (that would fail with
  // EdgeNotPermitted); the id is returned as the run's structured output only.
  return <String, Object?>{
    'questionIds': [questionId],
  };
}
