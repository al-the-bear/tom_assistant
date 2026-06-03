// Classifier — LLM-independent centroid-based classification
// (memory_specification.md § 7.2).
//
// Plan step A.64:
//   "Implement `classify(Vec, target)` with `minConfidence` +
//    `minMargin` decision rule."
//
// `Classifier` is the read-side counterpart of A.63's
// [CentroidStore]. Given an [embedding] and a [ClassificationTarget],
// it walks every centroid in the target's namespace, computes the
// cosine similarity against each, picks the best and the runner-up,
// and applies the spec § 7.2 decision rule:
//
//   * `confident` — `bestSimilarity ≥ minConfidence`
//                   AND `bestSimilarity - secondSimilarity ≥ minMargin`.
//   * `uncertain` — `bestSimilarity ≥ minConfidence` but the margin to
//                   the runner-up is below `minMargin`.
//   * `unknown`   — best similarity below `minConfidence`, or no
//                   centroids exist for the target (cold start).
//
// Cold-start gate (spec § 7.1): centroids whose [CentroidRecord.exampleCount]
// is below [ClassificationConfig.coldStartMinExamples] are *filtered out*
// before the decision runs. They count as "no centroid yet"; if every
// candidate is filtered, the result is [ClassificationDecision.unknown].
//
// Namespace stripping: the centroid table stores keys as
// `'NodeType:Question'` / `'Procedure:research_v1'`. The result's
// [ClassificationResult.bestMatch] strips the namespace prefix so
// callers receive the bare name they handed in originally
// (`'Question'`, `'research_v1'`) — same shape the spec's § 7.2
// example uses.
//
// ─────────────────────────────────────────────────────────────────────
// Sync vs async
// ─────────────────────────────────────────────────────────────────────
//
// The abstract `TomBrainMemory.classify` returns a `Future`. The
// classifier itself is synchronous — it reads from the store (which is
// synchronous against the SQLite handle), computes cosines in-process,
// and returns. The concrete `SqliteTomBrainMemory.classify` wraps with
// `Future.value(...)` when it lands. Making the classifier itself
// async would force every caller (including in-process synchronous
// callers like dreaming agents and Forge inspectors) onto an
// event-loop hop they don't need. See Q-A.64.1.
//
// ─────────────────────────────────────────────────────────────────────
// Tie-breaking
// ─────────────────────────────────────────────────────────────────────
//
// When two centroids produce identical similarities, the first one
// encountered in [CentroidStore.readAll]'s `for_key`-ascending order
// wins. This is deterministic across runs because [CentroidStore.readAll]
// uses a stable SQL `ORDER BY for_key ASC`. The choice between two
// equally-scoring matches is then alphabetical-first; in practice the
// next-call critique catches the case where two centroids genuinely
// overlap and the dispatcher decides which one belongs. See Q-A.64.4.
//
// ─────────────────────────────────────────────────────────────────────
// Input validation
// ─────────────────────────────────────────────────────────────────────
//
// Zero-norm embeddings are a producer bug: cosine is mathematically
// undefined for them and [cosine] in `tom_brain_shared` already throws
// `ArgumentError`. The classifier surfaces that throw — it does *not*
// turn it into `ClassificationDecision.unknown`. The caller is wrong;
// hiding the bug behind an "unknown" verdict would mask the upstream
// embedding pipeline silently producing zeros. See Q-A.64.5.
//
// Dimension mismatch between the query embedding and a centroid is
// also a producer bug — typically a re-embed migration that ran for
// the nodes but not for the centroids (spec § 15). [cosine] throws
// `ArgumentError`; the classifier surfaces it for the same reason.
// See Q-A.64.6.

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show Clock, SystemClock, Vec, cosine;

import '../api/memory_event.dart';
import '../api/scope.dart';
import '../config/memory_config.dart' show ClassificationConfig;
import 'centroid_store.dart';
import 'classification_events.dart';
import 'classification_result.dart';

