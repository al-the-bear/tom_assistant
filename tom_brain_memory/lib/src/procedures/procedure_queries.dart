// Typed procedure queries (`procedure_specification.md` § 7.3, § 10.3, G-PR4).
//
// Memory exposes a small set of *primitive* read operations — `recall`,
// `edgesOf`, `getMany`, `stream`. The procedure subsystem needs three *named*
// reads on top of them:
//
//   * `CandidateProceduresFor` — rank the retrievable procedures for an
//     incoming request by the four-factor re-rank (intent-embedding similarity
//     × `requires` overlap × success rate × recency). The runtime takes the top
//     candidate when it clears the similarity threshold, and the authoring
//     branch otherwise (§ 7.3, § 8.1).
//   * `ProcedureRunsOf` — the run history of one procedure, newest first, for
//     the metrics pass (G-PR5) and a Forge run inspector (§ 9.2).
//   * `ProcedureRevisionChain` — the full `superseded_by` chain a Procedure node
//     belongs to, oldest → newest. Revisions are structural and never deleted
//     (hard principle 6), so a chain walk is how the live tip and the full
//     audit history are read back.
//
// Each query is a small immutable value describing *what* to read; `execute`
// composes the client primitives to *do* the read and returns typed views. They
// live here in `tom_brain_memory` (not in shared) because they compose the
// memory client contract; the *shapes* they return (`ProcedureView`,
// `ProcedureRunView`) and the *scoring* they apply (`scoreProcedureCandidate`)
// are the shared / domain-free pieces, owned elsewhere.

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:tom_core_agentic/tom_core_agentic.dart'
    show ProcedureRerankWeights, recencyDecay, scoreProcedureCandidate;

/// A procedure candidate paired with the re-rank [score] that ordered it and
/// the four factors that produced the score (carried for trail observability —
/// a run inspector shows *why* a candidate ranked where it did).
final class RankedProcedure {
  /// The candidate procedure.
  final ProcedureView procedure;

  /// The folded re-rank score in [0,1].
  final double score;

  /// Intent-embedding similarity factor in [0,1] (`0` when no embedding was
  /// available on either side).
  final double embeddingSimilarity;

  /// `requires`-overlap factor in [0,1].
  final double requiresOverlap;

  /// Rolling-success-rate factor in [0,1].
  final double successRate;

  /// Recency factor in [0,1].
  final double recencyScore;

  const RankedProcedure({
    required this.procedure,
    required this.score,
    required this.embeddingSimilarity,
    required this.requiresOverlap,
    required this.successRate,
    required this.recencyScore,
  });
}

/// Ranks the retrievable procedures for an incoming request (§ 7.3).
///
/// Pulls a candidate pool with `recall` (BM25 over [text] and/or vector over
/// [embedding], narrowed to `Procedure` nodes), keeps only the retrievable ones
/// (`active` / `preferred`), and re-ranks them with the domain-free
/// [scoreProcedureCandidate]. The intent-embedding factor is the cosine between
/// the request [embedding] and each candidate's stored embedding (mapped into
/// [0,1]); when no [embedding] is supplied it contributes `0` and the other
/// three factors drive the order.
final class CandidateProceduresFor {
  /// Request text — used by BM25 mode (and memory-side embedding for vector
  /// mode when [embedding] is null).
  final String? text;

  /// Pre-computed request intent embedding — used by vector mode *and* by the
  /// re-rank's similarity factor.
  final Vec? embedding;

  /// The bridged-API capabilities the caller's context can supply — the
  /// `requires`-overlap factor scores each candidate's coverage by this set.
  final CapabilitySet available;

  /// How many candidates to pull from `recall` before re-ranking.
  final int poolSize;

  /// How many ranked candidates to return after thresholding.
  final int limit;

  /// Minimum folded score a candidate must clear to be returned. Below this the
  /// runtime takes the authoring branch (§ 7.3 "must clear a similarity
  /// threshold"). Default `0` returns the whole re-ranked pool.
  final double minScore;

