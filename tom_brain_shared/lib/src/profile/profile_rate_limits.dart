// ProfileRateLimits — the optional per-profile rate-limit envelope (spec
// § 3.1 / § 5.4, plan step 2).
//
// Each field is nullable: a null field means "inherit the per-principal global
// value". The edge (step 5) composes these with the per-principal quota by
// taking the *more restrictive* bound (SC-8 — a profile cannot raise a quota).
// Pure value type; the composition lives in `tom_brain_access`.

/// A per-profile rate-limit override. Any null field inherits the
/// per-principal global value (spec § 3.1).
final class ProfileRateLimits {
  /// Max requests per minute for this profile; null ⇒ inherit the global.
  final int? requestsPerMinute;

  /// Max concurrent runs for this profile; null ⇒ inherit the global.
  final int? concurrentRuns;

  const ProfileRateLimits({
    this.requestsPerMinute,
    this.concurrentRuns,
  });

  factory ProfileRateLimits.fromJson(Map<String, Object?> json) =>
      ProfileRateLimits(
        requestsPerMinute: json['requestsPerMinute'] as int?,
        concurrentRuns: json['concurrentRuns'] as int?,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'requestsPerMinute': requestsPerMinute,
        'concurrentRuns': concurrentRuns,
      };

  @override
  bool operator ==(Object other) =>
      other is ProfileRateLimits &&
      other.requestsPerMinute == requestsPerMinute &&
      other.concurrentRuns == concurrentRuns;

  @override
  int get hashCode => Object.hash(requestsPerMinute, concurrentRuns);

  @override
  String toString() => 'ProfileRateLimits(requestsPerMinute: '
      '$requestsPerMinute, concurrentRuns: $concurrentRuns)';
}
