/// @procedure
/// id: restructure_tree_v1
/// version: 1
/// summary: The checkpointed schema re-migration pass — reclassify the
///   candidates of each queued migration into their new node type, gradually,
///   within a per-pass budget, never deleting the originals.
/// successCriterion: For each migration descriptor on the restructure_backlog
///   stack, up to maxNodes candidate nodes that now classify confidently into
///   the descriptor's targetType are reclassified (a new node persisted, edged
///   derived_from the original, the original demoted migrationArchive); a
///   descriptor whose pass reclassifies nothing is removed from the backlog; the
///   reclassified count, reviewed count, and remaining backlog size are returned.
/// budget: { wallClockMs: 86400000, tokenSpend: 100000000, toolCalls: 800, memoryWrites: 1000000 }
/// inputs:
///   - { name: maxNodes, type: int, required: false }
///   - { name: maxDescriptors, type: int, required: false }
/// outputs:
///   - { name: reclassified, type: int }
///   - { name: reviewed, type: int }
///   - { name: backlogRemaining, type: int }
/// requires: [ stack.peek, stack.remove, recall, embed, classify, persist, edge, demote, note ]
//
// restructure_tree_v1 — the long-running schema re-migration (memory § 11.2;
// monthly lane, § 9.7). Adding a node type retroactively means reclassifying the
// existing nodes that should now belong to it; doing that in one shot is
// impossible at millions-of-nodes scale (§ 11.1), so the migration runs as a
// budgeted pass that the scheduler reschedules each idle cycle (§ 11.2 step 5).
//
// ── The durable cursor is the backlog stack ─────────────────────────
//
// The spec's `MigrationApi` cursor (§ 11.3) is a native memory surface that is
// *not* bridged into d4rt — a procedure body reaches only the bridged primitive
// set. The `restructure_backlog` bootstrap stack is therefore the cursor: each
// pass peeks a budgeted batch of migration descriptors, migrates a budgeted
// number of their candidates, and removes a descriptor only once its candidate
// set is exhausted. Popping consumes progress durably; a restart resumes from
// the stack's surviving entries. Non-completion is allowed (§ 11.4): a migration
// that never finishes leaves the system correct because the new type is
// queryable from registration and un-migrated nodes still resolve via their old
// type and centroid similarity.
//
// ── The migration descriptor ────────────────────────────────────────
//
// A `restructure_backlog` entry's `attrs` carry the migration: `targetType`
// (the node type to reclassify into) and `query` (the text that recalls the
// candidates), with an optional `fromType` (the old type to restrict the
// candidate recall to). This is the shape `propose_node_type_v1` pushes when a
// new type is accepted (§ per the dream description, "which existing nodes need
// reclassification into this type, what query identifies them").
//
// ── LLM-free (throttle-exempt) ──────────────────────────────────────
//
// The verdict is centroid-distance classification (`mem.classify`) over a
// re-embedding (`sub.embed`) — no chat completion. Like `dream_recentroid_v1`
// and `dream_decay_v1`, the dreaming throttle (which paces chat completions)
// does not gate it.
//
// ── Never deletes (HP6) ─────────────────────────────────────────────
//
// A reclassified candidate's original is demoted with reason `migrationArchive`
// — hidden from default retrieval, kept addressable by id and present in backup,
// and reachable from the new node by the `derived_from` edge. The reclassified
// node is the new authority; the original is its provenance.
//
// ── Scope (memory § 9.5) ────────────────────────────────────────────
//
// A Restructurer-class agent: reads everything, writes the reclassified nodes
// (`node:*` — the target type is data, so the wildcard write scope), the
// `derived_from` provenance edge, and demotes the originals. The engine binds
// its identity onto the memory bridge; the store's `AgentRegistry` confines the
// writes to its declared scopes.
import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure/src/bridges/memory_bridge.dart';
import 'package:tom_brain_procedure/src/bridges/substrate_bridge.dart';
import 'package:tom_brain_procedure/src/primitives_native/primitives_native.dart';

