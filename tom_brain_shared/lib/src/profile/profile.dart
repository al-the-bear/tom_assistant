// Barrel for the `profile/` module — the Profile selection axis' shared value
// types (session_configuration_plan.md step 2).
//
// Module surface:
//
//   * `ProfileMode`        — the cognitive/answer/passthrough alphabet + its
//                            mode→entry-procedure mapping (`profile_mode.dart`).
//   * `ProfileBudget`      — the optional per-profile budget envelope
//                            (`profile_budget.dart`).
//   * `ProfileRateLimits`  — the optional per-profile rate-limits
//                            (`profile_rate_limits.dart`).
//   * `ResolvedProfile`    — the boot-resolved bundle stamped on `Access`
//                            (`resolved_profile.dart`).
//
// The raw config-side `Profile` aggregate is NOT here — it references
// `McpServerConfig` (owned by `tom_brain_procedure`) and therefore lives in
// `tom_brain_run` alongside its parser (SCP-6).

export 'profile_budget.dart' show ProfileBudget;
export 'profile_mode.dart' show ProfileMode;
export 'profile_rate_limits.dart' show ProfileRateLimits;
export 'resolved_profile.dart' show ResolvedProfile;
