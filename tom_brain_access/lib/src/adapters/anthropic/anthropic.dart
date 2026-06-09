// Anthropic-format HTTP inbound adapter (plan item #28).
//
// Owns the `AnthropicHttpAdapter` shelf router mounting the single Anthropic
// Messages endpoint, `POST /v1/messages`: request parsing
// (`AnthropicRequest`), the SSE streaming response (`AnthropicSseRenderer` —
// the canonical `message_start` / `content_block_start` /
// `content_block_delta` / `content_block_stop` / `message_delta` /
// `message_stop` event sequence an Anthropic SDK consumes, no `[DONE]`
// sentinel), the non-streaming single Message-object JSON response
// (`AnthropicJsonRenderer`), and the `model` → persona mapping (reusing the
// shared `OpenAiPersonaMapping` vocabulary). The channel is wired through the
// shared admission pipeline at plan item #29.
//
// Unlike the OpenAI adapter, Anthropic frames its stream as named SSE events
// (`event: <name>\ndata: <json>\n\n`), opens with a `message_start` envelope
// and closes with `message_stop` (no terminal sentinel line), carries
// `msg_<id>` message ids, and renders errors as
// `{"type":"error","error":{"type":…,"message":…}}`. Like OpenAI (and unlike
// Ollama) it defaults to non-streaming.

export 'anthropic_adapter.dart';
export 'anthropic_json.dart';
export 'anthropic_requests.dart';
export 'anthropic_sse.dart';
