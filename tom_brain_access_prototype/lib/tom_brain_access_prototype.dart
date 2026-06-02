/// Prototype access layer for Tom Brain — the inbound surface and the
/// actual running process.
///
/// This package owns the channels that carry real user work into the
/// brain and stream answers back out: an OpenAI-format HTTP/SSE adapter
/// and a Telegram adapter. It produces the `Access` object the dispatcher
/// (`tom_brain_procedure_prototype`) consumes, resolves identity /
/// session / persona, enforces edge security (bearer auth, rate limits,
/// quota, anchor pre-check), runs the cheap kind-hint classifier, and
/// delivers outbound chunks back to the originating channel. See
/// `tom_brain_access_prototype_specification.md` and Phase E of
/// `prototype_implementation_plan.md`.
///
/// At E.8 the `lib/src/` module layout is in place: each subfolder below
/// carries an intentionally-empty per-folder barrel, re-exported here so
/// the package surface mirrors the internal layout from day one. Symbols
/// land in those barrels as the later steps populate each module; no
/// further edit to this top-level barrel is needed for them to surface.
///
/// - E.6  ✅ — Project skeleton (`lib/`, `test/`, `pubspec.yaml`,
///   `analysis_options.yaml`, `_copilot_guidelines/`, README, CHANGELOG).
/// - E.7  ✅ — Runtime dependencies (`tom_brain_shared`,
///   `tom_brain_procedure_prototype`, `tom_basics`, `tom_core_kernel`,
///   `tom_core_server`, `tom_chattools`), locked by
///   `test/dependency_surface_test.dart`.
/// - E.8  ✅ — `lib/src/` folder layout (`adapters/openai_http_sse/`,
///   `adapters/telegram/`, `identity/`, `edge_security/`,
///   `heuristic_classifier/`, `delivery/`, `boot/`, `config/`, `api/`),
///   locked by `test/folder_layout_test.dart`.
/// - E.9  ✅ — `bin/tom_brain_access_prototype.dart` executable
///   (the running process; built via `tom_build_base`'s `ToolDefinition`).
///   The `api/` barrel now exports the first concrete symbols
///   (`accessPrototypeTool`, `AccessServeExecutor`,
///   `createAccessPrototypeExecutors`, version constants). The `serve`
///   command is a not-yet-wired stub; full boot lands at E.41–E.45.
/// - E.10 ✅ — `.tom_metadata/tom_master.yaml` wiring (documented no-op
///   per policy override 5).
/// - E.11 ✅ — `OpenAiHttpSseAdapter` router scaffold: a raw
///   `shelf_router.Router` mounting `POST /v1/chat/completions`,
///   `POST /v1/embeddings`, `GET /v1/models` (Q-E.3.2 strategy 2). The
///   routes are inert `501` stubs at E.11; behaviour lands at E.12–E.18.
/// - E.12 ✅ — `chat/completions` request parsing: `ChatCompletionRequest` /
///   `ChatCompletionParseError` decode the JSON body (`messages` → prompt
///   text, `model` → persona id, `stream` → render flag); a malformed body
///   returns the OpenAI `400 invalid_request_error` envelope.
/// - E.13 ✅ — `chat/completions` SSE streaming response:
///   `ChatCompletionSseRenderer` maps a `Stream<OutboundChunk>` onto OpenAI
///   `chat.completion.chunk` `data: {…}\n\n` frames terminated by
///   `data: [DONE]\n\n`. A well-formed *streaming* request renders a
///   `text/event-stream` response from the injected `ChatAnswerStream`
///   seam (boot wires the real source, E.41+).
/// - E.14 ✅ — `chat/completions` non-streaming JSON response:
///   `ChatCompletionJsonRenderer` buffers the same `Stream<OutboundChunk>`
///   into one OpenAI `chat.completion` body (`choices[0].message.content`
///   + a char/4-estimated `usage` block). A well-formed *non-streaming*
///   request renders that body from the injected source; with no source
///   wired *either* render mode answers `501` (boot E.41+).
/// - E.15 ✅ — model-id → persona mapping: `OpenAiPersonaMapping` resolves
///   the request's `model` string to a `Persona` (`tom-assistant`,
///   `tom-assistant:terse`, `tom-assistant:verbose` round-trip; an
///   absent/unknown model normalises to `tom-assistant`, AC-5). The
///   resolved persona's canonical id is the `model` stamped into both
///   render paths, replacing E.14's raw request echo.
/// - E.16 ✅ — `/v1/embeddings` passthrough to substrate's embedding service
///   (proto spec § 5.6, Q-E.2.2 — direct-to-substrate default).
///   `EmbeddingsRequest` / `EmbeddingsParseError` parse the JSON body
///   (`input` → one-or-more text strings, `model` informational); a malformed
///   body returns the OpenAI `400 invalid_request_error` envelope. The inputs
///   are embedded through the injected `EmbeddingSource` seam (which keeps the
///   package free of a `tom_brain_substrate` dependency) and rendered by
///   `EmbeddingsResponseRenderer` into the OpenAI `embeddings` list body
///   (`data[].embedding`, the substrate model's `model`, a char/4-estimated
///   `usage`). With no source wired a well-formed request answers `501`
///   (boot E.41+).
/// - E.17 ✅ — `GET /v1/models` listing (proto spec § 5.7).
///   `ModelsResponseRenderer` renders the OpenAI models-list body
///   (`object: "list"`, `data[].id`, `object: "model"`, a fixed `created`
///   constant, `owned_by: "tom-brain"`) listing exactly
///   `OpenAiPersonaMapping.knownModels`. Unlike the chat / embeddings routes
///   the models route needs no injected source — the persona vocabulary is a
///   static, adapter-owned list — so it always answers `200`, never `501`.
/// - E.18 ✅ — OpenAI wire-format conformance suite (AC-6).
///   `test/adapters/openai_wire_format_conformance_test.dart` drives one
///   fully-wired adapter (both the `ChatAnswerStream` and the
///   `EmbeddingSource` seams injected) black-box through `handler` and proves
///   the complete OpenAI envelope of every route: the `chat.completion` /
///   `chat.completion.chunk` / embeddings-list / models-list shapes, that
///   streaming chunks arrive in order, that the non-streaming body completes
///   (full buffered text), and that `data: [DONE]` is the last SSE line —
///   plus the cross-route content-type and error-envelope invariants. This is
///   the in-process contract layer; E.53 guards the same invariant over a real
///   socket against captured OpenAI fixtures.
/// - E.19 ✅ — Telegram adapter scaffold: `TelegramAdapter` built on
///   `tom_chattools`' `ChatApi` + `TelegramChatConfig`, running long-polling
///   (`start` initialises the backend and subscribes to `onMessage`; `stop`
///   cancels + disconnects). It exposes the raw inbound relay
///   (`inboundMessages`) the E.20 mapper consumes, and the
///   `TelegramAdapter.fromConfig` factory (with a builder seam for tests).
///   The `ChatMessage` → `InboundRequest` mapping (E.20), outbound
///   consolidation (E.21), and the user-id whitelist (E.22) build on it.
/// - E.20 ✅ — Telegram inbound mapping: `ChatMessage.toInboundRequest()`
///   (`TelegramInboundMapping`) projects a Telegram message onto the
///   channel-agnostic `InboundRequest` — `text` from the body, `messageId`
///   from the Telegram message id, `conversationId` from the chat id, the
///   sender id on `metadata[telegramSenderIdMetadataKey]` (for
///   `IdentityResolver`, E.24), `streaming: false` (Telegram is
///   single-message, def § Q13). A non-text Stage-1 message returns
///   `Err(TelegramInboundError)` (ignored + logged, proto spec § 12). The
///   adapter surfaces the mapped, dropped-on-rejection view as
///   `TelegramAdapter.inboundRequests`.
/// - E.21 ✅ — Telegram outbound mapping: `TelegramOutboundConsolidator`
///   buffers an answer's `Stream<OutboundChunk>` into the full text and
///   splits it into the **minimum number of size-compliant Telegram
///   messages** — one consolidated message when it fits Telegram's
///   per-message limit (`telegramMaxMessageLength`, 4096 UTF-16 code units),
///   the fewest whole-character messages when it overflows (Q-E.2.6;
///   def § Q13 "no edits" preserved — N append-only messages, never an
///   edit). The adapter surfaces it as `TelegramAdapter.sendAnswer`
///   (plain-text sends: no `parseMode`, typing indicator, or inline
///   buttons — Stage-1, def § Q13).
/// - E.22 ✅ — Telegram edge auth gate: `TelegramWhitelist` is the pure
///   configured set of allowed Telegram user ids (`isAllowed`); an empty
///   whitelist allows no one (closed default, Q-E.22.1). The adapter surfaces
///   it as `TelegramAdapter.authorizedInboundRequests` — `inboundRequests`
///   gated by the whitelist *before* a request can become an `Access`. A
///   non-whitelisted sender is rejected at the edge: the graceful
///   `telegramNotAuthorisedMessage` is sent back and the request dropped, so
///   no `Access` is ever built (AC-3, AC-4; proto spec § 6.4 / § 8).
/// - E.23 ✅ — Telegram conformance suite (tests-only): a whitelisted message
///   round-trips inbound→authorise→outbound on one running adapter; whitelist
///   enforcement holds end-to-end; a large answer driven through `sendAnswer`
///   at the real 4096 limit splits into the minimum number of size-compliant
///   messages (whole-character, lossless). All through `LoopbackChatApi`.
/// - E.24 ✅ — `IdentityResolver` (identity/): maps an OpenAI bearer token /
///   a Telegram user id → an internal `tom_core_kernel` `TomPrincipal` → a
///   `tom_brain_shared` `ResolvedIdentity`, the minimal handle the dispatcher
///   threads into the memory scope (AC-7). Resolution is a registry lookup
///   (`IdentityBinding` per known credential) — a non-secret `principalId`
///   chosen at config time, never derived from the bearer token. An unbound
///   credential throws `IdentityResolutionException` (the auth step E.22/E.28
///   validates the credential first; an unbound one here is a config drift,
///   surfaced loudly, not a fabricated identity).
/// - E.25 ✅ — `SessionManager` (identity/): resolves an inbound request to
///   a sliding-window session keyed by (principal, channel, conversation id)
///   — `AccessChannel` (the channel discriminator), `SessionKey` (the
///   record-keyed triple), `SessionTurn` / `SessionNode` (the window). Reuse
///   is *by key, not by re-creation* (AC-8): the second request on the same
///   key returns the same node (same `sessionId`) with the new turn appended
///   and the window slid at `maxWindowTurns`. The node projects onto the
///   shared `Session` handle (§ 4.4); the node store is in-process for the
///   prototype (memory-node persistence is wired through the dispatcher at
///   E.27 / E.55 — the access layer never depends on `tom_brain_memory`).
/// - E.26 ✅ — `PersonaResolver` (identity/): resolves a model id (or its
///   absence) to the `Persona` the dispatcher hands to substrate. The three
///   persona-as-model ids (`tom-assistant`, `tom-assistant:terse`,
///   `tom-assistant:verbose`) round-trip — each carrying that id and the
///   single prototype substrate role `assistant_to_user`; a `null` or
///   unknown model id falls back to `Persona.assistant()` (AC-5: an unknown
///   model is not an error, it defaults). The resolver's default vocabulary
///   is the shared `OpenAiPersonaMapping.knownModels` (the single id-list
///   source of truth E.15 established), with an injectable seam for the
///   `AccessConfig` persona vocabulary at boot (E.41+). It is the third and
///   last of the three `Access`-filling resolvers (identity E.24, session
///   E.25, persona E.26).
/// - E.27 ✅ — resolution-test sweep (tests-only): the cross-resolver suite
///   exercising identity (E.24), session (E.25) and persona (E.26) the way
///   the edge composes them — token / user-id resolution, session reuse
///   across calls (same node by key, AC-8), and persona defaulting when no
///   model id is named (AC-5) — plus the cohesion check that the session is
///   keyed by the resolved principal id while persona varies per turn. No new
///   source; closes `## E.5 — Identity, session, persona`.
/// - E.28 ✅ — bearer-token auth (edge_security/): the OpenAI-channel
///   credential check that runs *before* an `Access` exists (AC-4).
///   `BearerTokenAuthenticator` validates a token to a `TomPrincipal` (or
///   throws `BearerAuthFailure` with a `missing` / `malformed` / `rejected`
///   reason); `StaticBearerTokenAuthenticator` (the prototype default,
///   opaque shared secrets) and `JwtBearerTokenAuthenticator` (via
///   `TomBearerAuthentication.convertTokenPayloadToPrincipal`) ship.
///   `parseBearerHeader` / `authenticateBearerHeader` lift the token out of
///   the `Authorization: Bearer <token>` header; every failure maps to
///   `bearerAuthHttpStatus` (`401`). Telegram auth is the whitelist (E.22);
///   the failure→`Response` wire shaping and the boot wiring of the
///   authenticator are E.41+ composition. Mirrors the A.76 bearer contract.
/// - E.29 ✅ — per-principal token-bucket rate limiting (edge_security/):
///   the short-horizon burst throttle, the second edge-security check, run
///   after auth (E.28) and before an `Access` exists (AC-4). `RateLimiter`
///   owns one continuous-refill `RateLimitPolicy` bucket per `principalId`
///   (the non-secret stable id — never the bearer token); `check` consumes
///   one token and returns, or throws `RateLimitExceeded` (carrying a finite
///   `retryAfter`) when the bucket is empty. Every failure maps to
///   `rateLimitHttpStatus` (`429`, OpenAI) / `telegramRateLimitMessage` (a
///   graceful "slow down", Telegram). Bucket state is in-process for the
///   prototype (Q-E.2.5); refill is read through an injectable clock. The
///   failure→wire shaping and the boot wiring of the limiter are E.41+.
/// - E.30 – E.50 ⏳ — quota, the anchor pre-check, the kind-hint classifier,
///   delivery, boot, and the end-to-end smoke.
library;

// Module barrels, in request-flow order: inbound adapters → identity →
// edge security → kind-hint classifier → delivery → boot → config → api.
// Every barrel is doc-comment-only at E.8 (no symbols yet); a
// comment-only Dart library is a valid re-export target.
export 'src/adapters/openai_http_sse/openai_http_sse.dart';
export 'src/adapters/telegram/telegram.dart';
export 'src/identity/identity.dart';
export 'src/edge_security/edge_security.dart';
export 'src/heuristic_classifier/heuristic_classifier.dart';
export 'src/delivery/delivery.dart';
export 'src/boot/boot.dart';
export 'src/config/config.dart';
export 'src/api/api.dart';
