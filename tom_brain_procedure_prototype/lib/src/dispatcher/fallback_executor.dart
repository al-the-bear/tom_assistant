// FallbackExecutor — walks a procedure's version chain on the typed
// run-failure classes (Plan step D.29;
// `tom_brain_procedure_prototype_specification.md` § 10.4 (PE-6);
// `tom_brain_definition.md` § 6).
//
// ── What PE-6 asks for ──────────────────────────────────────────────
//
// Every procedure has a monotonic `version` per `id`; `version: 1` of a
// system procedure is the permanent safety net and is never demoted. The
// dispatcher maintains an ordered **fallback chain** `[v_latest, …, v1]`
// per id (the [ProcedureResolver.fallbackChain] this executor drives). On
// these four typed run-failure classes — and *only* these — the executor
// steps down to the next-older accepted version:
//
//   - `procedure.contract.violation`
//   - `procedure.critique.rejected` (after retry budget exhausted)
//   - `procedure.deadline.exceeded` with no useful partial result
//   - `procedure.runtime.crash`
//
// **Environmental** failures (substrate-down, network-down, billing) do
// **not** trigger fallback: a newer version cannot fix the environment,
// so stepping down would only burn budget on a doomed retry. They surface
// immediately.
//
// ── What D.29 implements ────────────────────────────────────────────
//
// The stepping mechanism itself: classify each version's failure, and on
// a fallback-class failure with an older version available, re-attempt at
// the next version down; otherwise surface the failure. Each attempt is
// recorded in the returned [FallbackOutcome] so the D.31 sustained-fallback
// `AutomationIdea` push can be built directly on top without re-deriving the
// chain walk.
//
// ── What D.30 adds (this file + the `FallbackTried` variant) ─────────
//
// The fallback event emission. The executor takes an optional
// [FallbackEventSink]; on **every** fallback-class failure (a
// [FallbackTrigger] fired) it emits one [FallbackTried] — `surfaced:
// false` carrying `toVersion` when an older version exists (a step-down),
// `surfaced: true` with `toVersion: null` when the failing version is the
// oldest in the chain (the failure surfaces). Non-fallback failures
// (environmental, or a typed failure outside the four classes) and successes
// emit nothing. Def § 6: "Every fallback emits a fallback event."
//
// [FallbackTried] is the single fallback event — both the executor's
// `FallbackEventSink` emission here and the closed-taxonomy
// `DispatcherEvent` variant (it lives in `dispatcher_event.dart`). The
// earlier working name `ProcedureFallback` and its copy factory were
// collapsed into the one spec-named event (Q-D.30.1 / Q-D.49.2): a duplicate
// event with a 1:1 copy factory is a DRY weak point. See the
// `dispatcher_event.dart` header.
//
// ── What D.31 adds (kept out of this file) ──────────────────────────
//
// The aggregate sustained-fallback signal lives in
// `sustained_fallback_monitor.dart`: `SustainedFallbackMonitor` is a windowed
// counter over the [FallbackTried] stream this executor emits — on ≥ 3
// fallback edges within 24 h for one procedure *version* it pushes one
// `AutomationIdea: revise procedure X` onto the `automation_ideas` stack. Wire
// it to this executor via `monitor.asSink` as the `onFallback` sink.
//
// In the prototype only `v1` of any procedure exists, so a chain is a
// singleton and a fallback-class failure on it has nowhere to step: the
// executor surfaces the failure, but still emits one [FallbackTried]
// (`surfaced: true`), so the observability surface is exercised exactly as it
// will be once multiple versions exist.

import 'package:tom_brain_shared/tom_brain_shared.dart' show defaultNowUtc;

import '../budget/procedure_budget_exceeded.dart' show ProcedureBudgetExceeded;
import '../d4rt_host/procedure_parse_exception.dart'
    show ProcedureSourceParseException;
import '../procedure_store/procedure_loader.dart' show LoadedProcedure;
import '../procedure_store/procedure_resolver.dart' show ProcedureResolver;
import 'dispatcher_event.dart' show FallbackTried;

/// The four typed run-failure classes that step the fallback chain down to
/// an older version (def § 6, spec § 10.4, PE-6).
///
/// These are the *only* failures that trigger fallback. Anything else — an
/// [EnvironmentalFailure], or a typed failure whose kind is not one of these
/// four — surfaces without stepping the chain.
enum FallbackTrigger {
  /// The procedure's `run` returned something other than a `ProcedureResult`,
  /// or a result that violated its declared contract.
  contractViolation('procedure.contract.violation'),

