// The client-side DTOs for the Module-2 memory read surface
// (`prompt_tracing.md` § 5.2–5.6, § 8.4). Like the Module-1 DTOs
// (`prompt_trace.dart`), these mirror the backend's
// `tom_brain_observatory/lib/src/memory/memory_nodes.dart` wire shapes but are a
// *separate* decoding surface: the web app consumes the JSON the `/api/memory/*`
// routes emit, it does not import the server's package (which pulls in
// `dart:io`/shelf). Frontend↔API coupling is the JSON, not the Dart types.
//
// Decoding is total: a missing optional is `null`, never a throw (§ 3.1).

import 'dart:math' as math;

/// One of the four retrieval modes (§ 5.4). [wireName] is the JSON token the
/// `/api/memory/recall` body expects.
enum RecallMode {
  bm25('bm25'),
  vector('vector'),
  graphWalk('graphWalk'),
  symbolic('symbolic');

  const RecallMode(this.wireName);

  final String wireName;
}

/// Edge-traversal direction (§ 5.3).
enum EdgeDirection {
  outgoing('outgoing'),
  incoming('incoming'),
  both('both');

  const EdgeDirection(this.wireName);

  final String wireName;
}

/// Classification target for the probe (§ 5.6).
enum ClassifyTarget {
  nodeType('nodeType'),
  procedure('procedure'),
  concept('concept');

  const ClassifyTarget(this.wireName);

  final String wireName;
}

/// A memory node (§ 5.2). The embedding is decoded but rendered as
/// dimensionality + norm by default (never raw floats) — the view expands it on
/// demand.
class MemoryNode {
  final String id;
  final String typeName;
  final Map<String, dynamic> values;
  final List<double>? embedding;
  final String createdAt;
  final String status;

  const MemoryNode({
    required this.id,
    required this.typeName,
    required this.status,
    required this.createdAt,
    this.values = const <String, dynamic>{},
    this.embedding,
  });

  /// The embedding's dimensionality, or `null` when the node carries none.
  int? get embeddingDimension => embedding?.length;

  /// The embedding's L2 norm, or `null` when the node carries none.
  double? get embeddingNorm {
    final vec = embedding;
    if (vec == null) return null;
    var sumSq = 0.0;
    for (final v in vec) {
      sumSq += v * v;
    }
    return math.sqrt(sumSq);
  }

