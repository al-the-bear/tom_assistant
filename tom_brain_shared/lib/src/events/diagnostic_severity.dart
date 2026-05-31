// `DiagnosticSeverity` — the severity scale used by [DiagnosticEnvelope]
// (Plan step A.14).
//
// Five levels, matching the established TomLogger / RFC 5424 ordering
// pattern. The intent is to be a small, agreed vocabulary so that filters
// downstream of the event stream (Forge inspector, alerting in later
// phases, log routing) can apply uniform predicates such as
// `severity >= warning`.
//
// Ordering note: the enum order is the severity order. `severity.index`
// is the canonical numeric severity — `debug` < `info` < `notice` <
// `warning` < `error`. Comparison helpers ([atLeast], [operator <],
// [operator <=]) are provided so the comparison is named at call sites
// rather than relying on raw `.index` arithmetic.

/// Severity of a [DiagnosticEnvelope] for filtering and routing.
///
/// The enum order matches the severity order — see the module header.
enum DiagnosticSeverity {
  /// Verbose tracing useful only when debugging a specific subsystem.
  debug,

  /// Normal-operation events. The default.
  info,

  /// Notable but not actionable: a stack overflow into demotion, a recall
  /// that returned fewer than k results, a centroid drift over threshold.
  notice,

  /// Actionable but the system continued — e.g. a vec0 extension failed to
  /// load and recall degraded to BM25-only, an authority became
  /// unreachable and a mirror went read-only.
  warning,

  /// The originating operation failed. A persist that aborted, a procedure
  /// run that crashed, a migration that rolled back.
  error,
}

/// Comparison helpers on [DiagnosticSeverity].
///
/// Extension methods (not static globals) so call sites read naturally:
/// `envelope.severity.atLeast(DiagnosticSeverity.warning)`.
extension DiagnosticSeverityCompare on DiagnosticSeverity {
  /// True when this severity is at least as severe as [threshold].
  ///
  /// Idiomatic filter predicate:
  ///
  /// ```dart
  /// stream.where((env) => env.severity.atLeast(DiagnosticSeverity.warning));
  /// ```
  bool atLeast(DiagnosticSeverity threshold) => index >= threshold.index;

  /// True when this severity is strictly less severe than [other].
  bool operator <(DiagnosticSeverity other) => index < other.index;

  /// True when this severity is at most as severe as [other].
  bool operator <=(DiagnosticSeverity other) => index <= other.index;
}
