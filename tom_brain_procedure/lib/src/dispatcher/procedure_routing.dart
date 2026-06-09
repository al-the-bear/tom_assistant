// Procedure routing — the dispatcher's classify/select decision as one
// testable unit (Plan step D.16 / Q-E.50.1;
// `tom_brain_procedure_specification.md` § 10.2).
//
// The route the `Dispatcher` schedules has exactly one decision to make
// before it hands work to the coordinator: *which procedure id runs this
// access?* That decision has two branches (Q-E.50.1):
//
//   1. **Confident centroid hint (the fast path).** The Phase-E heuristic
//      classifier (E.33) pre-filled `access.envelope.kindHint` with a
//      *procedure id* — memory's centroid `bestMatch`. A non-blank hint is
//      routed directly via `ProcedureSelector.resolveHintedProcedure`,
//      bypassing the kind → procedure map. The dispatcher does not
//      re-classify a request the edge already classified.
//   2. **No hint (the fallback path).** A null/blank hint means the edge was
//      not confident; the no-hint classifier (`classify_inbound_v1` in the
//      prototype) produces an inbound *kind*, which
//      `ProcedureSelector.select` maps to a procedure id.
//
// Extracted here (rather than inlined in `BrainProcessBoot._buildRoute`)
// because the same two-branch decision is exercised by the D.17 / D.53 route
// integration tests; one tested function is the single source of truth for
// the branch, so production and tests cannot drift.

import 'package:tom_brain_shared/tom_brain_shared.dart' show Access;

import 'inbound_classifier.dart';
import 'procedure_selector.dart';

/// Resolves the procedure id to run for [access] (Q-E.50.1).
///
/// A confident `access.envelope.kindHint` (non-blank after trimming) is a
/// procedure id from the Phase-E centroid classifier (E.33); it routes
/// directly via [selector].`resolveHintedProcedure` (an unknown id raises
/// `UnknownProcedureHint`). Otherwise the no-hint [classifier] produces a
/// kind that [selector].`select` maps to a procedure id (an unknown kind
/// raises `UnsupportedProcedureKind`). Either failure propagates unchanged to
/// the caller (the D.14 contract).
String resolveProcedureId(
  Access access, {
  required InboundClassifier classifier,
  required ProcedureSelector selector,
}) {
  final hint = access.envelope.kindHint?.trim();
  if (hint != null && hint.isNotEmpty) {
    return selector.resolveHintedProcedure(hint);
  }
  return selector.select(classifier.classify(access));
}
