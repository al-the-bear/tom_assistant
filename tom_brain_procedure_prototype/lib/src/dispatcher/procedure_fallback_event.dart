// `ProcedureFallback` — the typed observability event the `FallbackExecutor`
// emits on every fallback-class failure (Plan step D.30;
// `tom_brain_procedure_prototype_specification.md` § 10.4 (PE-6), § 13;
// `tom_brain_definition.md` § 6, § 14).
//
// ── What def § 6 asks for ───────────────────────────────────────────
//
// "Every fallback emits a `ProcedureFallback` event. Sustained fallback
// against a specific version emits an `AutomationIdea: revise procedure X`
// pushed to the `automation_ideas` stack." This file owns the *event*; the
// `FallbackExecutor` (D.29) emits one per fallback-class failure (D.30); the
// sustained-fallback `AutomationIdea` push is D.31.
//
// ── What a fallback edge is ─────────────────────────────────────────
//
// A fallback fires when a procedure version fails with one of the four
// typed run-failure classes (`FallbackTrigger`). Two shapes:
//
//   - **Stepped down**: an older version exists, so the executor re-attempts
//     at [toVersion]. `surfaced` is `false`.
//   - **Surfaced**: the failing version is the oldest in the chain (in the
//     prototype, the permanent `v1`), so there is nowhere to step and the
//     failure surfaces to the caller. [toVersion] is `null`; `surfaced` is
//     `true`. This is the *only* fallback shape the prototype produces, since
//     every chain is the singleton `[v1]` — but the event still fires, so the
//     observability surface is exercised exactly as it will be once multiple
//     versions exist.
//
// ── Why this extends `BrainEvent` directly (not a `DispatcherEvent` base) ──
//
// The dispatcher half does not yet have a sealed `DispatcherEvent` family
// (it arrives with the D.47–D.50 config/observability surface). The existing
// dispatcher-side event family — `PreemptionEvent` (D.23) — also extends
// `BrainEvent` directly, so this matches the in-tree precedent: a one-off
// `BrainEvent` leaf is the right granularity until the family is built.
// Note: prototype spec § 13 lists a `DispatcherEvent` variant named
// `FallbackTried`; the plan (D.30) and definition (§ 6, § 14) name the event
// `ProcedureFallback`. This file uses the plan/definition name — see
// Q-D.30.1.

import 'package:tom_brain_shared/tom_brain_shared.dart' show BrainEvent;

import 'fallback_executor.dart' show FallbackTrigger;

/// A fallback edge fired during a `FallbackExecutor.run` chain walk (D.30).
///
/// One event is emitted per **fallback-class** failure (a `FallbackTrigger`
/// fired). A non-fallback failure (environmental, or a typed failure outside
/// the four classes) and a successful attempt produce no `ProcedureFallback`.
final class ProcedureFallback extends BrainEvent {
  /// The procedure id whose version chain was walked.
  final String procedureId;

  /// The version that failed and triggered this fallback.
  final int fromVersion;

  /// The next-older version the executor stepped down to, or `null` when the
  /// failing version was the oldest in the chain and the failure surfaced.
  final int? toVersion;

  /// The typed run-failure class that triggered the fallback.
  final FallbackTrigger trigger;

  ProcedureFallback({
    required super.occurredAt,
    super.runId,
    super.causedBy,
    required this.procedureId,
    required this.fromVersion,
    required this.toVersion,
    required this.trigger,
  });

  /// Whether the failure surfaced to the caller because [fromVersion] was the
  /// oldest version in the chain (no older version to step to).
  bool get surfaced => toVersion == null;

  @override
  String get kind => 'dispatcher.procedure-fallback';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'procedureId': procedureId,
        'fromVersion': fromVersion,
        if (toVersion != null) 'toVersion': toVersion,
        'trigger': trigger.failureKind,
        'surfaced': surfaced,
      };

  @override
  String toString() => surfaced
      ? 'ProcedureFallback($procedureId v$fromVersion → surfaced '
          '(${trigger.failureKind}))'
      : 'ProcedureFallback($procedureId v$fromVersion → v$toVersion '
          '(${trigger.failureKind}))';
}
