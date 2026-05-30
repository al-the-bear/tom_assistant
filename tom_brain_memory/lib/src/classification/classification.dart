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
// A.65 will add `findUncertain` for the opt-in batch path. The
// concrete `SqliteTomBrainMemory` wires `update` into the abstract
// `TomBrainMemory.updateCentroid(forKey, centroid)` surface in a
// later A-step — see Q-A.63.2 in `prototype_implementation_questions.md`
// for why the abstract signature stays minimal.

export 'centroid_store.dart' show CentroidRecord, CentroidStore;
export 'classification_result.dart'
    show ClassificationDecision, ClassificationResult, ClassificationTarget;
export 'classifier.dart' show Classifier;
