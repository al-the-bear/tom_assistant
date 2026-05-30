// Barrel for the `classification/` module (A.23 layout; A.24 surface).
//
// At A.24 this barrel exports:
//
//   - `ClassificationTarget` — match-against discriminator
//     (NodeType vs Procedure centroids).
//   - `ClassificationDecision` — confident / uncertain / unknown.
//   - `ClassificationResult` — `classify()` return value.
//
// The centroid table, the `updateCentroid` write path, and the
// `findUncertain` batch surface land at A.63 – A.66.

export 'classification_result.dart'
    show ClassificationDecision, ClassificationResult, ClassificationTarget;