  /// Re-rank weighting. Defaults to the balanced blend.
  final ProcedureRerankWeights weights;

  /// Half-life for the recency factor's exponential decay, in milliseconds.
  /// Defaults to 30 days.
  final int recencyHalfLifeMillis;

  const CandidateProceduresFor({
    required this.available,
    this.text,
    this.embedding,
    this.poolSize = 16,
    this.limit = 8,
    this.minScore = 0.0,
    this.weights = ProcedureRerankWeights.balanced,
    this.recencyHalfLifeMillis = 30 * 24 * 60 * 60 * 1000,
  });

  /// Runs the query against [client]. [now] anchors the recency factor; it
  /// defaults to the current UTC time and is injectable for deterministic
  /// tests.
  Future<List<RankedProcedure>> execute(
    TomBrainMemoryClient client, {
    DateTime? now,
  }) async {
    final at = (now ?? DateTime.now()).toUtc();
    final modes = <RecallMode>{
      if (text != null) RecallMode.bm25,
      if (embedding != null || text != null) RecallMode.vector,
    };
    if (modes.isEmpty) {
      throw ArgumentError(
        'CandidateProceduresFor needs text and/or an embedding to recall on.',
      );
    }

    final result = await client.recall(RecallQuery(
      modes: modes,
      text: text,
      embedding: embedding,
      filter: const SymbolicFilter(typeNames: <String>{procedureNodeTypeName}),
      k: poolSize,
    ));

    final ranked = <RankedProcedure>[];
    for (final node in result.nodes) {
      final view = ProcedureView.fromNode(node);
      if (!view.isRetrievable) continue;

      final similarity = _intentSimilarity(view);
      final overlap = view.requires.coverageBy(available);
      final success = view.successRate ?? 0.0;
      final recency = recencyDecay(
        ageMillis: view.lastRunAt == null
            ? null
            : at.difference(view.lastRunAt!).inMilliseconds,
        halfLifeMillis: recencyHalfLifeMillis,
      );

      final score = scoreProcedureCandidate(
        embeddingSimilarity: similarity,
        requiresOverlap: overlap,
        successRate: success,
        recencyScore: recency,
        weights: weights,
      );
      if (score < minScore) continue;

      ranked.add(RankedProcedure(
        procedure: view,
        score: score,
        embeddingSimilarity: similarity,
        requiresOverlap: overlap,
        successRate: success,
        recencyScore: recency,
      ));
    }

    ranked.sort((a, b) => b.score.compareTo(a.score));
    return ranked.length > limit ? ranked.sublist(0, limit) : ranked;
  }

  /// Cosine between the request and candidate embeddings, mapped into [0,1].
  /// `0` when either side has no embedding — no semantic signal to credit.
  double _intentSimilarity(ProcedureView view) {
    final request = embedding;
    final candidate = view.embedding;
    if (request == null || candidate == null) return 0.0;
    final c = cosine(request, candidate);
    return c < 0 ? 0.0 : (c > 1 ? 1.0 : c);
  }
}

/// The run history of one procedure, newest first (§ 9.2, G-PR4).
///
/// A `ProcedureRun` carries the procedure's *logical* id (e.g.
/// `answer_with_memory_v1`) in its `procedureId` field — so the history is a
/// symbolic recall over `ProcedureRun` nodes filtered on that field, then
/// ordered by `startedAt` descending.
final class ProcedureRunsOf {
  /// The logical procedure id whose runs to fetch.
  final String procedureId;

  /// Maximum number of run records to pull from the symbolic scan before
  /// ordering. The scan is unscored, so this caps the candidate set; the
  /// newest [limit] survive the sort.
  final int scanLimit;

  /// How many ordered runs to return.
  final int limit;

  const ProcedureRunsOf(
    this.procedureId, {
    this.scanLimit = 256,
    this.limit = 50,
  });

