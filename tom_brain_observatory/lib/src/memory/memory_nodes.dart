// The Memory-Monitoring view models (`prompt_tracing.md` § 5.2–5.6) — the
// observatory's own lean projection of the memory MCP read surface, decoded from
// the wire JSON the brain's tools emit (`tom_brain_memory/lib/src/mcp_server/
// mcp_tools.dart`). Mirrors the Module-1 pattern (`prompt_trace.dart` /
// `run_tree.dart`): the observatory parses the contract into read-only view
// models rather than importing the producing package's domain types — the app is
// a reader, not a second author of the truth (§ 8 authority clause).
//
// Authority: where this disagrees with `memory_specification.md` about a node /
// edge / report shape, the memory spec wins. These types only decode it.

import 'dart:math' as math;

/// One of the four retrieval modes (`memory_specification.md` § 6) the brain
/// runs and the recall views (§ 5.4) replay. The [wireName] is the JSON token
/// the MCP `memory.recall` tool expects.
enum RecallMode {
  bm25('bm25'),
  vector('vector'),
  graphWalk('graphWalk'),
  symbolic('symbolic');

  const RecallMode(this.wireName);

  /// The JSON token in a `modes`/`mode` argument.
  final String wireName;
}

/// Edge-traversal direction (`memory.edgesOf`, § 5.3).
enum EdgeDirection {
  outgoing('outgoing'),
  incoming('incoming'),
  both('both');

  const EdgeDirection(this.wireName);

  /// The JSON token in the `direction` argument.
  final String wireName;
}

/// Classification target for the probe (`memory.classify`, § 5.6).
enum ClassifyTarget {
  nodeType('nodeType'),
  procedure('procedure'),
  concept('concept');

  const ClassifyTarget(this.wireName);

  /// The JSON token in the `target` argument.
  final String wireName;
}

/// A memory node (§ 5.2) — the decoded `Node` wire shape. The embedding is kept
/// raw but never surfaced as 768 floats by default; views render
/// [embeddingDimension] + [embeddingNorm] and expand the vector on demand.
final class MemoryNode {
  final String id;
  final String typeName;
  final Map<String, Object?> values;
  final List<double>? embedding;
  final String createdAt;

  /// Lifecycle: `active` / `demoted` / `archived` / `forgotten`.
  final String status;

  MemoryNode({
    required this.id,
    required this.typeName,
    required this.status,
    required this.createdAt,
    Map<String, Object?> values = const <String, Object?>{},
    this.embedding,
  }) : values = Map<String, Object?>.unmodifiable(values);

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

