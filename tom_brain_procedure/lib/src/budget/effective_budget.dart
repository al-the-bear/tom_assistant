// effectiveProcedureBudget — the entry procedure's header budget tightened by a
// profile's per-dimension overrides (`session_configuration.md` § 3.1 / § 5.4;
// plan step 8 (d); SCP-34).
//
// A profile may carry a [ProfileBudget] override. The engine builds the run's
// enforced budget by *tightening* the entry procedure's header budget with each
// set profile dimension — a profile may only **lower** a cap, never raise one
// (the spec's "a profile may only tighten" / SC-8). The result is a
// [ProcedureBudget] the [BudgetLedger] enforces exactly as it does a header.
//
// ── Dimension mapping ───────────────────────────────────────────────
//
// `ProfileBudget` names its caps from the access/profile vocabulary; the
// procedure header names them from the ledger's vocabulary. The mapping is:
//
//   ProfileBudget.maxToolCalls → ProcedureBudget.toolCalls
//   ProfileBudget.maxTokens    → ProcedureBudget.tokenSpend
//   ProfileBudget.wallClock    → ProcedureBudget.wallClockMs  (ms)
//   ProfileBudget.maxLlmCalls  → (no procedure dimension — dropped)
//
// `maxLlmCalls` has **no** counterpart in `ProcedureBudget` / `BudgetLedger`
// (there is no `llmCalls` cap — token spend governs LLM cost; the same gap
// SCP-26 records). It is therefore dropped here: a future `llmCalls` ledger
// dimension would map it, but until then carrying it would be dead data the
// ledger never reads. `memoryWrites` has no `ProfileBudget` override, so the
// header's value (if any) always survives untouched.

import 'package:tom_brain_shared/tom_brain_shared.dart' show ProfileBudget;

import '../procedure_store/procedure_header.dart' show ProcedureBudget;

/// Tightens [header] with the set dimensions of [profile], returning the budget
/// the run's [BudgetLedger] enforces.
///
/// Each profile dimension can only *lower* the corresponding header cap: when
/// the header already caps a dimension, the result is `min(header, profile)`;
/// when the header omits it, the profile value fills it. A `null` [profile]
/// (or a profile with no set dimensions) returns [header] unchanged.
ProcedureBudget effectiveProcedureBudget(
  ProcedureBudget header,
  ProfileBudget? profile,
) {
  if (profile == null) return header;

  final raw = Map<String, int>.of(header.raw);

  void tighten(String dimension, int? value) {
    if (value == null) return;
    final existing = raw[dimension];
    raw[dimension] = existing == null ? value : (value < existing ? value : existing);
  }

  tighten('toolCalls', profile.maxToolCalls);
  tighten('tokenSpend', profile.maxTokens);
  tighten('wallClockMs', profile.wallClock?.inMilliseconds);
  // maxLlmCalls intentionally unmapped — no ledger dimension exists (SCP-34).

  return ProcedureBudget(raw);
}