  /// Runs the query against [client]. Returns runs newest-started first.
  Future<List<ProcedureRunView>> execute(TomBrainMemoryClient client) async {
    final result = await client.recall(RecallQuery(
      modes: const <RecallMode>{RecallMode.symbolic},
      filter: SymbolicFilter(
        typeNames: const <String>{procedureRunNodeTypeName},
        attributes: <AttrClause>[
          AttrClause('procedureId', SymbolicOp.eq, procedureId),
        ],
      ),
      k: scanLimit,
    ));

    final runs = result.nodes
        .map(ProcedureRunView.fromNode)
        .toList(growable: false)
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return runs.length > limit ? runs.sublist(0, limit) : runs;
  }
}

/// The full `superseded_by` revision chain a Procedure node belongs to,
/// ordered oldest → newest (§ 7.2, G-PR4, hard principle 6).
///
/// `superseded_by` points from a superseded node to the revision that replaced
/// it (`old → new`). The walk goes both ways from the [anchor]: backward along
/// incoming edges to the root, forward along outgoing edges to the live tip.
/// Every revision is retained, so the returned list is the complete audit
/// history, with the live tip last.
final class ProcedureRevisionChain {
  /// Any node in the chain — the walk finds the whole chain from it.
  final NodeId anchor;

  const ProcedureRevisionChain(this.anchor);

  /// Runs the query against [client]. Returns the chain oldest → newest, or an
  /// empty list when [anchor] does not resolve to a live node.
  Future<List<ProcedureView>> execute(TomBrainMemoryClient client) async {
    final anchorNode = await client.get(anchor);
    if (anchorNode == null) return const <ProcedureView>[];

    // Walk backward to the root: follow incoming `superseded_by` edges
    // (predecessor → this).
    final older = <NodeId>[];
    var cursor = anchor;
    final seen = <NodeId>{anchor};
    while (true) {
      final predecessor = await _step(
        client,
        cursor,
        EdgeDirection.incoming,
        pick: (edge) => edge.from,
      );
      if (predecessor == null || !seen.add(predecessor)) break;
      older.add(predecessor);
      cursor = predecessor;
    }

    // Walk forward to the tip: follow outgoing `superseded_by` edges
    // (this → successor).
    final newer = <NodeId>[];
    cursor = anchor;
    while (true) {
      final successor = await _step(
        client,
        cursor,
        EdgeDirection.outgoing,
        pick: (edge) => edge.to,
      );
      if (successor == null || !seen.add(successor)) break;
      newer.add(successor);
      cursor = successor;
    }

    // Oldest → newest: reversed predecessors, the anchor, then successors.
    final ordered = <NodeId>[
      ...older.reversed,
      anchor,
      ...newer,
    ];
    final nodes = await client.getMany(ordered);
    // `getMany` elides missing ids and is not order-guaranteed against an
    // arbitrary id list across all implementations; re-project in chain order.
    final byId = <NodeId, Node>{for (final n in nodes) n.id: n};
    return <ProcedureView>[
      for (final id in ordered)
        if (byId[id] != null) ProcedureView.fromNode(byId[id]!),
    ];
  }

  /// Returns the single chain neighbour of [from] in [direction], or `null`
  /// when there is none. A procedure has at most one predecessor and one
  /// successor in a linear revision chain; if storage somehow holds more, the
  /// first is taken (the chain is linear by construction — a fork is a bug
  /// upstream, not something this read should mask).
  Future<NodeId?> _step(
    TomBrainMemoryClient client,
    NodeId from,
    EdgeDirection direction, {
    required NodeId Function(Edge edge) pick,
  }) async {
    final edges = await client.edgesOf(
      from,
      direction: direction,
      types: const <EdgeType>{EdgeType.supersededBy},
    );
    if (edges.isEmpty) return null;
    return pick(edges.first);
  }
}
