// Ollama-format HTTP inbound adapter (plan item #27).
//
// Owns the `OllamaHttpAdapter` shelf router mounting the two Ollama
// endpoints, `POST /api/chat` and `POST /api/generate`: request parsing
// (`OllamaRequest` over `OllamaApiShape`), the NDJSON streaming response
// (`OllamaNdjsonRenderer` — one JSON object per `\n`-terminated line, a
// terminal `done: true` line, no `[DONE]`), the non-streaming single-object
// JSON response (`OllamaJsonRenderer`), and the `model` → persona mapping
// (reusing the shared `OpenAiPersonaMapping` vocabulary). The two channels
// are wired through the shared admission pipeline at plan item #29.
//
// Unlike the OpenAI adapter, Ollama streams by default (`stream` absent ⇒
// true), frames its stream as `application/x-ndjson`, terminates with a
// `done: true` object rather than a sentinel line, carries no `id`, and
// renders errors as a bare `{"error": <message>}` object.

export 'ollama_adapter.dart';
export 'ollama_json.dart';
export 'ollama_ndjson.dart';
export 'ollama_requests.dart';