  /// A critic rejected the run's result after the retry budget was exhausted.
  critiqueRejected('procedure.critique.rejected'),

  /// The run exceeded its hard step deadline with no useful partial result.
  deadlineExceeded('procedure.deadline.exceeded'),

  /// The run threw an uncaught error mid-execution.
  runtimeCrash('procedure.runtime.crash');

  const FallbackTrigger(this.failureKind);

  /// The wire string that names this failure class (def § 14).
  final String failureKind;

  /// The trigger for [failureKind], or `null` when [failureKind] is not one
  /// of the four fallback-class strings.
  static FallbackTrigger? forKind(String failureKind) {
    for (final trigger in values) {
      if (trigger.failureKind == failureKind) return trigger;
    }
    return null;
  }
}

/// A failure that names its typed failure class (def § 14), so the executor
/// can classify it without string-matching an error message.
///
/// `RunDeadlineExceeded` implements this; the four trigger classes a
/// procedure run can surface should too. A failure that does not carry a
/// classification is treated as a [FallbackTrigger.runtimeCrash] by
/// [defaultFallbackClassifier] (an uncaught error is a crash, def § 14).
abstract interface class ClassifiedFailure {
  /// The typed failure class string (e.g. `procedure.runtime.crash`).
  String get failureKind;
}

/// A failure caused by the environment rather than the procedure itself —
/// substrate-down, network-down, or billing (PE-6).
///
/// These never step the fallback chain regardless of any kind string they
/// might also carry: a newer procedure version cannot repair the
/// environment. Mark such an error with this interface so
/// [defaultFallbackClassifier] surfaces it instead of treating it as a
/// runtime crash.
abstract interface class EnvironmentalFailure {}

/// Classifies a thrown [error] into the [FallbackTrigger] that should step
/// the chain, or `null` when the failure must surface without fallback.
typedef FailureClassifier = FallbackTrigger? Function(Object error);

/// Attempts one [version] of a procedure, completing with its value or
/// throwing the failure the executor classifies.
typedef VersionAttempt<T> = Future<T> Function(LoadedProcedure version);

/// Sink the executor calls with each [FallbackTried] it emits (D.30).
///
/// Injected into [FallbackExecutor]; the composition root wires it to the
/// dispatcher's event bus, and the D.31 sustained-fallback counter subscribes
/// to the same stream. `null` (the default) disables emission.
typedef FallbackEventSink = void Function(FallbackTried event);

/// Clock the executor stamps onto every emitted event's `occurredAt` (D.30).
///
/// Must return a UTC `DateTime` (`BrainEvent.toJson` asserts the invariant).
/// Injectable so a test can stamp deterministic timestamps instead of the
/// wall clock — the same seam as `PreemptionController`'s `PreemptionClock`.
typedef FallbackClock = DateTime Function();

/// The default [FailureClassifier] (def § 6, § 14).
///
///   - An [EnvironmentalFailure] never triggers fallback (`null`).
///   - A [ProcedureSourceParseException] never triggers fallback (`null`):
///     a parse failure (`procedure.parse.failed`, § 10.4) means the procedure
///     never ran, and an older version cannot repair a syntactically broken
///     newer source — stepping the chain would mask the fault and silently run
///     stale logic (Q-C.46.1). It surfaces without stepping, like any
///     non-fallback class.
///   - A [ProcedureBudgetExceeded] never triggers fallback (`null`): a budget
///     refusal (`procedure.budget.exceeded`, PE-8) is a deliberate stop, not a
///     fault in the version. An older version would run against the same
///     header budget and hit the same cap, so stepping the chain would only
///     burn budget on a doomed retry — exactly like an environmental failure.
///     It surfaces without stepping.
///   - A [ClassifiedFailure] triggers fallback when its [failureKind] is one
///     of the four [FallbackTrigger] classes, and surfaces otherwise.
///   - Any other uncaught error is a [FallbackTrigger.runtimeCrash] — an
///     unmarked error mid-run is a crash (def § 14), and a crash steps the
///     chain. Environmental failures must opt out via [EnvironmentalFailure].
FallbackTrigger? defaultFallbackClassifier(Object error) {
  if (error is EnvironmentalFailure) return null;
  if (error is ProcedureSourceParseException) return null;
  if (error is ProcedureBudgetExceeded) return null;
  if (error is ClassifiedFailure) {
    return FallbackTrigger.forKind(error.failureKind);
  }
  return FallbackTrigger.runtimeCrash;
}