  factory MemoryNode.fromJson(Map<String, Object?> json) => MemoryNode(
        id: json['id'] as String,
        typeName: json['typeName'] as String,
        status: json['status'] as String? ?? 'active',
        createdAt: json['createdAt'] as String? ?? '',
        values: (json['values'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{},
        embedding: _doubleList(json['embedding']),
      );
}

/// A memory edge (§ 5.3) — the decoded `Edge` wire shape.
final class MemoryEdge {
  final String id;
  final String from;
  final String type;
  final String to;
  final double weight;
  final Map<String, Object?> attrs;

  MemoryEdge({
    required this.id,
    required this.from,
    required this.type,
    required this.to,
    required this.weight,
    Map<String, Object?> attrs = const <String, Object?>{},
  }) : attrs = Map<String, Object?>.unmodifiable(attrs);

  factory MemoryEdge.fromJson(Map<String, Object?> json) => MemoryEdge(
        id: json['id'] as String,
        from: json['from'] as String,
        type: json['type'] as String,
        to: json['to'] as String,
        weight: (json['weight'] as num?)?.toDouble() ?? 1.0,
        attrs: (json['attrs'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{},
      );
}

/// A stack inventory row (`memory.stack.list`, § 5.5).
final class MemoryStackSummary {
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

  factory MemoryStackSummary.fromJson(Map<String, Object?> json) =>
      MemoryStackSummary(
        name: json['name'] as String,
        size: (json['size'] as num?)?.toInt() ?? 0,
        topPriority: (json['topPriority'] as num?)?.toDouble() ?? 0.0,
        bootstrap: json['bootstrap'] as bool? ?? false,
      );
}

/// A stack entry (`memory.stack.peek`, § 5.5).
final class MemoryStackEntry {
  final String id;
  final String stackName;
  final String nodeId;
  final double priority;
  final String pushedAt;
  final String status;
  final Map<String, Object?> attrs;

  MemoryStackEntry({
    required this.id,
    required this.stackName,
    required this.nodeId,
    required this.priority,
    required this.pushedAt,
    required this.status,
    Map<String, Object?> attrs = const <String, Object?>{},
  }) : attrs = Map<String, Object?>.unmodifiable(attrs);

  factory MemoryStackEntry.fromJson(Map<String, Object?> json) =>
      MemoryStackEntry(
        id: json['id'] as String,
        stackName: json['stackName'] as String,
        nodeId: json['nodeId'] as String,
        priority: (json['priority'] as num?)?.toDouble() ?? 0.0,
        pushedAt: json['pushedAt'] as String? ?? '',
        status: json['status'] as String? ?? 'active',
        attrs: (json['attrs'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{},
      );
}

/// A centroid classification result (`memory.classify`, § 5.6).
final class MemoryClassification {
  /// Decision band: `confident` / `uncertain` / `unknown`.
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

  factory MemoryClassification.fromJson(Map<String, Object?> json) =>
      MemoryClassification(
        decision: json['decision'] as String,
        bestMatch: json['bestMatch'] as String?,
        bestSimilarity: (json['bestSimilarity'] as num?)?.toDouble() ?? 0.0,
        secondSimilarity: (json['secondSimilarity'] as num?)?.toDouble() ?? 0.0,
      );
}

/// The per-mode cost report of a recall (§ 5.4).
final class RecallReport {
  final Map<String, int> candidatesPerMode;
  final String fusionStrategy;
  final String diversityStrategy;
  final double? diversityLambda;
  final int elapsedMs;
  final int embeddingsCallouts;
  final bool reRankInvoked;
  final bool degraded;

  RecallReport({
    Map<String, int> candidatesPerMode = const <String, int>{},
    required this.fusionStrategy,
    required this.diversityStrategy,
    required this.elapsedMs,
    required this.embeddingsCallouts,
    required this.reRankInvoked,
    required this.degraded,
    this.diversityLambda,
  }) : candidatesPerMode = Map<String, int>.unmodifiable(candidatesPerMode);

  factory RecallReport.fromJson(Map<String, Object?> json) => RecallReport(
        candidatesPerMode: <String, int>{
          for (final entry
              in (json['candidatesPerMode'] as Map?)?.entries ??
                  const <MapEntry<Object?, Object?>>[])
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

/// Per-node seed provenance returned by multi-seed recall (§ 5.4).
final class RecallProvenance {
  final String nodeId;
  final List<int> seedIndexes;
  final double fusedScore;

  RecallProvenance({
    required this.nodeId,
    required this.fusedScore,
    List<int> seedIndexes = const <int>[],
  }) : seedIndexes = List<int>.unmodifiable(seedIndexes);

  factory RecallProvenance.fromJson(Map<String, Object?> json) =>
      RecallProvenance(
        nodeId: json['nodeId'] as String,
        fusedScore: (json['fusedScore'] as num?)?.toDouble() ?? 0.0,
        seedIndexes: <int>[
          for (final i in (json['seedIndexes'] as List?) ?? const <Object?>[])
            (i as num).toInt(),
        ],
      );
}

/// A recall result (§ 5.4): the fused-and-diversified node list, the cost
/// [report], and (for multi-seed recall) per-node [provenance].
final class RecallResult {
  final List<MemoryNode> nodes;
  final RecallReport report;
  final List<RecallProvenance>? provenance;

  RecallResult({
    required this.report,
    List<MemoryNode> nodes = const <MemoryNode>[],
    this.provenance,
  }) : nodes = List<MemoryNode>.unmodifiable(nodes);

  factory RecallResult.fromJson(Map<String, Object?> json) {
    final provenanceRaw = json['provenance'] as List?;
    return RecallResult(
      nodes: <MemoryNode>[
        for (final raw in (json['nodes'] as List?) ?? const <Object?>[])
          MemoryNode.fromJson((raw as Map).cast<String, Object?>()),
      ],
      report: RecallReport.fromJson(
        (json['report'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{},
      ),
      provenance: provenanceRaw == null
          ? null
          : <RecallProvenance>[
              for (final raw in provenanceRaw)
                RecallProvenance.fromJson((raw as Map).cast<String, Object?>()),
            ],
    );
  }
}

/// One seed of a multi-seed recall (`memory.recall.multi`, § 5.4). Marshalled to
/// the seed-object shape the MCP tool expects.
final class RecallSeedSpec {
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

  /// The seed as the MCP `seeds[]` object — null fields omitted.
  Map<String, Object?> toJson() => <String, Object?>{
        'mode': mode.wireName,
        if (text != null) 'text': text,
        if (embedding != null) 'embedding': embedding,
        if (terms != null) 'terms': terms,
        if (startNodes != null) 'startNodes': startNodes,
        'weight': weight,
        if (k != null) 'k': k,
      };
}

// ─── small decode helper ───────────────────────────────────────────────

/// Decodes a JSON number list into `List<double>`, or `null` when absent.
List<double>? _doubleList(Object? raw) {
  if (raw is! List) return null;
  return <double>[for (final v in raw) (v as num).toDouble()];
}