/// LLM-independent centroid-based classifier (spec § 7.2).
///
/// Construct once per [CentroidStore]; reuse for every classification
/// call. The classifier holds no per-call state — it reads the live
/// centroid table on every [classify] call so subsequent
/// `dream_recentroid_v1` updates (spec § 7.3) are picked up
/// immediately.
///
/// Thread / isolate safety: inherits the store's single-threaded-owner
/// rule (the store is bound to one [Database] handle).
final class Classifier {
  /// Centroid storage the classifier reads against.
  final CentroidStore _store;

  /// Decision tunables — `minConfidence`, `minMargin`,
  /// `coldStartMinExamples`. Defaults to the spec § 7.2 defaults
  /// (`0.55 / 0.05 / 8`) when omitted.
  final ClassificationConfig _config;

  /// Optional observability sink for [ClassificationComputed]
  /// (spec § 16). `null` on the no-observer default.
  final void Function(MemoryEvent)? _eventSink;

  /// Clock stamping the `occurredAt` of emitted
  /// [ClassificationComputed] events. Defaults to [SystemClock];
  /// tests inject a fixed clock to assert the timestamp exactly.
  final Clock _clock;

  /// Constructs a classifier over [store], reading tunables from
  /// [config].
  ///
  /// Production wires the workspace's [MemoryConfig.classification];
  /// tests construct their own [ClassificationConfig] to exercise
  /// borderline thresholds.
  ///
  /// [eventSink] is optional — when non-null, every [classify] call
  /// emits a [ClassificationComputed] onto it. The concrete
  /// `SqliteTomBrainMemory` wires this to the same `StreamController`
  /// that backs `TomBrainMemory.events()`; tests pass a list-backed
  /// sink to inspect emissions. [clock] stamps the event's
  /// `occurredAt` and is only consulted when [eventSink] is wired.
  Classifier({
    required CentroidStore store,
    ClassificationConfig config = const ClassificationConfig(),
    void Function(MemoryEvent)? eventSink,
    Clock clock = const SystemClock(),
  })  : _store = store,
        _config = config,
        _eventSink = eventSink,
        _clock = clock;

  /// The configuration this classifier was built with. Exposed so the
  /// concrete `SqliteTomBrainMemory.classify` (later A-step) and the
  /// Forge inspector can surface the thresholds in their UIs without
  /// re-reading the workspace config.
  ClassificationConfig get config => _config;