  factory MemoryNode.fromJson(Map<String, dynamic> json) => MemoryNode(
        id: json['id'] as String,
        typeName: json['typeName'] as String,
        status: json['status'] as String? ?? 'active',
        createdAt: json['createdAt'] as String? ?? '',
        values: (json['values'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{},
        embedding: _doubleList(json['embedding']),
      );
}

/// A memory edge (§ 5.3).
class MemoryEdge {
  final String id;
  final String from;
  final String type;
  final String to;
  final double weight;
  final Map<String, dynamic> attrs;

  const MemoryEdge({
    required this.id,
    required this.from,
    required this.type,
    required this.to,
    required this.weight,
    this.attrs = const <String, dynamic>{},
  });

  factory MemoryEdge.fromJson(Map<String, dynamic> json) => MemoryEdge(
        id: json['id'] as String,
        from: json['from'] as String,
        type: json['type'] as String,
        to: json['to'] as String,
        weight: (json['weight'] as num?)?.toDouble() ?? 1.0,
        attrs: (json['attrs'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{},
      );
}

/// A stack inventory row (§ 5.5).
class MemoryStackSummary {
  final String name;
  final int size;
  final double topPriority;
  final bool bootstrap;

  const MemoryStackSummary({
    required this.name,
    required this.size,
    required this.topPriority,
    required this.bootstrap,
  });

  factory MemoryStackSummary.fromJson(Map<String, dynamic> json) =>
      MemoryStackSummary(
        name: json['name'] as String,
        size: (json['size'] as num?)?.toInt() ?? 0,
        topPriority: (json['topPriority'] as num?)?.toDouble() ?? 0.0,
        bootstrap: json['bootstrap'] as bool? ?? false,
      );
}

/// A stack entry (§ 5.5).
class MemoryStackEntry {
  final String id;
  final String stackName;
  final String nodeId;
  final double priority;
  final String pushedAt;
  final String status;
  final Map<String, dynamic> attrs;

  const MemoryStackEntry({
    required this.id,
    required this.stackName,
    required this.nodeId,
    required this.priority,
    required this.pushedAt,
    required this.status,
    this.attrs = const <String, dynamic>{},
  });

  factory MemoryStackEntry.fromJson(Map<String, dynamic> json) =>
      MemoryStackEntry(
        id: json['id'] as String,
        stackName: json['stackName'] as String,
        nodeId: json['nodeId'] as String,
        priority: (json['priority'] as num?)?.toDouble() ?? 0.0,
        pushedAt: json['pushedAt'] as String? ?? '',
        status: json['status'] as String? ?? 'active',
        attrs: (json['attrs'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{},
      );
}

/// A centroid classification result (§ 5.6).
class MemoryClassification {
  final String decision;
  final String? bestMatch;
  final double bestSimilarity;
  final double secondSimilarity;

  const MemoryClassification({
    required this.decision,
    required this.bestMatch,
    required this.bestSimilarity,
    required this.secondSimilarity,
  });

  factory MemoryClassification.fromJson(Map<String, dynamic> json) =>
      MemoryClassification(
        decision: json['decision'] as String,
        bestMatch: json['bestMatch'] as String?,
        bestSimilarity: (json['bestSimilarity'] as num?)?.toDouble() ?? 0.0,
        secondSimilarity: (json['secondSimilarity'] as num?)?.toDouble() ?? 0.0,
      );
}

/// The per-mode cost report of a recall (§ 5.4).
class RecallReport {
  final Map<String, int> candidatesPerMode;
  final String fusionStrategy;
  final String diversityStrategy;
  final double? diversityLambda;
  final int elapsedMs;
  final int embeddingsCallouts;
  final bool reRankInvoked;
  final bool degraded;

  const RecallReport({
    this.candidatesPerMode = const <String, int>{},
    required this.fusionStrategy,
    required this.diversityStrategy,
    required this.elapsedMs,
    required this.embeddingsCallouts,
    required this.reRankInvoked,
    required this.degraded,
    this.diversityLambda,
  });

  factory RecallReport.fromJson(Map<String, dynamic> json) => RecallReport(
        candidatesPerMode: <String, int>{
          for (final entry in (json['candidatesPerMode'] as Map?)?.entries ??
              const <MapEntry<dynamic, dynamic>>[])
            entry.key as String: (entry.value as num).toInt(),
        },
        fusionStrategy: json['fusionStrategy'] as String? ?? 'rrf',
        diversityStrategy: json['diversityStrategy'] as String? ?? 'mmr',
        diversityLambda: (json['diversityLambda'] as num?)?.toDouble(),
        elapsedMs: (json['elapsedMs'] as num?)?.toInt() ?? 0,
        embeddingsCallouts: (json['embeddingsCallouts'] as num?)?.toInt() ?? 0,
        reRankInvoked: json['reRankInvoked'] as bool? ?? false,
        degraded: json['degraded'] as bool? ?? false,
      );
}

/// Per-node seed provenance from multi-seed recall (§ 5.4).
class RecallProvenance {
  final String nodeId;
  final List<int> seedIndexes;
  final double fusedScore;

  const RecallProvenance({
    required this.nodeId,
    required this.fusedScore,
    this.seedIndexes = const <int>[],
  });

  factory RecallProvenance.fromJson(Map<String, dynamic> json) =>
      RecallProvenance(
        nodeId: json['nodeId'] as String,
        fusedScore: (json['fusedScore'] as num?)?.toDouble() ?? 0.0,
        seedIndexes: <int>[
          for (final i in (json['seedIndexes'] as List?) ?? const <dynamic>[])
            (i as num).toInt(),
        ],
      );
}

/// A recall result (§ 5.4): the fused list, the cost [report], and (multi-seed)
/// per-node [provenance].
class RecallResult {
  final List<MemoryNode> nodes;
  final RecallReport report;
  final List<RecallProvenance>? provenance;

  const RecallResult({
    required this.report,
    this.nodes = const <MemoryNode>[],
    this.provenance,
  });

  factory RecallResult.fromJson(Map<String, dynamic> json) {
    final provenanceRaw = json['provenance'] as List?;
    return RecallResult(
      nodes: <MemoryNode>[
        for (final raw in (json['nodes'] as List?) ?? const <dynamic>[])
          MemoryNode.fromJson((raw as Map).cast<String, dynamic>()),
      ],
      report: RecallReport.fromJson(
        (json['report'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{},
      ),
      provenance: provenanceRaw == null
          ? null
          : <RecallProvenance>[
              for (final raw in provenanceRaw)
                RecallProvenance.fromJson((raw as Map).cast<String, dynamic>()),
            ],
    );
  }
}

/// One seed of a multi-seed recall (§ 5.4). Marshalled to the `seeds[]` object
/// the `/api/memory/recall/multi` body expects.
class RecallSeedSpec {
  final RecallMode mode;
  final String? text;
  final List<double>? embedding;
  final List<String>? terms;
  final List<String>? startNodes;
  final double weight;
  final int? k;

  const RecallSeedSpec({
    required this.mode,
    this.text,
    this.embedding,
    this.terms,
    this.startNodes,
    this.weight = 1.0,
    this.k,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'mode': mode.wireName,
        if (text != null) 'text': text,
        if (embedding != null) 'embedding': embedding,
        if (terms != null) 'terms': terms,
        if (startNodes != null) 'startNodes': startNodes,
        'weight': weight,
        if (k != null) 'k': k,
      };
}

/// A composed browse-by-type result (§ 5.2) — `GET /api/memory/nodes`.
/// [exhaustive] is always `false`; [sources] names the read tools used.
class TypeBrowseResult {
  final String typeName;
  final List<MemoryNode> nodes;
  final bool exhaustive;
  final List<String> sources;

  const TypeBrowseResult({
    required this.typeName,
    required this.exhaustive,
    this.nodes = const <MemoryNode>[],
    this.sources = const <String>[],
  });

  factory TypeBrowseResult.fromJson(Map<String, dynamic> json) =>
      TypeBrowseResult(
        typeName: json['typeName'] as String? ?? '',
        exhaustive: json['exhaustive'] as bool? ?? false,
        nodes: <MemoryNode>[
          for (final raw in (json['nodes'] as List?) ?? const <dynamic>[])
            MemoryNode.fromJson((raw as Map).cast<String, dynamic>()),
        ],
        sources: <String>[
          for (final s in (json['sources'] as List?) ?? const <dynamic>[])
            s as String,
        ],
      );
}

/// The profile list plus the current binding (§ 5.6) — `GET /api/memory/profiles`.
class MemoryProfiles {
  final List<String> profiles;
  final String? current;

  const MemoryProfiles({this.profiles = const <String>[], this.current});

  factory MemoryProfiles.fromJson(Map<String, dynamic> json) => MemoryProfiles(
        profiles: <String>[
          for (final p in (json['profiles'] as List?) ?? const <dynamic>[])
            p as String,
        ],
        current: json['current'] as String?,
      );
}

/// Decodes a JSON number list into `List<double>`, or `null` when absent.
List<double>? _doubleList(Object? raw) {
  if (raw is! List) return null;
  return <double>[for (final v in raw) (v as num).toDouble()];
}
