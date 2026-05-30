// Barrel for the `embedding/` module (Plan step A.11).
//
// Exposes `Vec` plus the three free-function similarity / distance operations
// (`cosine`, `dot`, `l2`). `Vec.mean` is a static on the class. The internal
// `_requireSameDimension` and `_sqrt` helpers are deliberately not exported.

export 'vec.dart' show Vec, cosine, dot, l2;
