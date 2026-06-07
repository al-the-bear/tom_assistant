// RecallResult + RecallReport — `recall` output (§ 6.4).
//
// `RecallResult` is the materialised list of nodes plus the
// `RecallReport` cost breakdown. Reports always ride along so a
// caller can append them to the run's trail without a second
// query.
//
// Multi-seed recall (`recallMulti`, § 6.5, Extension H) returns the
// same `RecallResult` shape, additionally populating the optional
// `provenance` list: one `RecallProvenanceEntry` per returned node,
// recording which seeds surfaced it and the fused score. Single-seed
// `recall` leaves `provenance` null.

import '../../ids/ids.dart' show NodeId;
import '../nodes/node.dart';
import 'recall_query.dart';

/// Per-mode cost / candidacy report for one recall call.
///
/// Goes into the run's trail (§ 8.2 `primitiveCall`) so cost is
/// observable and tunable. The shape follows the example block
/// listed in spec § 6.4.
final class RecallReport {
  /// Candidate count returned by each mode *before* fusion.
  final Map<RecallMode, int> candidatesPerMode;

  /// Which fusion strategy was applied.
  final FusionStrategy fusionStrategy;

  /// Which diversity strategy was applied (and lambda, when MMR).
  final DiversityStrategy diversityStrategy;
  final double? diversityLambda;

  /// Total wall-clock elapsed for the recall, in milliseconds.
  final int elapsedMs;

  /// Number of embed callouts memory made on the caller's behalf
  /// (typically 0 or 1 — 1 when the caller did not supply an
  /// embedding for vector mode).
  final int embeddingsCallouts;

  /// Whether the caller-supplied re-rank hook ran.
  final bool reRankInvoked;

  /// True when the recall ran in degraded mode (e.g. the executor was
  /// constructed without a vector backend). In production the brain
  /// refuses to boot when vec0 is absent
  /// (`loadVecExtensionOrRefuseToBoot`), so this flag is only set by
  /// tests that omit the vector backend.
  final bool degraded;

  const RecallReport({
    required this.candidatesPerMode,
    required this.fusionStrategy,
    required this.diversityStrategy,
    required this.elapsedMs,
    this.diversityLambda,
    this.embeddingsCallouts = 0,
    this.reRankInvoked = false,
    this.degraded = false,
  });
}

/// Per-node provenance for a multi-seed recall (§ 6.5).
///
/// One entry per node returned by `recallMulti`, aligned by index with
/// `RecallResult.nodes`. Records which seeds (by their index in the
/// `MultiRecallQuery.seeds` list) surfaced the node and the fused score
/// that ranked it. Single-seed `recall` does not produce these.
final class RecallProvenanceEntry {
  /// The node this entry describes (matches the same-index entry in
  /// `RecallResult.nodes`).
  final NodeId nodeId;

  /// Indices into `MultiRecallQuery.seeds` of the seeds that surfaced
  /// this node, ascending. Always non-empty — a node with no surfacing
  /// seed cannot appear in the result.
  final List<int> seedIndexes;

  /// The fused (weighted-RRF) score that ranked this node. Higher =
  /// more relevant.
  final double fusedScore;

  const RecallProvenanceEntry({
    required this.nodeId,
    required this.seedIndexes,
    required this.fusedScore,
  });
}

/// `TomBrainMemory.recall` / `recallMulti` output.
final class RecallResult {
  /// Final ranked list of nodes — at most `RecallQuery.k` (or
  /// `MultiRecallQuery.k`) entries.
  final List<Node> nodes;

  /// Cost / candidacy report. Always present.
  final RecallReport report;

  /// Per-node seed provenance, index-aligned with [nodes]. Populated
  /// by `recallMulti` (§ 6.5); `null` for single-seed `recall`.
  final List<RecallProvenanceEntry>? provenance;

  const RecallResult({
    required this.nodes,
    required this.report,
    this.provenance,
  });
}
