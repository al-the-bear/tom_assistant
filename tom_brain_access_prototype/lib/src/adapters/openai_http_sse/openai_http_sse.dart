// OpenAI-format HTTP/SSE inbound adapter.
//
// Owns the `OpenAiHttpSseAdapter` shelf router mounted under `/v1/`:
// `POST /v1/chat/completions` (streaming + non-streaming), `POST
// /v1/embeddings`, `GET /v1/models`, request parsing, SSE response
// framing (`data: …\n\n` lines + `[DONE]` terminator), and the
// model-id → persona mapping. See
// `tom_brain_access_prototype_specification.md` § OpenAI adapter and
// Plan steps E.11 – E.18.
//
// At E.8 this folder is intentionally empty. No exports yet.