/// One version's attempt within a [FallbackOutcome]'s chain walk (D.29).
///
/// Records which [version] was attempted, whether it [succeeded], and — for
/// a failure — the [FallbackTrigger] it classified to ([trigger] is `null`
/// for a success *or* for a non-fallback failure that surfaced) and the
/// captured [error].
final class FallbackAttempt {
  const FallbackAttempt._(
    this.version,
    this.succeeded,
    this.trigger,
    this.error,
  );

  /// A version that produced a usable value.
  const FallbackAttempt.succeeded(int version)
      : this._(version, true, null, null);

  /// A version that failed. [trigger] is the classified fallback class when
  /// the failure was a fallback-class one, or `null` when it was not (an
  /// environmental / non-fallback failure that surfaced without stepping).
  const FallbackAttempt.failed(int version, FallbackTrigger? trigger, Object error)
      : this._(version, false, trigger, error);

  /// The procedure version this attempt ran.
  final int version;

  /// Whether the attempt produced a usable value.
  final bool succeeded;

  /// The classified fallback trigger, or `null` for a success or a
  /// non-fallback failure.
  final FallbackTrigger? trigger;

  /// The captured failure, or `null` on success.
  final Object? error;

  @override
  String toString() => succeeded
      ? 'FallbackAttempt(v$version → ok)'
      : 'FallbackAttempt(v$version → ${trigger?.failureKind ?? 'surfaced'})';
}

/// The result of a [FallbackExecutor.run] chain walk (D.29).
///
/// Carries the procedure id, the ordered [attempts] (one per version the
/// executor tried, newest-first), and the terminal value or surfaced error.
/// Immutable; [attempts] is wrapped unmodifiable on construction.
final class FallbackOutcome<T> {
  FallbackOutcome._success(
    this.procedureId,
    List<FallbackAttempt> attempts,
    this.value,
  )   : attempts = List<FallbackAttempt>.unmodifiable(attempts),
        _succeeded = true,
        error = null,
        stackTrace = null;

  FallbackOutcome._failure(
    this.procedureId,
    List<FallbackAttempt> attempts,
    this.error,
    this.stackTrace,
  )   : attempts = List<FallbackAttempt>.unmodifiable(attempts),
        _succeeded = false,
        value = null;

  /// The procedure id the executor walked the chain for.
  final String procedureId;

  /// The ordered attempts the executor made, newest version first.
  final List<FallbackAttempt> attempts;

  /// The value a version produced, or `null` when the whole chain failed.
  final T? value;

  /// The surfaced failure when the whole chain failed; `null` on success.
  final Object? error;

  /// The stack trace captured with [error]; `null` on success.
  final StackTrace? stackTrace;

  final bool _succeeded;

  /// Whether some version produced a usable value.
  bool get isSuccess => _succeeded;

  /// The number of versions the executor attempted.
  int get versionsAttempted => attempts.length;

  /// The attempts on which a fallback-class failure fired (those that either
  /// stepped the chain down or surfaced because the chain was exhausted).
  Iterable<FallbackAttempt> get fallbackFailures =>
      attempts.where((a) => a.trigger != null);

  /// The value when the chain succeeded; otherwise rethrows the surfaced
  /// [error] with its original [stackTrace].
  T get valueOrThrow => _succeeded
      ? value as T
      : Error.throwWithStackTrace(error!, stackTrace ?? StackTrace.current);

  @override
  String toString() => isSuccess
      ? 'FallbackOutcome($procedureId → ok after $versionsAttempted attempt(s))'
      : 'FallbackOutcome($procedureId → failed after $versionsAttempted attempt(s))';
}

/// Walks a procedure's version chain on the typed run-failure classes
/// (Plan D.29; spec § 10.4, PE-6).
///
/// For a procedure id, the executor resolves the fallback chain
/// `[v_latest, …, v1]` through [resolver] and attempts each version in turn
/// via the caller-supplied [VersionAttempt]. A version that succeeds ends
/// the walk; a version that fails is classified by [classify], and:
///
///   - a **fallback-class** failure with an older version available steps
///     down to the next version;
///   - any other failure (environmental, a non-fallback typed failure, or a
///     fallback-class failure on the *oldest* version) surfaces and ends the
///     walk.
///
/// The executor never decides *what* a version does (that is the engine,
/// driven by the caller's [VersionAttempt]); it owns only *which* version to
/// try next when a fallback-class failure occurs.
final class FallbackExecutor {
  /// Builds an executor over [resolver]. [classifier] decides which failures
  /// step the chain (default: [defaultFallbackClassifier]). [onFallback], when
  /// supplied, receives a [FallbackTried] on every fallback-class failure
  /// (D.30); [clock] stamps those events' `occurredAt` (default: the UTC wall
  /// clock).
  FallbackExecutor(
    this.resolver, {
    FailureClassifier? classifier,
    FallbackEventSink? onFallback,
    FallbackClock? clock,
  })  : classify = classifier ?? defaultFallbackClassifier,
        _onFallback = onFallback,
        _clock = clock ?? defaultNowUtc;

