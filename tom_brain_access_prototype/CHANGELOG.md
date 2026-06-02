# Changelog

## 0.0.1 — 2026-06-02 (Phase E.17)

OpenAI HTTP/SSE adapter — `GET /v1/models` listing (proto spec § 5.7):

- `lib/src/adapters/openai_http_sse/models_response.dart` —
  `ModelsResponseRenderer`. Pure, network-free renderer of the OpenAI
  models-list body: `object: "list"`, and one `data[]` item per id carrying
  `id`, `object: "model"`, a fixed `created` constant (the personas are
  static, so the response is byte-for-byte reproducible — no wall-clock read),
  and `owned_by: "tom-brain"`. Defaults to listing exactly
  `OpenAiPersonaMapping.knownModels` (E.15), the adapter's persona vocabulary.
- `lib/src/adapters/openai_http_sse/openai_http_sse_adapter.dart` —
  `_handleModels` wired: `GET /v1/models` always renders the `200` models
  list. Unlike the chat / embeddings routes it needs no injected source (the
  vocabulary is static and adapter-owned), so it never answers `501`. File
  header + route-table doc updated E.16 → E.17.
- `lib/src/adapters/openai_http_sse/openai_http_sse.dart` — barrel now also
  exports `models_response.dart`.
- `test/adapters/models_test.dart` — 5 assertions: the renderer (default
  vocabulary in order, per-item OpenAI model shape, deterministic `created`,
  explicit-list passthrough) and the adapter route (a bare adapter answers a
  `200` OpenAI models-list body).
- `test/adapters/openai_http_sse_adapter_test.dart` — the E.11 models stub
  case re-scoped: `GET /v1/models` → `200` (no longer a `501` stub); group
  re-labelled to "chat / embeddings answer 501 until a source is wired".

## 0.0.1 — 2026-06-02 (Phase E.16)

OpenAI HTTP/SSE adapter — `/v1/embeddings` passthrough to substrate's
embedding service (proto spec § 5.6, Q-E.2.2 — direct-to-substrate default):

- `lib/src/adapters/openai_http_sse/embeddings_request.dart` —
  `EmbeddingsRequest` / `EmbeddingsParseError`. Parses the `POST
  /v1/embeddings` JSON body: `input` (a string or an array of strings) →
  one-or-more non-empty texts; `model` (informational) → optional string;
  `encoding_format` must be `float` (base64 rejected). Token-id inputs are a
  reported `400` (the prototype embeds text, not pre-tokenised ids). Pure —
  returns a `Result`, never throws on bad input.
- `lib/src/adapters/openai_http_sse/embeddings_response.dart` —
  `EmbeddingBatch` (the substrate-agnostic seam result: one float vector per
  input + the substrate model id) and `EmbeddingsResponseRenderer` (renders
  the OpenAI list body — `object: "list"`, `data[].embedding`, the substrate
  model's `model`, a char/4-estimated `usage` with `total == prompt` and no
  `completion_tokens`). A vector-count / input-count mismatch is an
  `ArgumentError` (a seam-wiring bug, not a silent truncation).
- `lib/src/adapters/openai_http_sse/openai_http_sse_adapter.dart` —
  the `EmbeddingSource` passthrough seam (`Future<EmbeddingBatch>
  Function(List<String>)`) injected via the new `embeddingSource` constructor
  parameter; `_handleEmbeddings` parses the body (400 on malformed) and
  `_respondToEmbeddings` answers `501` when no source is wired, else embeds
  and renders the list body. Keeping the seam a function (not a
  `tom_brain_substrate` type) preserves the E.7 dependency set.
- `test/adapters/embeddings_test.dart` — 15 assertions: the pure parser
  (string / array inputs, model, encoding_format; invalid_body /
  missing_input / invalid_input / token-id rejection / invalid_model /
  invalid_encoding_format), the pure renderer (list shape, usage, count
  mismatch → ArgumentError), and the adapter black-box (injected source →
  200 list body echoing the substrate model; malformed → 400 with the source
  untouched; no source → 501).
