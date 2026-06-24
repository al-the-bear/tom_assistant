// ProfileBudget — the optional per-profile budget envelope (spec § 3.1 / § 5.4,
// plan step 2).
//
// Each field is nullable: a null field means "inherit the entry procedure's
// budget header value". The boot resolver (step 3) overrides the header with
// each set field, then clamps to the global ceiling (SC-8 — a profile may only
// *tighten*). This is a pure value type; the clamping and ledger construction
// live in `tom_brain_run` / `tom_brain_procedure`.

/// A per-profile budget override. Any null field inherits the entry
/// procedure's header value (spec § 3.1).
final class ProfileBudget {
  /// Max LLM (chat-completion) calls; null ⇒ inherit the header.
  final int? maxLlmCalls;

  /// Max tool/MCP calls; null ⇒ inherit the header.
  final int? maxToolCalls;

  /// Max model tokens; null ⇒ inherit the header.
  final int? maxTokens;

  /// Wall-clock ceiling for the run; null ⇒ inherit the header.
  final Duration? wallClock;

  const ProfileBudget({
    this.maxLlmCalls,
    this.maxToolCalls,
    this.maxTokens,
    this.wallClock,
  });

  /// Decodes the [toJson] shape. [Duration] is carried as `wallClockMs`
  /// (integer milliseconds) so the round-trip is exact and unit-unambiguous.
  factory ProfileBudget.fromJson(Map<String, Object?> json) => ProfileBudget(
        maxLlmCalls: json['maxLlmCalls'] as int?,
        maxToolCalls: json['maxToolCalls'] as int?,
        maxTokens: json['maxTokens'] as int?,
        wallClock: json['wallClockMs'] == null
            ? null
            : Duration(milliseconds: json['wallClockMs'] as int),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'maxLlmCalls': maxLlmCalls,
        'maxToolCalls': maxToolCalls,
        'maxTokens': maxTokens,
        'wallClockMs': wallClock?.inMilliseconds,
      };

  @override
  bool operator ==(Object other) =>
      other is ProfileBudget &&
      other.maxLlmCalls == maxLlmCalls &&
      other.maxToolCalls == maxToolCalls &&
      other.maxTokens == maxTokens &&
      other.wallClock == wallClock;

  @override
  int get hashCode =>
      Object.hash(maxLlmCalls, maxToolCalls, maxTokens, wallClock);

  @override
  String toString() => 'ProfileBudget(maxLlmCalls: $maxLlmCalls, '
      'maxToolCalls: $maxToolCalls, maxTokens: $maxTokens, '
      'wallClock: $wallClock)';
}
