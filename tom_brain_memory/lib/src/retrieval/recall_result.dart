// RecallResult + RecallReport — `recall` output (§ 6.4).
//
// `RecallResult` is the materialised list of nodes plus the
// `RecallReport` cost breakdown. Reports always ride along so a
// caller can append them to the run's trail without a second
// query.

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

  /// True when the recall ran in degraded mode (e.g. vector mode
  /// disabled because the extension failed to load — see § 15
  /// `VectorIndexUnavailable`).
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

/// `TomBrainMemory.recall` output.
final class RecallResult {
  /// Final ranked list of nodes — at most `RecallQuery.k` entries.
  final List<Node> nodes;

  /// Cost / candidacy report. Always present.
  final RecallReport report;

  const RecallResult({
    required this.nodes,
    required this.report,
  });
}
