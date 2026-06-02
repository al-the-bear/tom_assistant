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
// ── What D.29 implements (this file) ────────────────────────────────
//
// The stepping mechanism itself: classify each version's failure, and on
// a fallback-class failure with an older version available, re-attempt at
// the next version down; otherwise surface the failure. Each attempt is
// recorded in the returned [FallbackOutcome] so the D.30 `ProcedureFallback`
// event emitter and the D.31 sustained-fallback `AutomationIdea` push can be
// built directly on top without re-deriving the chain walk.
//
// Deferred to later substeps (kept out of this file deliberately):
//   - D.30 — emit a `ProcedureFallback` event per fallback edge.
//   - D.31 — push an `AutomationIdea: revise procedure X` on sustained
//     fallback (≥ 3 within 24 h for the same id).
//
// In the prototype only `v1` of any procedure exists, so a chain is a
// singleton and a fallback-class failure on it has nowhere to step: the
// executor surfaces the failure (D.30), but the *machinery* — classify,
// walk, record — runs exactly as it will once multiple versions exist.

import '../procedure_store/procedure_loader.dart' show LoadedProcedure;
import '../procedure_store/procedure_resolver.dart' show ProcedureResolver;

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

/// The default [FailureClassifier] (def § 6, § 14).
///
///   - An [EnvironmentalFailure] never triggers fallback (`null`).
///   - A [ClassifiedFailure] triggers fallback when its [failureKind] is one
///     of the four [FallbackTrigger] classes, and surfaces otherwise.
///   - Any other uncaught error is a [FallbackTrigger.runtimeCrash] — an
///     unmarked error mid-run is a crash (def § 14), and a crash steps the
///     chain. Environmental failures must opt out via [EnvironmentalFailure].
FallbackTrigger? defaultFallbackClassifier(Object error) {
  if (error is EnvironmentalFailure) return null;
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
  /// step the chain (default: [defaultFallbackClassifier]).
  FallbackExecutor(this.resolver, {FailureClassifier? classifier})
      : classify = classifier ?? defaultFallbackClassifier;

  /// Resolves a procedure id to its fallback chain (C.25).
  final ProcedureResolver resolver;

  /// Decides which failures step the chain and which surface (PE-6).
  final FailureClassifier classify;

  /// Walks the fallback chain for [procedureId], attempting each version with
  /// [attempt] until one succeeds or the chain is exhausted / surfaces.
  ///
  /// Throws [ProcedureNotFound] (from [ProcedureResolver.fallbackChain]) when
  /// [procedureId] is unknown — there is no chain to walk. Otherwise always
  /// completes with a [FallbackOutcome]; the caller reads
  /// [FallbackOutcome.isSuccess] / [FallbackOutcome.valueOrThrow].
  Future<FallbackOutcome<T>> run<T>({
    required String procedureId,
    required VersionAttempt<T> attempt,
  }) async {
    final chain = resolver.fallbackChain(procedureId);
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
    // `fallbackChain` throws for an unknown id and never returns an empty
    // list for a known one, so the loop always returns above. This guards a
    // future change to that contract.
    throw StateError('fallback chain for "$procedureId" was empty');
  }
}