  /// Resolves a procedure id to its fallback chain (C.25).
  final ProcedureResolver resolver;

  /// Decides which failures step the chain and which surface (PE-6).
  final FailureClassifier classify;

  /// Sink for [FallbackTried] events, or `null` to disable emission.
  final FallbackEventSink? _onFallback;

  /// Stamps `occurredAt` on every emitted [FallbackTried].
  final FallbackClock _clock;

  /// Walks the fallback chain for [procedureId], attempting each version with
  /// [attempt] until one succeeds or the chain is exhausted / surfaces.
  ///
  /// [runId] / [causedBy] are threaded onto every emitted [FallbackTried]
  /// so a consumer can stitch the fallback into the run's causal trace.
  ///
  /// Throws [ProcedureNotFound] (from [ProcedureResolver.fallbackChain]) when
  /// [procedureId] is unknown — there is no chain to walk. Otherwise always
  /// completes with a [FallbackOutcome]; the caller reads
  /// [FallbackOutcome.isSuccess] / [FallbackOutcome.valueOrThrow].
  Future<FallbackOutcome<T>> run<T>({
    required String procedureId,
    required VersionAttempt<T> attempt,
    String? runId,
    String? causedBy,
  }) async {
    final chain = resolver.fallbackChain(procedureId);
    // `fallbackChain` throws `ProcedureNotFound` for an unknown id and never
    // returns an empty list for a known one. Fail fast at the boundary if that
    // contract is ever broken, rather than falling through the loop to a
    // trailing throw that reads as dead code (F.3.4).
    if (chain.isEmpty) {
      throw StateError('fallback chain for "$procedureId" was empty');
    }
    final attempts = <FallbackAttempt>[];
    for (var i = 0; i < chain.length; i++) {
      final loaded = chain[i];
      final version = loaded.header.version;
      final hasOlderVersion = i < chain.length - 1;
      try {
        final value = await attempt(loaded);
        attempts.add(FallbackAttempt.succeeded(version));
        return FallbackOutcome<T>._success(procedureId, attempts, value);
      } catch (error, stackTrace) {
        final trigger = classify(error);
        attempts.add(FallbackAttempt.failed(version, trigger, error));
        final stepsDown = trigger != null && hasOlderVersion;
        // D.30: every fallback-class failure emits a `FallbackTried` —
        // a step-down carries the next-older `toVersion`; a fallback-class
        // failure on the oldest version surfaces with `toVersion: null`.
        if (trigger != null) {
          _emitFallback(
            procedureId: procedureId,
            fromVersion: version,
            toVersion: stepsDown ? chain[i + 1].header.version : null,
            trigger: trigger,
            runId: runId,
            causedBy: causedBy,
          );
        }
        if (!stepsDown) {
          return FallbackOutcome<T>._failure(
            procedureId,
            attempts,
            error,
            stackTrace,
          );
        }
        // Fallback-class failure with an older version available: step down
        // and re-attempt at the next version in the chain.
      }
    }
    // Unreachable: the chain is non-empty (guarded above) and every loop
    // iteration either returns or steps down, with the last iteration
    // (`!hasOlderVersion`) always returning. Present only so Dart's
    // definite-return analysis accepts the method.
    throw StateError('fallback chain walk for "$procedureId" did not return');
  }

  /// Builds and emits one [FallbackTried] when a sink is wired (D.30).
  void _emitFallback({
    required String procedureId,
    required int fromVersion,
    required int? toVersion,
    required FallbackTrigger trigger,
    required String? runId,
    required String? causedBy,
  }) {
    final sink = _onFallback;
    if (sink == null) return;
    sink(FallbackTried(
      occurredAt: _clock(),
      runId: runId,
      causedBy: causedBy,
      procedureId: procedureId,
      fromVersion: fromVersion,
      toVersion: toVersion,
      trigger: trigger,
    ));
  }
}
