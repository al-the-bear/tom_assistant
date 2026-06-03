// Barrel for the `classification/` module.
//
// At A.24 this barrel exported only the result-type triad
// (`ClassificationTarget` / `ClassificationDecision` /
// `ClassificationResult`) used by `TomBrainMemory.classify`'s
// abstract signature.
//
// At A.63 the centroid storage layer landed:
//
//   * `CentroidRecord` — one row of the `centroids` table.
//   * `CentroidStore` — `memory.db`-side storage with the
//     `update` write path (the underlying implementation of
//     `TomBrainMemory.updateCentroid`), plus `read`, `readAll`,
//     `listKeys`, and `count` for the classifier (A.64) and
//     `findUncertain` (A.65) to build on.
//
// At A.64 the read-side classifier lands:
//
//   * `Classifier` — wraps a `CentroidStore` and applies the
//     spec § 7.2 `minConfidence` + `minMargin` decision rule,
//     including the spec § 7.1 cold-start gate
//     (`coldStartMinExamples`). Sync method; the concrete
//     `SqliteTomBrainMemory.classify` (later A-step) wraps with
//     `Future.value(...)` to satisfy the abstract surface.
//
// At A.65 the opt-in batch path lands:
//
//   * `UncertainCandidate` — one borderline candidate with similarity.
//   * `UncertainFinder` — wraps a `CentroidStore` + `VectorTable` +
//     `memory.db` handle and returns node ids whose centroid
//     similarity falls in a `[low, high]` band. The opt-in batch
//     consumer (`dream_recentroid_v1`) reads these to feed an LLM-batch
//     re-classification (spec § 7.4). Memory never originates the call.
//
// The concrete `SqliteTomBrainMemory` wires `update` into the abstract
// `TomBrainMemory.updateCentroid(forKey, centroid)` surface and the
// `UncertainFinder.find` into the abstract
// `TomBrainMemory.findUncertain(forKey, low, high, limit)` surface in
// a later A-step — see Q-A.63.2 in
// `prototype_implementation_questions.md` for why the abstract
// signatures stay minimal.

export 'centroid_store.dart' show CentroidRecord, CentroidStore;
export 'classification_events.dart'
    show CentroidUpdated, ClassificationComputed;
export 'classification_result.dart'
    show ClassificationDecision, ClassificationResult, ClassificationTarget;
export 'classifier.dart' show Classifier;
export 'uncertain_finder.dart' show UncertainCandidate, UncertainFinder;
