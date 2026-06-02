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
// E.11 lands the router scaffold (`OpenAiHttpSseAdapter`); the per-route
// behaviour follows in E.12 – E.18. E.12 adds `ChatCompletionRequest` /
// `ChatCompletionParseError` — the `chat/completions` request parser. E.13
// adds `ChatCompletionSseRenderer` — the SSE streaming-response renderer —
// and the `ChatAnswerStream` seam on the adapter. E.14 adds
// `ChatCompletionJsonRenderer` — the non-streaming `chat.completion` JSON
// body renderer. E.15 adds `OpenAiPersonaMapping` — the model-id → `Persona`
// map whose canonical persona id is stamped into the rendered body.

export 'chat_completion_json.dart';
export 'chat_completion_request.dart';
export 'chat_completion_sse.dart';
export 'openai_http_sse_adapter.dart';
export 'persona_mapping.dart';
