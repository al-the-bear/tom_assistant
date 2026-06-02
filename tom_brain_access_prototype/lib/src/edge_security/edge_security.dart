// Edge security — the gate every inbound request crosses before the
// dispatcher ever sees it.
//
// Owns bearer-token auth (via `tom_core_kernel`'s
// `TomBearerAuthentication`), per-principal token-bucket rate limiting,
// the per-principal daily LLM-call quota (surfaces as `429` on OpenAI /
// a graceful Telegram message), and the **anchor pre-check** — a
// structural disallowed-fragment screen applied before the prompt
// reaches the dispatcher, with no bypass path. See
// `tom_brain_access_prototype_specification.md` § Edge security and Plan
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
// E.30 ⏳ — per-principal daily LLM-call quota.
// E.31 ⏳ — the anchor pre-check.

export 'bearer_auth.dart';
export 'rate_limiter.dart';
