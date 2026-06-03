// CritiqueHook — the seam memory uses to ask "does this new node-type
// proposal overlap with what we already have?" without ever calling an
// LLM itself.
//
// Plan step A.33:
//   "Implement `registerNodeType` + validation (overlap check delegated
//    to a caller-provided critique hook so memory stays LLM-free)."
//
// Hard invariant #2 in the memory specification ("Memory does not call
// LLMs on the hot path") is structural, not advisory. The registry
// cannot be tempted to "just call a model here" because it has no model
// dependency in scope — instead it consults whatever async function the
// caller wired in. In production that function routes through
// `critique_v1` on the procedure engine, which carries the
// assistant-dedication anchor on every prompt; in tests it is a small
// in-process predicate. Memory is none the wiser either way.
//
// What the hook is for, and what it is not for:
//
//   - For: overlap / redundancy judgement — "is this proposal actually
//     the same shape as an existing type with different wording?" The
//     existing types are passed as the second argument exactly so the
//     hook can reason about overlap.
//   - For: domain veto — a hook may reject for any reason (e.g. naming
//     drift from a previously-rejected proposal, conflict with a
//     restructure-in-progress).
//   - NOT for: structural validation. PascalCase, schema non-empty,
//     supersedes-version monotonicity — those are pure registry
//     business and run *before* the hook ever sees the proposal. A
//     malformed decl never reaches the hook.
//   - NOT for: persistence. Approval is an *opinion*; the registry
//     decides when to commit and emits the event.
//
// Why a sealed result type rather than `bool`:
//
//   - A "no" without a reason is debug-hostile. Rejection forces the
//     caller to supply prose, and (optionally) to point at the
//     conflicting type(s) so the operator log shows *why*.
//   - An approval with a note lets the hook record subtle remarks the
//     registry can fold into its emitted event ("approved — overlaps
//     `Pattern` weakly, watch for drift").
//
// The hook is always async — production callers are remote (procedure
// engine) and we don't want a synchronous-vs-asynchronous shim layer
// the day we switch test fakes for the real one.

import 'package:tom_brain_shared/tom_brain_shared.dart' show NodeTypeDecl;

/// Outcome of a critique pass over a candidate [NodeTypeDecl].
///
/// Sealed so the registry's commit/refuse branch is exhaustive at
/// compile time. Adding a new outcome shape is intentionally a
/// breaking change in this layer.
sealed class CritiqueOutcome {
  const CritiqueOutcome();
}

/// Hook approved the proposal. Optional [note] is included verbatim in
/// the `NodeTypeRegistered` event so the operator log preserves the
/// hook's reasoning.
final class CritiqueApproved extends CritiqueOutcome {
  /// Free-form remark from the hook (e.g. "overlaps `Pattern` weakly").
  /// `null` when the hook had nothing extra to say.
  final String? note;

  const CritiqueApproved({this.note});

  @override
  String toString() =>
      note == null ? 'CritiqueApproved' : 'CritiqueApproved($note)';
}

/// Hook refused the proposal. [reason] is required; [conflictingTypeNames]
/// points at the existing types the hook thinks overlap (empty when the
/// refusal is for a non-overlap reason, e.g. drift from a previous
/// refused name).
///
/// Renamed from `CritiqueRejected` at A.69 to free that name for the
/// shaking-event sub-kind declared in spec § 9.4. See Q-A.69.1 in
/// `prototype_implementation_questions.md` for the rationale. The two
/// concepts are unrelated: this class is a synchronous outcome returned
/// by the node-type proposal critique hook; the shaking-event leaf is
/// a typed `MemoryEvent` raised by sleep-cycle agents.
final class CritiqueRefused extends CritiqueOutcome {
  /// Human-readable explanation. Surfaces verbatim in
  /// `NodeTypeRejected` (the failure thrown by `registerNodeType`).
  final String reason;

  /// Names of existing types the hook considers overlapping. Empty list
  /// is legal — not every refusal is about overlap.
  final List<String> conflictingTypeNames;

  const CritiqueRefused({
    required this.reason,
    this.conflictingTypeNames = const <String>[],
  });

  @override
  String toString() => conflictingTypeNames.isEmpty
      ? 'CritiqueRefused($reason)'
      : 'CritiqueRefused($reason; conflicts: ${conflictingTypeNames.join(", ")})';
}

/// Caller-supplied function that judges a candidate node-type proposal
/// against the existing registry.
///
/// Contract:
///
///   * MUST be pure with respect to the registry — implementations must
///     not call back into `registerNodeType`, `persist`, `edge`, or any
///     other memory write surface. The registry will deadlock or
///     re-enter undefined state if violated.
///   * MAY perform I/O (procedure-engine round trip, LLM completion);
///     the registry awaits the future and treats long latencies as
///     "still in progress" — no built-in timeout. Callers responsible
///     for budgeting hand the hook a wrapper that cancels.
///   * MUST NOT throw for "refusal" — return `CritiqueRefused`
///     instead. An exception from the hook is treated as a
///     **hook crash** by the registry and surfaces as
///     `NodeTypeRejected(reason: 'critique hook crashed: …')`.
///   * MAY ignore [existingTypes] when the hook has its own store of
///     prior types (e.g. when the procedure engine maintains a richer
///     index than the registry exposes). The argument is provided as a
///     convenience, not a contract.
///
/// In tests the typical shape is:
///
/// ```dart
/// CritiqueHook approveAll() =>
///     (_, __) async => const CritiqueApproved();
///
/// CritiqueHook rejectIfNameContains(String fragment) =>
///     (decl, _) async => decl.typeName.contains(fragment)
///         ? CritiqueRefused(reason: 'name contains "$fragment"')
///         : const CritiqueApproved();
/// ```
typedef CritiqueHook = Future<CritiqueOutcome> Function(
  NodeTypeDecl proposal,
  List<NodeTypeDecl> existingTypes,
);
