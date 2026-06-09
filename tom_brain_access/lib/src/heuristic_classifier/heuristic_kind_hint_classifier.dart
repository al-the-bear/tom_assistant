// Cheap kind-hint classifier — the access-side three-step heuristic (E.33;
// `tom_brain_access_specification.md` § 9.1; AC-9; def § 1.5).
//
// What this file owns:
//
//   * `HeuristicKindHintClassifier` — runs the three steps of § 9.1:
//       1. embed the inbound text (substrate's `EmbeddingService`),
//       2. classify the embedding against the procedure centroids
//          (memory's `classify(embedding, ClassificationTarget.procedure)`),
//       3. attach the returned procedure id as `InboundRequest.kindHint`
//          *only* when the decision is `confident`; otherwise null.
//   * `KindHintEmbedder` / `KindHintClassifier` — the two injected seams
//     that keep this package free of a `tom_brain_substrate` /
//     `tom_brain_memory` import (Plan E.7 dependency set; mirrors the E.16
//     `EmbeddingSource` decision).
//   * `KindHintClassification` / `KindHintDecision` — the access-local
//     result the classify seam returns. A faithful, decoupled mirror of
//     memory's `ClassificationResult` / `ClassificationDecision`: boot
//     (E.41+) adapts `TomBrainMemoryClient.classify(…,
//     ClassificationTarget.procedure)` into this shape; tests supply a
//     synthetic one.
//
// Why two seams rather than direct substrate / memory calls (proto spec
// § 14 dependency set, AC-13; Q logged in the details doc): the access
// layer never depends on `tom_brain_substrate` or `tom_brain_memory`
// (pubspec E.7 — both are *interface only*, reached through boot). The same
// injection discipline the E.16 embeddings route adopted (`EmbeddingSource`)
// is reused here: the classifier takes functions, not service types, so the
// classifier file imports neither. Boot binds the real `EmbeddingService`
// and the `classify`-with-`ClassificationTarget.procedure` call into the two
// seams; the `procedure` target is fixed *inside the seam*, so it never
// leaks into this package.
//
// What this file does NOT do (scope discipline — E.33 only):
//
//   * No embedding cache. The 5-min exact-text cache is E.34 (§ 9.2); this
//     step runs the embed call unconditionally. The cache wraps the
//     `KindHintEmbedder` seam without touching this class.
//   * No routing. The classifier supplies a *hint*; the dispatcher owns
//     selection (D.16, AC-9). A confident result is the dispatcher's
//     `kindHint` pass-through (D.15); an unconfident one leaves it null so
//     `classify_inbound_v1` takes over.
//   * No `Access` / `InboundRequest` assembly. The classifier returns the
//     hint *value*; building the `InboundRequest` (and thus the `Access`)
//     around it is the boot composition's job (E.41+), exactly as E.28 – E.32
//     left wire shaping to boot.
//   * No graceful-degradation catch. An embed / classify *failure* (the
//     seam throwing) propagates; the `access.classify.unavailable` →
//     null-hint degradation and its observability event are wired at boot
//     (§ 13.1 — E.41+). E.33 owns only the *uncertainty* path (a non-
//     confident decision → null), which is a decision-band check, not error
//     handling.

import 'dart:async';

/// Embeds one inbound prompt's text into a vector — the substrate seam.
///
/// Returns the embedding for [text], in the substrate embedding model's
/// vector space. Boot (E.41+) binds substrate's `EmbeddingService` into this
/// function; tests supply a synthetic one. Keeping it a function — not a
/// `tom_brain_substrate` type — is what keeps the classifier free of a
/// substrate dependency (Plan E.7; mirrors the E.16 `EmbeddingSource`
/// decision). E.34's cache slots in by wrapping this seam.
typedef KindHintEmbedder = Future<List<double>> Function(String text);

/// Classifies an embedding against the procedure centroids — the memory seam.
///
/// Returns the [KindHintClassification] for [embedding]. Boot (E.41+) binds
/// memory's `classify(embedding, ClassificationTarget.procedure)` into this
/// function — the `ClassificationTarget.procedure` target is fixed *inside*
/// the seam, so it never leaks into this package. Tests supply a synthetic
/// one. Keeping it a function — not a `tom_brain_memory` type — is what keeps
/// the classifier free of a memory dependency (Plan E.7; both are interface-
/// only, reached through boot).
typedef KindHintClassifier = Future<KindHintClassification> Function(
  List<double> embedding,
);

/// The decision band of a kind-hint classification.
///
/// A faithful, access-local mirror of memory's `ClassificationDecision`
/// (`memory_specification.md` § 7.2). Boot maps memory's enum onto this one;
/// the classifier branches on it. Only [confident] yields a hint (AC-9).
enum KindHintDecision {
  /// The best procedure centroid is a confident match (similarity ≥ the
  /// confidence floor AND the margin to the runner-up is wide enough).
  /// The classifier attaches the matched procedure id as the hint.
  confident,

