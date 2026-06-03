// InspectableSmokeMemory — an in-process, MCP-inspectable `TomBrainMemory`
// for the end-to-end conformance test (E.55).
//
// Plan step E.55 (verbatim): "End-to-end conformance test: scripted scenario —
// start process → OpenAI request → answer → memory inspect (via the MCP
// server) → assert event + conclusion + interest stack contents. Repeat for
// Telegram. Both must pass in CI."
//
// ── Why a second smoke memory ────────────────────────────────────────
//
// E.46–E.54 run memory over the *isolate* transport ([SmokeMemory] +
// [spawnSmokeMemory]) and inspect the post-run graph through the one read-back
// that marshals across the isolate boundary, [TomBrainMemoryClient.stats]. E.55
// has a stricter obligation: it must inspect memory *through the MCP server*,
// which is the brain's real external memory-inspection surface
// (`memory_specification.md` § 3.2). The MCP server is constructed over a
// [TomBrainMemory] and forwards each tool call to it directly; it cannot reach
// a store that lives behind a SendPort in a worker isolate.
//
// So E.55 provisions memory **in-process** ([MemoryProvisioningConfig.inProcess]
// — the test transport D.43 names): the run and the MCP server share one
// [TomBrainMemory] object in the host isolate. The run writes to it through the
// dispatcher/engine; the MCP server reads it back through the seven v1 tools.
// Since `TomBrainMemory implements TomBrainMemoryClient`, the very same object
// is both the dispatcher's in-process client and the MCP server's memory.
//
// ── How the cold path survives a recall that returns persisted nodes ──
//
// `answer_with_memory_v1` (§ 11) recalls **first**, then persists the Event /
// Conclusion / InterestItem. So a recall whose result is "every currently-
// persisted node" still returns *nothing* during the run (the store is empty at
// recall time, before any persist), which keeps the procedure on its cold
// classification path (InterestItem + an `interests` stack push, D.40). After
// the run the same recall returns the persisted Event and Conclusion — exactly
// what the E.55 MCP inspection needs to read back. The two phases are
// distinguished by *when* recall runs relative to the writes, not by any flag.
//
// ── What this double adds over the shared base ───────────────────────
//
// [RecordingMemoryBase] owns the recording tallies, `stats`, `get`/`getMany`,
// the trail surface, and the no-op tail. This double additionally records full
// [Node] (with embedding) / [Edge] objects and the node insertion order, so the
// MCP read tools — `memory.recall`, `memory.get`, `memory.edgesOf`,
// `memory.stack.list`, `memory.stack.peek` — return real graph contents to the
// inspecting client. It therefore overrides the base's four projecting members
// ([persist], [edge], [recall], [edgesOf]) to project the full graph rather
// than tallies.

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show EdgeId, NodeId;

import 'recording_memory_support.dart';

/// An in-process recording [TomBrainMemory] whose graph is readable back through
/// the memory MCP server (E.55).
///
/// Records every persisted node (with embedding), every edge, and every stack
/// push as full domain objects, and serves them through the consumer API the
/// MCP tools call. [recall] returns the persisted nodes (capped at the query's
/// `k`), so a post-run MCP `memory.recall` surfaces the run's Event + Conclusion;
/// because `answer_with_memory_v1` recalls before it persists, the in-run recall
/// still returns empty and the cold-classification path (InterestItem +
/// `interests` push) is preserved.
final class InspectableSmokeMemory extends RecordingMemoryBase {
  /// The node type the engine's `RunRecorder` persists as a run bookkeeping
  /// marker (`procedureRunNodeType`). Excluded from [recall] so it never
  /// masquerades as a knowledge hit (see [recall]).
  static const String _procedureRunTypeName = 'ProcedureRun';

  /// Insertion order of node ids (recall returns nodes in this order).
  final List<NodeId> _nodeOrder = <NodeId>[];

  /// Recorded edges in insertion order.
  final List<Edge> _edges = <Edge>[];

  @override
  Future<NodeId> persist(NodeDraft draft, {required Scope scope}) async {
    final NodeId id = NodeId.generate();
    nodes[id] = Node(
      id: id,
      typeName: draft.typeName,
      values: Map<String, Object?>.of(draft.values),
      embedding: draft.embedding,
      createdAt: DateTime.now().toUtc(),
    );
    _nodeOrder.add(id);
    nodeCountByType.update(draft.typeName, (c) => c + 1, ifAbsent: () => 1);
    return id;
  }

  @override
  Future<EdgeId> edge(
    NodeId from,
    EdgeType type,
    NodeId to, {
    required Scope scope,
    double weight = 1.0,
    Map<String, Object?>? attrs,
  }) async {
    final EdgeId id = EdgeId.generate();
    _edges.add(
      Edge(
        id: id,
        from: from,
        type: type,
        to: to,
        weight: weight,
        attrs: attrs ?? const <String, Object?>{},
      ),
    );
    edgeCountByType.update(type.wireName, (c) => c + 1, ifAbsent: () => 1);
    return id;
  }

  @override
  Future<RecallResult> recall(RecallQuery query) async {
    // Return the persisted *knowledge* nodes in insertion order, capped at the
    // query's k. `ProcedureRun` records are excluded: a real recall surfaces
    // retrievable knowledge (Event, Conclusion, InterestItem, …), never run
    // bookkeeping — and the engine's `RunRecorder` persists an inflight
    // `ProcedureRun` marker *before* the procedure body runs. Counting that
    // marker as a recall hit would make the in-run recall non-empty and rob
    // `answer_with_memory_v1` of its cold-classification path (the InterestItem
    // + `interests` push, D.40). Filtering it keeps recall empty during the run
    // (only the marker exists at that point) while still surfacing the Event +
    // Conclusion after the run for the MCP inspection (see the file header).
    final nodes = <Node>[
      for (final id in _nodeOrder)
        if (this.nodes[id] != null &&
            this.nodes[id]!.typeName != _procedureRunTypeName)
          this.nodes[id]!,
    ];
    final capped = nodes.length <= query.k ? nodes : nodes.sublist(0, query.k);
    return RecallResult(
      nodes: capped,
      report: RecallReport(
        candidatesPerMode: <RecallMode, int>{
          for (final mode in query.modes) mode: capped.length,
        },
        fusionStrategy: FusionStrategy.rrf,
        diversityStrategy: DiversityStrategy.mmr,
        elapsedMs: 0,
        embeddingsCallouts: 0,
        reRankInvoked: false,
        degraded: false,
      ),
    );
  }

  @override
  Future<List<Edge>> edgesOf(
    NodeId id, {
    EdgeDirection direction = EdgeDirection.both,
    Set<EdgeType>? types,
  }) async =>
      <Edge>[
        for (final e in _edges)
          if (_touches(e, id, direction) &&
              (types == null || types.contains(e.type)))
            e,
      ];

  /// Whether [e] touches [id] in the requested [direction].
  bool _touches(Edge e, NodeId id, EdgeDirection direction) {
    switch (direction) {
      case EdgeDirection.outgoing:
        return e.from == id;
      case EdgeDirection.incoming:
        return e.to == id;
      case EdgeDirection.both:
        return e.from == id || e.to == id;
    }
  }
}
