// Fixture procedure script for the PT-3.1 `GET /api/procedures/<id>` endpoint
// test (and a realistic correlation target for the PT-3.2 web tests). Not
// executed — only served verbatim by the Trail Read API, so its body just needs
// to be a recognisable, stable string shaped like a real
// `scripts/system/<id>.dart`: a `/// @procedure` header + a body that calls the
// bridged primitive acts the trail records by name (`embed`, `llm`, `persist`,
// `edge`) and dispatches a sub-procedure (`retrieve_for_prompt_v1`).

/// @procedure
/// id: answer_with_memory_v1
/// version: 1
Future<void> main() async {
  final hits = await runProcedure('retrieve_for_prompt_v1', {'prompt': prompt});
  final vector = await sub.embed(prompt);
  final answer = await llm(hits, vector);
  final node = await mem.persist(answer);
  await mem.edge(node);
}