- `test/adapters/openai_http_sse_adapter_test.dart` — the E.11 embeddings
  stub case re-scoped: a well-formed body with no source → 501 (mirroring the
  chat no-source case); the group label narrowed to `(E.17)`.

## 0.0.1 — 2026-06-02 (Phase E.15)

OpenAI HTTP/SSE adapter — model-id → persona mapping:

- `lib/src/adapters/openai_http_sse/persona_mapping.dart` —
  `OpenAiPersonaMapping`, the pure, network-free map from an OpenAI `model`
  string to a `tom_brain_shared` `Persona`. The closed vocabulary is the
  three prototype personas (`tom-assistant`, `tom-assistant:terse`,
  `tom-assistant:verbose`), each carrying that id as its `personaId` and all
  resolving to the substrate role `assistant_to_user`. An absent or unknown
  model resolves to `Persona.assistant()` (AC-5 — not an error). Exposes
  `resolve(...)`, `knownModels`, and `isKnown(...)`.
- `lib/src/adapters/openai_http_sse/openai_http_sse_adapter.dart` —
  `_respondToChatCompletion` now resolves the persona via
  `OpenAiPersonaMapping.resolve(request.model)` and passes the persona's
  canonical `personaId` to both render paths (`_streamingChatResponse` /
  `_jsonChatResponse` gained a `modelId` parameter), replacing E.14's raw
  `request.model` echo. The `_defaultModel` literal placeholder was removed —
  the mapping owns the default now.
- `test/adapters/persona_mapping_test.dart` — 11 assertions: the pure
  mapping (three recognised ids, null / unknown / empty fallback,
  `knownModels`, `isKnown`) and the adapter stamping the resolved persona's
  canonical id into the response body (variant round-trips; unknown / absent
  normalise to `tom-assistant`).

## 0.0.1 — 2026-06-02 (Phase E.14)

OpenAI HTTP/SSE adapter — `chat/completions` non-streaming JSON response:

- `lib/src/adapters/openai_http_sse/chat_completion_json.dart` —
  `ChatCompletionJsonRenderer`, the renderer that **buffers** a
  `Stream<OutboundChunk>` into one OpenAI `chat.completion` JSON body:
  `choices[0].message` (`role: "assistant"`, the concatenated answer text),
  `finish_reason: "stop"`, and a `usage` block. `render(...)` buffers the
  stream then encodes; `bodyMap(...)` / `bodyJson(...)` are the pure body
  builders; `estimateTokens(...)` is the approximate char/4 token estimate
  (Q-E.2.1 — no real effort metrics in the prototype). `forModel(...)` mints
  a `chatcmpl-<ULID>` id via `tom_brain_shared`'s `Ulid` and stamps
  Unix-epoch `created`.
- `lib/src/adapters/openai_http_sse/openai_http_sse_adapter.dart` — the
  `POST /v1/chat/completions` handler now renders a buffered
  `application/json` `chat.completion` body for a well-formed *non-streaming*
  request, sourcing chunks from the same injected `ChatAnswerStream` seam the
  SSE path uses. With no source wired *either* render mode answers `501`
  (boot E.41+). `_respondToChatCompletion` is now async; the no-source check
  moved ahead of the render-mode branch.
- `test/adapters/chat_completion_json_test.dart` — 11 assertions: renderer
  body shape, `usage` char/4 estimates, chunk buffering (in-order
  concatenation, `isFinal` ignored, empty stream), `estimateTokens`,
  `forModel`, and the adapter non-streaming path (200 + `application/json` +
  buffered body + `usage` totals; no-source → 501; model echoed).
- `test/adapters/chat_completion_sse_test.dart` /
  `test/adapters/openai_http_sse_adapter_test.dart` /
  `test/adapters/chat_completion_request_test.dart` — re-scoped: the
  non-streaming-with-source `501` assertion moved to E.14's test (it now
  renders JSON); the no-source `501` cases are re-labelled "boot E.41+".

## 0.0.1 — 2026-06-02 (Phase E.13)

OpenAI HTTP/SSE adapter — `chat/completions` SSE streaming response:

