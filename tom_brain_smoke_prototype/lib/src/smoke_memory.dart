// SmokeMemory + spawnSmokeMemory — an in-isolate recording `TomBrainMemory`
// for the end-to-end smoke (E.46 stand-up, E.47 chat roundtrip).
//
// The smoke harness provisions memory over the *isolate* transport (the
// production topology), so the store runs in a spawned worker isolate. The
// factory reference and the class it returns therefore cross the isolate
// boundary: Dart forbids closures captured from the spawning isolate, so both
// [spawnSmokeMemory] and [SmokeMemory] (and the [RecordingMemoryBase] it
// extends) must be top-level, reachable in the spawned isolate (which loads the
// same Dart program). This mirrors the procedure prototype's
// `RecordingFakeMemory` + `spawnRichFakeMemory` convention
// (`d43_memory_provisioning_test.dart`).
//
// ── Why this records (and how the test reads it back) ────────────────
//
// E.47 drives a real `POST /v1/chat/completions` and must then assert the
// `answer_with_memory_v1` procedure persisted the expected graph: an `Event`
// for the inbound prompt, a `Conclusion` for the answer, a `produced_by` edge
// (recorder), and — on a fresh empty memory — a cold-path `InterestItem` plus
// an `interests` stack push. But the store runs in the *worker* isolate, so
// the test cannot reach into it directly. The one marshallable read-back is
// [TomBrainMemory.stats]: this store therefore tallies every persist (by node
// type), every edge (by wire name), every stack push (by stack name), and
// every opened trail, and projects them onto a [MemoryStats] the host can read
// across the boundary — all of which is owned by [RecordingMemoryBase].
//
// SmokeMemory keeps only the tallies (not the full graph), so it overrides the
// base's four projecting members minimally: [persist] records the node so [get]
// resolves it but tracks no insertion order or embedding; [edge] only counts;
// [recall] stays empty (no seeded nodes) so the procedure takes the cold path;
// [edgesOf] returns empty. The richer read-back lives in
// [InspectableSmokeMemory].

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show EdgeId, NodeId;

import 'recording_memory_support.dart';

/// Top-level factory the isolate transport calls inside the spawned worker to
/// build the memory the smoke runs against. Must be top-level so the host can
/// send it across the isolate boundary.
Future<TomBrainMemory> spawnSmokeMemory() async => SmokeMemory();

/// An in-isolate recording [TomBrainMemory] for the smoke harness.
///
/// Records per-type node / edge / stack tallies (through [RecordingMemoryBase])
/// and projects them onto a [MemoryStats] through `stats` — the one read-back
/// path that marshals across the isolate boundary back to the host. Recall
/// returns empty (no seeded nodes), so the `answer_with_memory_v1` procedure
/// takes its cold path. Top-level so it is reachable in the spawned isolate.
final class SmokeMemory extends RecordingMemoryBase {
  @override
  Future<NodeId> persist(NodeDraft draft, {required Scope scope}) async {
    final NodeId id = NodeId.generate();
    nodes[id] = Node(
      id: id,
      typeName: draft.typeName,
      values: Map<String, Object?>.of(draft.values),
      createdAt: DateTime.now().toUtc(),
    );
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
    edgeCountByType.update(type.wireName, (c) => c + 1, ifAbsent: () => 1);
    return EdgeId.generate();
  }

  @override
  Future<RecallResult> recall(RecallQuery query) async => const RecallResult(
        nodes: <Node>[],
        report: RecallReport(
          candidatesPerMode: <RecallMode, int>{},
          fusionStrategy: FusionStrategy.rrf,
          diversityStrategy: DiversityStrategy.mmr,
          elapsedMs: 0,
          embeddingsCallouts: 0,
          reRankInvoked: false,
          degraded: false,
        ),
      );

  @override
  Future<List<Edge>> edgesOf(
    NodeId id, {
    EdgeDirection direction = EdgeDirection.both,
    Set<EdgeType>? types,
  }) async =>
      const <Edge>[];
}