  /// A plausible best match with a tight margin to the runner-up — too
  /// weak to route on. The classifier supplies *no* hint; the dispatcher's
  /// `classify_inbound_v1` decides (D.15).
  uncertain,

  /// No procedure centroid is a plausible match (below the confidence
  /// floor, or a cold start with no centroids yet). No hint.
  unknown,
}

/// The result the [KindHintClassifier] seam returns — an access-local mirror
/// of memory's `ClassificationResult` (`memory_specification.md` § 7).
///
/// Immutable value object. [procedureId] is the best-matching procedure id
/// (memory's `bestMatch`); it is `null` for an [KindHintDecision.unknown]
/// cold-start case and may be present-but-ignored for the non-confident
/// bands. The classifier reads [decision] first and only consults
/// [procedureId] on a [KindHintDecision.confident] result.
final class KindHintClassification {
  /// The decision band — drives the classifier's confident-only branching.
  final KindHintDecision decision;

  /// The best-matching procedure id (memory's `bestMatch`), or `null` when
  /// no centroid matched (cold start). Only consulted on a [confident]
  /// decision.
  final String? procedureId;

  /// Builds the classification. [decision] is required; [procedureId] is
  /// optional because the cold-start `unknown` case has no best match.
  const KindHintClassification({
    required this.decision,
    this.procedureId,
  });

  /// The cold-start case: no centroids exist for the procedure target yet.
  /// Convenience for tests and for the seam's pre-centroid return.
  const KindHintClassification.unknown()
      : decision = KindHintDecision.unknown,
        procedureId = null;

  @override
  bool operator ==(Object other) =>
      other is KindHintClassification &&
      other.decision == decision &&
      other.procedureId == procedureId;

  @override
  int get hashCode => Object.hash(decision, procedureId);

  @override
  String toString() =>
      'KindHintClassification(decision: $decision, procedureId: $procedureId)';
}

/// The access-side cheap kind-hint classifier (E.33; § 9.1; AC-9).
///
/// Runs the three steps of § 9.1 over one inbound prompt's text and returns
/// the procedure-id hint to attach as `InboundRequest.kindHint` — or `null`
/// when the classification is not confident, in which case the dispatcher's
/// `classify_inbound_v1` (D.15) takes over.
///
/// The classifier **never routes** (AC-9): it only supplies a hint the
/// dispatcher is free to use. It is the *cheap* path and is allowed to be
/// silent — uncertainty is a `null` hint, not an error.
final class HeuristicKindHintClassifier {
  /// Builds the classifier over the two injected seams. Boot (E.41+) binds
  /// the real substrate / memory calls; tests supply synthetic ones.
  const HeuristicKindHintClassifier({
    required KindHintEmbedder embedder,
    required KindHintClassifier classifier,
  })  : _embedder = embedder,
        _classifier = classifier;

  final KindHintEmbedder _embedder;
  final KindHintClassifier _classifier;

  /// Classifies [text] into a confident-only procedure-id hint.
  ///
  /// Steps (§ 9.1):
  ///   1. **Embed** [text] via the [KindHintEmbedder] seam.
  ///   2. **Classify** the embedding via the [KindHintClassifier] seam (which
  ///      boot binds to `classify(embedding, ClassificationTarget.procedure)`).
  ///   3. **Hint**: on a [KindHintDecision.confident] result with a non-blank
  ///      procedure id, return that id (trimmed). Otherwise return `null`.
  ///
  /// A confident decision whose `procedureId` is `null` or blank still
  /// returns `null`: a hint must name a procedure, and "confident about
  /// nothing" is not a routable hint — it degrades to the un-hinted path
  /// rather than attaching an empty string the dispatcher would have to
  /// special-case.
  ///
  /// [text] is the caller-validated inbound prompt body
  /// (`InboundRequest.text`, already guaranteed non-empty at construction),
  /// so this method does not re-validate it — it trusts the boundary that
  /// produced it.
  ///
  /// Seam *failures* (the embedder or classifier throwing) propagate: the
  /// `access.classify.unavailable` graceful-degradation path and its event
  /// are boot's concern (§ 13.1, E.41+), not this method's.
  Future<String?> classifyKindHint(String text) async {
    final List<double> embedding = await _embedder(text);
    final KindHintClassification result = await _classifier(embedding);
    if (result.decision != KindHintDecision.confident) {
      return null;
    }
    final String? procedureId = result.procedureId?.trim();
    if (procedureId == null || procedureId.isEmpty) {
      return null;
    }
    return procedureId;
  }
}