- `lib/src/adapters/openai_http_sse/chat_completion_sse.dart` —
  `ChatCompletionSseRenderer`, the pure wire-format renderer. `render(...)`
  maps a `Stream<OutboundChunk>` onto OpenAI `chat.completion.chunk`
  `data: {…}\n\n` frames (one per chunk, `choices[0].delta.content`,
  `finish_reason: "stop"` on the final chunk) terminated by a single
  `data: [DONE]\n\n` line. `forModel(...)` mints a `chatcmpl-<ULID>` id via
  `tom_brain_shared`'s `Ulid` generator and stamps Unix-epoch `created`.
- `lib/src/adapters/openai_http_sse/openai_http_sse_adapter.dart` — the
  `POST /v1/chat/completions` handler now renders a `text/event-stream`
  response for a well-formed *streaming* request, sourcing chunks from the
  injected `ChatAnswerStream` seam (a new constructor parameter). With no
  source wired it answers `501`; a non-streaming request answers `501`
  (the JSON body is E.14). Adds the `ChatAnswerStream` typedef and the
  `text/event-stream` content type.
- `test/adapters/chat_completion_sse_test.dart` — 9 assertions: renderer
  frame shape (content / final / empty-final / `forModel`), stream
  ordering + `[DONE]` terminator, and the adapter streaming path
  (200 + `text/event-stream` + ordered frames; no-source → 501;
  non-streaming → 501).

## 0.0.1 — 2026-06-02 (Phase E.12)

OpenAI HTTP/SSE adapter — `chat/completions` request parsing:

- `lib/src/adapters/openai_http_sse/chat_completion_request.dart` —
  `ChatCompletionRequest` (the wire DTO: `prompt`, `model`, `stream`) +
  `ChatCompletionParseError` (the typed `400` payload) +
  `ChatCompletionRequest.parse(Object?)`, a pure decode-and-validate of the
  request body. The prompt is the last `user` message's text (string or
  content-part array); `model` is an optional persona id; `stream` defaults
  to `false`. `toInboundRequest()` projects it onto the shared
  `InboundRequest` (`prompt` → `text`, `stream` → `streaming`).
- `lib/src/adapters/openai_http_sse/openai_http_sse_adapter.dart` — the
  `POST /v1/chat/completions` handler now reads the body, parses it, returns
  the OpenAI `400 invalid_request_error` envelope (with `param`) on a
  malformed body, and a `501` (now naming E.13 – E.15) for a well-formed
  request whose response path is not yet wired. `_errorResponse` gained the
  OpenAI `param` field.
- `lib/src/adapters/openai_http_sse/openai_http_sse.dart` — module barrel
  now also exports the parser.
- `test/adapters/chat_completion_request_test.dart` — unit + black-box
  contract test (field extraction, every parse-failure branch,
  `toInboundRequest`, adapter 400/501 envelopes).
- `test/adapters/openai_http_sse_adapter_test.dart` — the E.11 chat-route
  assertion updated: a malformed body is now a 400 (E.12), so the 501 case
  now sends a well-formed body.

## 0.0.1 — 2026-06-02 (Phase E.11)

OpenAI HTTP/SSE adapter — router scaffold:

- `lib/src/adapters/openai_http_sse/openai_http_sse_adapter.dart` —
  `OpenAiHttpSseAdapter`, a raw `shelf_router.Router` (Q-E.3.2 strategy 2)
  exposing `handler` (a `shelf.Handler`) with `POST /v1/chat/completions`,
  `POST /v1/embeddings`, and `GET /v1/models` mounted under `/v1/`. Routes
  are inert `501` stubs in the OpenAI error envelope until E.12 – E.18;
  unmatched path/verb returns the OpenAI `404` envelope.
- `lib/src/adapters/openai_http_sse/openai_http_sse.dart` — module barrel
  now exports the adapter.
- `pubspec.yaml` — `shelf: ^1.4.2` + `shelf_router: ^1.1.2` added as direct
  deps (Q-E.3.1 / Q-E.7.1; held out at E.7, decided here).
- `test/adapters/openai_http_sse_adapter_test.dart` — router-scaffold
  contract test (route paths, 501 stubs, 404 envelope, verb mismatch).