Future<Map<String, Object?>> run(ProcedureInputs inputs) async {
  const producer = 'restructure_tree_v1';
  final maxNodes = _intArg(inputs, 'maxNodes', 64);
  final maxDescriptors = _intArg(inputs, 'maxDescriptors', 8);

  // 1. Peek the migration descriptors. The backlog is the durable cursor: we
  //    leave the entries in place and remove one only when its candidates are
  //    exhausted (a pass that reclassifies nothing for it).
  final backlog = await mem.stackPeek('restructure_backlog', k: maxDescriptors);

  var reclassified = 0;
  var reviewed = 0;
  // The per-pass node budget is shared across descriptors, oldest-first, so one
  // huge migration cannot starve the rest — each pass makes some progress on the
  // head of the backlog and the scheduler reschedules for the remainder.
  var remainingBudget = maxNodes;

  for (final entry in backlog) {
    if (remainingBudget <= 0) break;
    if (entry is! Map) continue;
    final attrs = entry['attrs'];
    if (attrs is! Map) continue;

    final targetType = attrs['targetType'];
    final query = attrs['query'];
    if (targetType is! String || targetType.isEmpty) continue;
    if (query is! String || query.isEmpty) continue;
    final fromType = attrs['fromType'];

    // 2. Recall the candidates this descriptor still has to migrate. When a
    //    `fromType` is given the recall is restricted to it, so reclassified
    //    (demoted) originals fall out of the candidate set automatically.
    final recall = fromType is String && fromType.isNotEmpty
        ? await mem.recall(query, modes: ['bm25', 'vector'],
            k: remainingBudget, types: [fromType])
        : await mem.recall(query, modes: ['bm25', 'vector'], k: remainingBudget);

    var reclassifiedForDescriptor = 0;
    final nodes = recall['nodes'];
    if (nodes is List) {
      for (final node in nodes) {
        if (remainingBudget <= 0) break;
        if (node is! Map) continue;
        final nodeId = node['id'];
        if (nodeId is! String) continue;
        // A node already of the target type is migrated — skip it (belt and
        // braces; the fromType filter usually excludes these already).
        if (node['typeName'] == targetType) continue;

        final values = node['values'];
        if (values is! Map) continue;
        final text = _textOf(values);
        if (text.isEmpty) continue;

        reviewed++;
        remainingBudget--;

        // 3. Re-embed and classify against the node-type centroids. Only a
        //    confident match *into the target type* is reclassified; an
        //    uncertain or differently-matched candidate is left untouched for a
        //    later pass (or forever — non-completion is allowed, § 11.4).
        final embedded = await sub.embed(text);
        final vec = embedded['vec'];
        if (vec is! List) continue;
        final classification = await mem.classify(_toDoubles(vec));
        if (classification['decision'] != 'confident') continue;
        if (classification['bestMatch'] != targetType) continue;

        // 4. Persist the reclassified node (carrying the original values + the
        //    embedding we just computed), edge it `derived_from` the original,
        //    and demote the original `migrationArchive` (reversible, never
        //    deleted — HP6).
        final newId = await mem.persist(
          targetType,
          Map<String, Object?>.from(values),
          producer: producer,
          embedding: vec,
        );
        if (newId.isEmpty) continue; // a write cap was hit (spec § 5.4)
        await mem.edge(newId, 'derived_from', nodeId, producer: producer);
        await mem.demote(nodeId, 'migrationArchive');
        reclassified++;
        reclassifiedForDescriptor++;
      }
    }

    // 5. A descriptor whose pass migrated nothing is exhausted (no remaining
    //    candidate classifies into the target type) — remove it from the
    //    backlog so the migration retires. A descriptor that migrated at least
    //    one candidate stays for the next pass.
    if (reclassifiedForDescriptor == 0) {
      final descriptorNode = entry['nodeId'];
      if (descriptorNode is String) {
        await mem.stackRemove('restructure_backlog', descriptorNode);
      }
    }
  }

  final after = await mem.stackPeek('restructure_backlog', k: 1000);
  final backlogRemaining = after.length;

  note('progress', {
    'agent': 'restructure_tree_v1',
    'reclassified': reclassified,
    'reviewed': reviewed,
    'backlogRemaining': backlogRemaining,
  });

  return <String, Object?>{
    'reclassified': reclassified,
    'reviewed': reviewed,
    'backlogRemaining': backlogRemaining,
  };
}

/// The text the store embeds for a node — its String-valued fields joined in
/// sorted-key order, mirroring `dream_recentroid_v1`'s reconstruction so the
/// re-embedding is commensurable with the centroids that classified the node.
String _textOf(Map values) {
  final parts = <String>[];
  final keys = values.keys.map((k) => '$k').toList()..sort();
  for (final key in keys) {
    final value = values[key];
    if (value is String && value.isNotEmpty) parts.add(value);
  }
  return parts.join(' ');
}

/// Narrows a recalled embedding list to `List<double>` for `mem.classify`.
List<double> _toDoubles(List raw) {
  final out = <double>[];
  for (final component in raw) {
    if (component is num) out.add(component.toDouble());
  }
  return out;
}

/// Reads an int-valued input named [name], or [fallback] when absent /
/// non-numeric — the per-pass budgets are robust to a missing override.
int _intArg(ProcedureInputs inputs, String name, int fallback) {
  if (!inputs.has(name)) return fallback;
  final v = inputs.get(name);
  return v is num ? v.toInt() : fallback;
}
