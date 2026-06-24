// Edge security — the gate every inbound request crosses before the
// dispatcher ever sees it.
//
// Owns bearer-token auth (via `tom_core_kernel`'s
// `TomBearerAuthentication`), per-principal token-bucket rate limiting,
// the per-principal daily LLM-call quota (surfaces as `429` on OpenAI /
// a graceful Telegram message), and the **anchor pre-check** — a
// structural disallowed-fragment screen applied before the prompt
// reaches the dispatcher, with no bypass path. See
// `tom_brain_access_specification.md` § Edge security and Plan
// steps E.28 – E.32 (anchor-at-the-edge proof: E.56).
//
// E.28 ✅ — bearer-token auth (`BearerTokenAuthenticator` +
// `JwtBearerTokenAuthenticator` / `StaticBearerTokenAuthenticator`,
// `BearerAuthFailure` / `BearerAuthFailureReason`, `parseBearerHeader` /
// `authenticateBearerHeader`): the OpenAI-channel credential check, run
// before an `Access` exists; a failure maps to `401` (AC-4). Telegram auth
// is the whitelist (E.22, in the Telegram adapter).
// E.29 ✅ — per-principal token-bucket rate limiting (`RateLimiter` +
// `RateLimitPolicy`, `RateLimitExceeded`, `rateLimitHttpStatus` /
// `telegramRateLimitMessage`): the short-horizon burst throttle, keyed on
// the non-secret `principalId`, run after auth and before an `Access`
// exists; a failure maps to `429` (OpenAI) / a graceful "slow down" message
// (Telegram). In-process bucket state for the prototype (Q-E.2.5).
// E.30 ✅ — per-principal daily LLM-call quota (`DailyQuotaLimiter` +
// `DailyQuotaPolicy`, `DailyQuotaExceeded`, `quotaHttpStatus` /
// `telegramQuotaMessage`): the long-horizon cap — at most `dailyCap` admitted
// calls per calendar day — keyed on the non-secret `principalId`, run after
// the burst throttle (E.29) and before an `Access` exists; a failure maps to
// `429` (OpenAI) / a graceful "daily limit reached" message (Telegram).
// In-process counter state for the prototype (Q-E.2.5 / Q-E.30.1).
// E.31 ✅ — the anchor pre-check (`AnchorPreCheck` + `AnchorPolicy`,
// `AnchorPreCheckRejected`, `anchorPreCheckHttpStatus` /
// `telegramAnchorMessage`): the stateless content screen — a configurable
// list of disallowed prompt-fragment signatures (obvious prompt-injection
// patterns), matched case-insensitively — run last in the edge chain (after
// auth / rate-limit / quota) and before an `Access` exists. A rejected prompt
// maps to `400` (OpenAI, a structurally bad request, never `429`) / a graceful
// "cannot process" message (Telegram). The access-side half of the
// assistant-dedication safety lever (def § 14.5; the substrate-side injection
// half is B.46; anchor-at-edge proof is E.56).
// E.32 ✅ — the edge-security test sweep (test/edge_security/
// edge_security_sweep_test.dart): a test-only composition of all four checks in
// the documented chain order, locking that the four behave as one gate (AC-4) —
// auth failures surface per channel, the rate-limit / quota `429` and anchor
// `400` are distinct, and the first failing check short-circuits the rest. No
// production change here — E.32 is purely tests; boot wiring is E.41+.

export 'api_key_markers.dart';
export 'bearer_auth.dart';
export 'edge_state_store.dart';
export 'profile_rate_limiter.dart';
export 'profile_resolution.dart';
export 'rate_limiter.dart';
export 'quota.dart';
export 'anchor_precheck.dart';
