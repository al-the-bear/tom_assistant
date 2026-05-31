// Barrel for the `version/` module (Plan step A.16).
//
// Module surface:
//
//   * `BrainVersion` — monotonic positive-integer version value type.
//                      Equality + hash by value; total ordering via
//                      `compareTo` + `<` / `<=` / `>` / `>=`;
//                      successor via `next()`; immediate-neighbour
//                      predicates `isImmediateSuccessorOf` and
//                      `isImmediatePredecessorOf`; parse / toString
//                      round-trip on the `"v<digits>"` form.
//
// What is deliberately NOT here:
//
//   * No semver triple (major.minor.patch). Every consumer in the
//     brain (procedure revisions, schema migrations, node-type
//     registry, stack-policy revisions) needs *total order only*. A
//     semver wrapper around [BrainVersion] is fine in a downstream
//     package; the shared layer keeps the primitive as the lowest
//     common factor.
//   * No "version 0 = no version yet" sentinel. The optionality is
//     carried by `Maybe<BrainVersion>` (see `result/maybe.dart`),
//     not encoded into the integer range. [BrainVersion] is always
//     ≥ 1.
//   * No time link. Versions are advanced by explicit `next()` (or
//     by the migration writer setting an exact value); clocks have
//     nothing to do with it.
//   * No "branching" or alternate timelines. Versions are a strict
//     total order. Branching is modelled in memory at the edge
//     level (`superseded_by` edges form the revision graph; the
//     [BrainVersion] on each node only orders them within a
//     chain).

export 'brain_version.dart' show BrainVersion;