- `test/dependency_surface_test.dart` — locks the new `shelf` /
  `shelf_router` direct deps.

## 0.0.1 — 2026-06-02 (Phase E.9)

Executable entry point — the running process:

- `bin/tom_brain_access_prototype.dart` — a three-line shim over a
  `ToolRunner` wired to `accessPrototypeTool` + the serve executor.
  Non-zero exit on failure.
- `lib/src/api/access_prototype_tool.dart` — the `tom_build_base`
  `ToolDefinition` (`multiCommand` mode, default non-traversal `serve`
  command, framework-reserved `--config` / `-c` global option,
  version constants, running-process help footer).
- `lib/src/api/access_serve_executor.dart` — `AccessServeExecutor`
  (`executeWithoutTraversal` → status banner + `ToolResult.success`);
  reads `--config` from `CliArgs.configPath` (the framework's reserved
  field); `createAccessPrototypeExecutors()` factory.
- `lib/src/api/api.dart` — now exports the first concrete symbols.
- `pubspec.yaml` — `tom_build_base: ^2.6.21` added (workspace rule: every
  CLI tool is built on `tom_build_base`).
- `.gitignore` — `pubspec.lock` no longer ignored (Q-E.6.2: an
  application package that ships an executable commits its lock).
- `test/executable_test.dart` — black-box contract test for the tool
  shape, the executor map, and end-to-end `--version` / `--help` / bare
  `serve` / `--config` dispatch.
- `test/package_loads_test.dart` / `test/dependency_surface_test.dart` —
  updated to reference the first concrete exported symbols and lock the
  `tom_build_base` v2 framework surface.
- The `serve` command is a not-yet-wired stub; full boot lands at
  E.41 – E.45.

## 0.0.1 — 2026-06-02 (Phase E.8)

`lib/src/` module layout established:

- Nine leaf-module subfolders created under `lib/src/`, two of them
  nested under a shared `adapters/` grouping directory:
  `adapters/openai_http_sse/`, `adapters/telegram/`, `identity/`,
  `edge_security/`, `heuristic_classifier/`, `delivery/`, `boot/`,
  `config/`, `api/`. Each carries an intentionally-empty per-folder
  barrel (`//` comment header naming its ownership and the E-steps that
  populate it — no symbols yet).
- Top-level barrel `lib/tom_brain_access_prototype.dart` now re-exports
  all nine module barrels in request-flow order, so the package surface
  mirrors the internal layout from day one.
- Stale E.6 placeholder `lib/src/.gitkeep` removed.
- `test/folder_layout_test.dart` — locks the leaf-module inventory, the
  per-folder barrel convention, the top-level re-export, the placeholder
  removal, and the absence of stray directories (incl. under
  `adapters/`).

## 0.0.1 — 2026-06-02 (Phase E.7)

Runtime dependencies wired:

- `pubspec.yaml` — the six plan-named runtime dependencies added:
  `tom_brain_shared`, `tom_brain_procedure_prototype` (interface boundary
  — dispatcher only), `tom_basics`, `tom_core_kernel`, `tom_core_server`
  (path deps), and `tom_chattools: ^1.0.2` (the E.4 pin). `mocktail`
  reserved under `dev_dependencies`.
- `test/dependency_surface_test.dart` — locks the dependency surface and
  the specific identifiers the access layer leans on from each library
  (incl. `Access` / `Dispatcher` / `ChatApi` / `TomBearerAuthentication`).
- `shelf` / `shelf_router` deliberately NOT direct deps — the E.11
  mounting strategy (Q-E.3.2) decides whether they are added later.

## 0.0.1 — 2026-06-02 (Phase E.6)

Initial project scaffold:

- `pubspec.yaml` — minimal skeleton, no runtime dependencies yet
  (deferred to E.7 per the plan).
- Empty barrel `lib/tom_brain_access_prototype.dart`.
- `lib/src/` placeholder for the module layout that lands in E.8.
- Smoke test verifying the package loads (`test/package_loads_test.dart`).
- Local copilot guidelines at `_copilot_guidelines/index.md`.
- `analysis_options.yaml` with `package:lints/recommended.yaml`.
