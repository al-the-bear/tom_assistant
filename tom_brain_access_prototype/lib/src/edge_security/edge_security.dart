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
// At E.8 this folder is intentionally empty. No exports yet.
