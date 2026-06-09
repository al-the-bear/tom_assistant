// A canned [MemoryApiClient] for the Module-2 widget tests — no network, no live
// brain. Each method returns the supplied canned value; an unset value yields an
// empty/typed default. Set [unavailable] to make every call throw
// [MemoryUnavailable], driving the deferred-connector view state (§ 8.4).

import 'package:tom_brain_observatory_web/src/api/memory_api_client.dart';
import 'package:tom_brain_observatory_web/src/model/memory_nodes.dart';

class StubMemoryApiClient implements MemoryApiClient {
  /// Browse results keyed by `typeName`.
  final Map<String, TypeBrowseResult> browses;

  /// Node detail keyed by id.
  final Map<String, MemoryNode> nodes;

  /// Edges keyed by node id.
  final Map<String, List<MemoryEdge>> edgesByNode;

  /// The single canned recall result (single- and multi-seed share it).
  final RecallResult? recallResult;

  final List<MemoryStackSummary> stackList;

  /// Stack entries keyed by stack name.
  final Map<String, List<MemoryStackEntry>> stackEntries;

  final MemoryClassification? classification;

  final MemoryProfiles profileList;

  /// When `true`, every call throws [MemoryUnavailable] (deferred connector).
  final bool unavailable;

  /// Records every call for assertions (e.g. that switching the viewed profile
  /// never issues a write — there is no write method to issue).
  final List<String> calls = <String>[];

  StubMemoryApiClient({
    this.browses = const <String, TypeBrowseResult>{},
    this.nodes = const <String, MemoryNode>{},
    this.edgesByNode = const <String, List<MemoryEdge>>{},
    this.recallResult,
    this.stackList = const <MemoryStackSummary>[],
    this.stackEntries = const <String, List<MemoryStackEntry>>{},
    this.classification,
    this.profileList = const MemoryProfiles(),
    this.unavailable = false,
  });

  void _guard(String call) {
    calls.add(call);
    if (unavailable) throw const MemoryUnavailable();
  }

  static const RecallReport _emptyReport = RecallReport(
    fusionStrategy: 'rrf',
    diversityStrategy: 'mmr',
    elapsedMs: 0,
    embeddingsCallouts: 0,
    reRankInvoked: false,
    degraded: false,
  );

  @override
  Future<TypeBrowseResult> browseNodes(
    String typeName, {
    List<String> knownIds = const <String>[],
    bool traverseEdges = false,
  }) async {
    _guard('browseNodes:$typeName');
    return browses[typeName] ??
        TypeBrowseResult(typeName: typeName, exhaustive: false);
  }

  @override
  Future<MemoryNode?> node(String id) async {
    _guard('node:$id');
    return nodes[id];
  }

  @override
  Future<List<MemoryEdge>> edges(
    String id, {
    EdgeDirection direction = EdgeDirection.both,
    Set<String>? types,
  }) async {
    _guard('edges:$id');
    return edgesByNode[id] ?? const <MemoryEdge>[];
  }

  @override
  Future<RecallResult> recall({
    String? text,
    List<double>? embedding,
    Set<RecallMode>? modes,
    int? k,
    int? wallClockMs,
  }) async {
    _guard('recall:$text');
    return recallResult ?? const RecallResult(report: _emptyReport);
  }

  @override
  Future<RecallResult> recallMulti({
    required List<RecallSeedSpec> seeds,
    int? k,
    int? wallClockMs,
  }) async {
    _guard('recallMulti:${seeds.length}');
    return recallResult ?? const RecallResult(report: _emptyReport);
  }

  @override
  Future<List<MemoryStackSummary>> stacks() async {
    _guard('stacks');
    return stackList;
  }

  @override
  Future<List<MemoryStackEntry>> stackPeek(String name, {int? k}) async {
    _guard('stackPeek:$name');
    return stackEntries[name] ?? const <MemoryStackEntry>[];
  }

  @override
  Future<MemoryClassification> classify(
    List<double> embedding, {
    ClassifyTarget target = ClassifyTarget.nodeType,
  }) async {
    _guard('classify');
    return classification ??
        const MemoryClassification(
          decision: 'unknown',
          bestMatch: null,
          bestSimilarity: 0.0,
          secondSimilarity: 0.0,
        );
  }

  @override
  Future<MemoryProfiles> profiles() async {
    _guard('profiles');
    return profileList;
  }
}