  /// Classifies [embedding] against the centroids registered for
  /// [target].
  ///
  /// Returns one of:
  ///
  ///   * [ClassificationDecision.confident] with [bestMatch] set to
  ///     the bare key (no namespace prefix) and `bestSimilarity` /
  ///     `secondSimilarity` populated.
  ///   * [ClassificationDecision.uncertain] when `best ≥ minConfidence`
  ///     but `best - second < minMargin`. `bestMatch` is still set —
  ///     the caller can use it as a hint for an LLM tiebreak.
  ///   * [ClassificationDecision.unknown] when the best similarity is
  ///     below `minConfidence`, or when no eligible centroid exists
  ///     for [target] (cold start, including the case where every
  ///     centroid is below the `coldStartMinExamples` gate).
  ///
  /// Throws [ArgumentError] when [embedding] has zero norm, or when
  /// its dimension does not match a centroid being scored. Both are
  /// producer bugs — see file header.
  ///
  /// [scope] is optional and only supplies `runId` / `causedBy` for
  /// the emitted [ClassificationComputed] event; it does not affect
  /// the decision.
  ClassificationResult classify(
    Vec embedding, {
    ClassificationTarget target = ClassificationTarget.nodeType,
    Scope? scope,
  }) {
    final prefix = _prefixFor(target);
    final candidates = _store.readAll(prefix: prefix);
    if (candidates.isEmpty) {
      return _emit(const ClassificationResult.unknown(), target, scope);
    }

    // Cold-start filter (spec § 7.1): drop centroids whose backing
    // example set is too small. A type with seven accepted examples
    // and a centroid row sitting at `example_count = 7` is still
    // counted as cold-start; the centroid is technically present but
    // not yet trusted. If every candidate is below the gate, the
    // outcome is the same as "no centroids exist".
    final eligible = candidates
        .where((r) => r.exampleCount >= _config.coldStartMinExamples)
        .toList(growable: false);
    if (eligible.isEmpty) {
      return _emit(const ClassificationResult.unknown(), target, scope);
    }

    // Score every eligible centroid. `readAll` returns rows in
    // `for_key` ascending order, so ties resolve to the
    // alphabetically-first key — deterministic across runs.
    String? bestKey;
    double bestSimilarity = double.negativeInfinity;
    double secondSimilarity = double.negativeInfinity;
    for (final record in eligible) {
      final sim = cosine(embedding, record.centroid);
      if (sim > bestSimilarity) {
        secondSimilarity = bestSimilarity;
        bestSimilarity = sim;
        bestKey = record.forKey;
      } else if (sim > secondSimilarity) {
        secondSimilarity = sim;
      }
    }

    // Single-centroid case: `secondSimilarity` was never overwritten
    // and is still `negativeInfinity`. Spec § 7.2's decision rule
    // wants the margin against "no runner-up" to be `bestSimilarity`
    // itself — which is the same as saying `secondSimilarity = 0.0`
    // for the margin computation. [ClassificationResult] documents
    // `secondSimilarity` defaulting to `0.0` in this case, so we
    // normalise here.
    if (secondSimilarity == double.negativeInfinity) {
      secondSimilarity = 0.0;
    }

    final strippedKey = _stripPrefix(bestKey!, prefix);
    final decision = _decide(bestSimilarity, secondSimilarity);

    return _emit(
      ClassificationResult(
        decision: decision,
        bestMatch: strippedKey,
        bestSimilarity: bestSimilarity,
        secondSimilarity: secondSimilarity,
      ),
      target,
      scope,
    );
  }

  /// Emits [ClassificationComputed] for [result] (spec § 16) and
  /// returns [result] unchanged so call sites stay one-liners. The
  /// event carries the decision plus both similarity scores; on the
  /// cold-start `unknown` paths `bestMatch` is `null` and both
  /// similarities are `0.0`, mirroring the returned result. Short-
  /// circuits on a null sink.
  ClassificationResult _emit(
    ClassificationResult result,
    ClassificationTarget target,
    Scope? scope,
  ) {
    final sink = _eventSink;
    if (sink != null) {
      sink(
        ClassificationComputed(
          target: target,
          decision: result.decision,
          bestMatch: result.bestMatch,
          bestSimilarity: result.bestSimilarity,
          secondSimilarity: result.secondSimilarity,
          occurredAt: _clock.now(),
          runId: scope?.runId,
          causedBy: scope?.causedBy,
        ),
      );
    }
    return result;
  }

  ClassificationDecision _decide(double best, double second) {
    if (best < _config.minConfidence) {
      return ClassificationDecision.unknown;
    }
    if ((best - second) < _config.minMargin) {
      return ClassificationDecision.uncertain;
    }
    return ClassificationDecision.confident;
  }

  static String _prefixFor(ClassificationTarget target) {
    switch (target) {
      case ClassificationTarget.nodeType:
        return CentroidStore.nodeTypeKeyPrefix;
      case ClassificationTarget.procedure:
        return CentroidStore.procedureKeyPrefix;
    }
  }

  static String _stripPrefix(String key, String prefix) {
    // Defensive — `readAll(prefix: ...)` guarantees the prefix is
    // present, but stripping a non-prefixed string would silently
    // produce wrong output. This is a decode of a value crossing from
    // the centroid store, so it must fail in release too (an `assert`
    // is compiled out): throw if a future migration ever writes a
    // different key shape.
    if (!key.startsWith(prefix)) {
      throw StateError(
        'Classifier: centroid key "$key" missing expected '
        'namespace prefix "$prefix"',
      );
    }
    return key.substring(prefix.length);
  }
}
