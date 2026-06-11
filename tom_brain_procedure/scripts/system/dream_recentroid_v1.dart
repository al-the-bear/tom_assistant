/// @procedure
/// id: dream_recentroid_v1
/// version: 1
/// summary: Recompute a node-type centroid from its recalled members.
/// successCriterion: The centroid for forKey is replaced with the mean of the
///   recalled members' re-embedded text, the borderline members are surfaced
///   via findUncertain, and the uncertain count is returned.
/// budget: { wallClockMs: 86400000, tokenSpend: 100000000, toolCalls: 800, memoryWrites: 1000000 }
/// inputs:
///   - { name: source, type: String, required: true }
///   - { name: forKey, type: String, required: true }
/// outputs:
///   - { name: uncertainCount, type: int }
/// requires: [ recall, embed, updateCentroid, findUncertain, note ]
//
// dream_recentroid_v1 — the centroid-recomputation pass (memory § 7.3 / § 7.4;
// `prototype_implementation_plan_2.md` item 22). Memory never auto-recomputes
// its classification centroids — this agent is the normal-operation writer. It
// recalls the members of a node-type family (`forKey`), re-embeds each member's
// text, folds those embeddings into a fresh mean, replaces the centroid with it
// (`updateCentroid`), then surfaces the members that still sit in the uncertain
// band around the new centroid (`findUncertain`) so a later re-classification
// pass can revisit them.
//
// ── No writes, no scope (memory § 7.3) ──────────────────────────────
//
// `updateCentroid` replaces a centroid row and `findUncertain` reads the
// centroid table; neither is a graph mutation, so the store's `AgentRegistry`
// does not scope them. The agent registers with an *empty* write-scope set: it
// creates no node, draws no edge, pushes onto no stack. Recomputing a centroid
// is a maintenance act on the classifier, not a change to the knowledge graph.
//
// ── Why the embeddings come from re-embedding, not from recall ──────
//
// The prototype's recall contract deliberately does not rehydrate node
// embeddings: vectors live in `vectors.db` and the read path returns only the
// `memory.db` row (Q-A.35.1), so a recalled node's `embedding` field is always
// absent. The only path back to a member's vector is therefore to re-embed its
// text through the substrate under the same embedding model the store uses for
// that node type. The centroid is the mean of those re-embeddings — computed
// with the same model that classified the members, so it stays commensurable
// with them.
import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure/src/bridges/memory_bridge.dart';
import 'package:tom_brain_procedure/src/bridges/substrate_bridge.dart';
import 'package:tom_brain_procedure/src/primitives_native/primitives_native.dart';

Future<Map<String, Object?>> run(ProcedureInputs inputs) async {
  final source = inputs.get('source');
  final forKey = inputs.get('forKey');

  // 1. Recall the members of the family and collect their textual content.
  //    A member's text is the concatenation of its String-valued fields (a
  //    Claim's `statement`, an Event's `summary`, …) — the same text the
  //    store embeds when the node is persisted.
  final recall = await mem.recall(source, modes: ['bm25', 'vector'], k: 64);
  final texts = <String>[];
  final nodes = recall['nodes'];
  if (nodes is List) {
    for (final node in nodes) {
      if (node is Map && node['typeName'] == forKey) {
        final values = node['values'];
        if (values is Map) {
          final parts = <String>[];
          final keys = values.keys.map((k) => '$k').toList()..sort();
          for (final key in keys) {
            final value = values[key];
            if (value is String && value.isNotEmpty) parts.add(value);
          }
          final text = parts.join(' ');
          if (text.isNotEmpty) texts.add(text);
        }
      }
    }
  }

  // No member text recalled — nothing to recompute. Leave the existing
  // centroid untouched rather than writing an empty one.
  if (texts.isEmpty) {
    note('progress', {'agent': 'dream_recentroid_v1', 'recentroided': 0});
    return <String, Object?>{'uncertainCount': 0};
  }

  // 2. Re-embed each member's text and fold the vectors into a component-wise
  //    mean.
  final vectors = <List<double>>[];
  for (final text in texts) {
    final embedded = await sub.embed(text);
    final vec = embedded['vec'];
    if (vec is List) {
      final v = <double>[];
      for (final component in vec) {
        if (component is num) v.add(component.toDouble());
      }
      if (v.isNotEmpty) vectors.add(v);
    }
  }
  if (vectors.isEmpty) {
    note('progress', {'agent': 'dream_recentroid_v1', 'recentroided': 0});
    return <String, Object?>{'uncertainCount': 0};
  }

  final dims = vectors.first.length;
  final sums = List<double>.filled(dims, 0.0);
  for (final vec in vectors) {
    for (var i = 0; i < dims && i < vec.length; i++) {
      sums[i] = sums[i] + vec[i];
    }
  }
  final mean = <double>[];
  for (var i = 0; i < dims; i++) {
    mean.add(sums[i] / vectors.length);
  }

  // 3. Replace the centroid with the fresh mean, then surface the members that
  //    still sit in the uncertain band around it (the full [0,1] window here —
  //    the prototype reports the borderline batch rather than re-classifying).
  await mem.updateCentroid('$forKey', mean);
  final uncertain =
      await mem.findUncertain('$forKey', low: 0.0, high: 1.0, limit: 200);
  final uncertainCount = uncertain is List ? uncertain.length : 0;

  note('progress', {
    'agent': 'dream_recentroid_v1',
    'members': vectors.length,
    'uncertain': uncertainCount,
  });

  // No produced nodes — recentroid maintains the classifier, it does not author
  // graph content; `producedNodeIds` is never returned.
  return <String, Object?>{
    'uncertainCount': uncertainCount,
  };
}
