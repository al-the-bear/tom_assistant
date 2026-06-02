# tom_brain_access_prototype

Prototype **access layer** for Tom Brain — the inbound surface and the
actual running process. It accepts OpenAI-format HTTP/SSE and Telegram
inbound work, produces the `Access` object the dispatcher consumes, runs
`answer_with_memory_v1` through `tom_brain_procedure_prototype`, and
streams the answer back through the originating channel.

> **Status:** E.30 — the per-principal daily LLM-call quota is the third
> `## E.6 — Edge security` check: `DailyQuotaLimiter` owns one calendar-day
> counter per non-secret `principalId` under a single `DailyQuotaPolicy.dailyCap`
> and is called once per inbound request, after the burst throttle (E.29) and
> before an `Access` exists (AC-4); `check` counts one call and returns, or
> throws `DailyQuotaExceeded` (carrying a `retryAfter` until the next day
> boundary) once the cap is reached. A rejected request is not counted; the
> counter resets on the day roll-over read through an injectable clock. A
> failure maps to `quotaHttpStatus` (`429`, the same status the burst throttle
> uses, OpenAI) / `telegramQuotaMessage` (a graceful "daily limit reached",
> Telegram). Counter state is in-process for the prototype.
> E.29 — per-principal token-bucket rate limiting is the second
> `## E.6 — Edge security` check: `RateLimiter` owns one continuous-refill
> `RateLimitPolicy` bucket per non-secret `principalId` and is called once
> per inbound request, after auth (E.28) and before an `Access` exists
> (AC-4); `check` consumes one token and returns, or throws
> `RateLimitExceeded` (carrying a finite `retryAfter`) when the bucket is
> empty. A failure maps to `rateLimitHttpStatus` (`429`, OpenAI) /
> `telegramRateLimitMessage` (a graceful "slow down", Telegram). Bucket state
> is in-process for the prototype; refill is read through an injectable clock.
> E.28 — bearer-token auth opened `## E.6 — Edge security`: the
> OpenAI-channel credential check that runs *before* an `Access` exists
> (AC-4). `BearerTokenAuthenticator` validates a token to a `TomPrincipal`
> (or throws `BearerAuthFailure` with a `missing` / `malformed` / `rejected`
> reason); `StaticBearerTokenAuthenticator` (the prototype default — opaque
> shared secrets) and `JwtBearerTokenAuthenticator` (via
> `TomBearerAuthentication`) ship. `parseBearerHeader` /
> `authenticateBearerHeader` lift the token out of the
> `Authorization: Bearer <token>` header; every failure maps to
> `bearerAuthHttpStatus` (`401`). Telegram auth is the whitelist (E.22); the
> failure→`Response` wire shaping and the boot wiring are E.41+. Mirrors the
> A.76 bearer contract. E.27 — the identity / session / persona resolution
> sweep closes `## E.5`: a cross-resolver test suite locks token / user-id
> resolution, session reuse across calls (same node by key, AC-8), and
> persona defaulting when no model id is named (AC-5), plus the cohesion
> check that the session is keyed by the resolved principal id while persona
> varies per turn. E.26 — `PersonaResolver` completes the three
> `Access`-filling resolvers, mapping a model id (or its absence) to a
> `Persona`.
> The Telegram channel surface is
> conformance-locked (roundtrip + whitelist enforcement + large-answer
> chunking), end-to-end through the in-process `LoopbackChatApi`.
> `TelegramAdapter` is built on `tom_chattools`' `ChatApi` +
> `TelegramChatConfig` and runs **long-polling**: `start()` initialises the
> backend and subscribes to its `onMessage` stream (relayed raw on
> `inboundMessages`); `stop()` cancels and disconnects.
> `TelegramAdapter.fromConfig` builds the real backend, with a builder seam
> for the in-process `LoopbackChatApi` test double (E.5). E.20 added
> `ChatMessage.toInboundRequest()` (`TelegramInboundMapping`): a Telegram
> message → the channel-agnostic `InboundRequest` — `text` from the body,
> `messageId` from the Telegram message id, `conversationId` from the chat id
> (sender-id fallback for a private chat), the sender id on
> `metadata[telegramSenderIdMetadataKey]` for `IdentityResolver`,
> `streaming: false`. A non-text Stage-1 message is rejected
> (`Err(TelegramInboundError)`, ignored + logged). The adapter surfaces the
> mapped, dropped-on-rejection view as `inboundRequests`. E.21 adds the
> outbound mapping: `TelegramOutboundConsolidator` buffers an answer's
> `Stream<OutboundChunk>` and splits it into the **minimum number of
> size-compliant messages** — one consolidated message when it fits
> Telegram's 4096-code-unit limit (`telegramMaxMessageLength`), the fewest
> whole-character messages when it overflows (def § Q13 "no edits" preserved
> — N append-only messages). The adapter surfaces it as `sendAnswer`
> (plain-text sends: no `parseMode`, typing indicator, or inline buttons).
> E.22 adds the edge auth gate: `TelegramWhitelist` is the pure configured
> set of allowed Telegram user ids (`isAllowed`); an empty whitelist allows
> no one (closed default, Q-E.22.1). The adapter surfaces it as
> `authorizedInboundRequests` — `inboundRequests` gated by the whitelist
> *before* a request can become an `Access`. A non-whitelisted sender is
> rejected at the edge: the graceful `telegramNotAuthorisedMessage` is sent
> back and the request dropped, so no `Access` is ever built (proto spec
> § 6.4 / § 8). E.23 adds the Telegram conformance suite: a whitelisted
> message round-trips inbound→authorise→outbound on one running adapter; the
> whitelist is enforced end-to-end; and a large answer driven through
> `sendAnswer` at the real 4096 limit is split into the minimum number of
> size-compliant messages (whole-character, lossless). E.24 adds the first
> of the three `Access`-filling resolvers: `IdentityResolver` maps an OpenAI
> bearer token / a Telegram user id → an internal `tom_core_kernel`
> `TomPrincipal` → a `tom_brain_shared` `ResolvedIdentity` (the minimal
> handle threaded into the memory scope, AC-7). Resolution is a registry
> lookup (`IdentityBinding` per known credential) — a non-secret
> `principalId` chosen at config time, never derived from the bearer token;
> an unbound credential throws `IdentityResolutionException`. E.25 adds the
> second resolver: `SessionManager` resolves an inbound request to a
> sliding-window session keyed by (principal, channel, conversation id) —
> `AccessChannel` (the channel discriminator), `SessionKey` (the
> record-keyed triple), `SessionTurn` / `SessionNode` (the window). Reuse is
> *by key, not by re-creation* (AC-8): a second request on the same key
> returns the same node (same `sessionId`) with the new turn appended and the
> window slid at `maxWindowTurns`; the node projects onto the shared
> `Session` handle. The node store is in-process for the prototype — the
> access layer never depends on `tom_brain_memory`, so the memory-node
> persistence is wired through the dispatcher at E.27 / E.55. E.26 adds the
> third and last resolver: `PersonaResolver` maps a model id (or its
> absence) to the `Persona` the dispatcher hands to substrate — the three
> persona-as-model ids (`tom-assistant`, `:terse`, `:verbose`) round-trip,
> each carrying that id and the single substrate role `assistant_to_user`;
> a `null` or unknown model id falls back to `Persona.assistant()` (AC-5).
> Its default vocabulary is the shared `OpenAiPersonaMapping.knownModels`
> (the single id-list source of truth E.15 established), with an injectable
> seam for the `AccessConfig` persona vocabulary at boot (E.41+). The
> resolution-test sweep (E.27) builds on the three resolvers.
>
> The OpenAI HTTP/SSE adapter (E.11 – E.18) is complete and its
> wire-format conformance is locked. `OpenAiHttpSseAdapter` router scaffold
> (E.11), `chat/completions` request parsing (E.12), the SSE streaming response
> (E.13), the non-streaming JSON response (E.14), the model-id → persona
> mapping (E.15), the `/v1/embeddings` passthrough (E.16), and the
> `/v1/models` listing (E.17). E.18 adds the consolidated
> **wire-format conformance suite** (AC-6):
> `test/adapters/openai_wire_format_conformance_test.dart` drives one
> fully-wired adapter black-box through `handler` and asserts the complete
> OpenAI envelope of every route (`chat.completion` /
> `chat.completion.chunk` / embeddings-list / models-list), that streaming
> chunks arrive in order, that the non-streaming body completes, that
> `data: [DONE]` is the last SSE line, and the cross-route content-type and
> error-envelope invariants. A raw
> `shelf_router.Router` (Q-E.3.2 strategy 2) mounts
> `POST /v1/chat/completions`, `POST /v1/embeddings`, and `GET /v1/models`
> under `/v1/`. The chat route parses its body (`ChatCompletionRequest`:
> `messages` → prompt text, `model` → persona id, `stream` → render flag),
> returning the OpenAI `400 invalid_request_error` envelope on malformed
> input. A well-formed *streaming* request (`stream: true`) renders a
> `text/event-stream` SSE response — `ChatCompletionSseRenderer` maps each
> `OutboundChunk` to a `chat.completion.chunk` `data: {…}\n\n` frame ending
> with `data: [DONE]\n\n`; a *non-streaming* request renders one buffered
> `application/json` `chat.completion` body — `ChatCompletionJsonRenderer`
> concatenates the chunks into `choices[0].message.content` and attaches an
> approximate (char/4) `usage` block. The `model` stamped into the rendered
> body is now the resolved persona's canonical id — `OpenAiPersonaMapping`
> maps `tom-assistant` / `:terse` / `:verbose` to `Persona` objects (all
> `assistant_to_user`), normalising an absent/unknown model to
> `tom-assistant` (AC-5). Both render modes source chunks from the injected
> `ChatAnswerStream` seam (the real source is wired at boot, E.41+); with no
> source wired either mode answers `501`. The `POST /v1/embeddings` route is a
> **passthrough** to substrate's embedding service (proto spec § 5.6,
> Q-E.2.2 — direct-to-substrate by default): `EmbeddingsRequest` parses
> `input` (a string or array of strings) into one-or-more texts, returning the
> OpenAI `400` envelope on a malformed body; the inputs are embedded through
> the injected `EmbeddingSource` seam (which keeps the package free of a
> `tom_brain_substrate` dependency) and `EmbeddingsResponseRenderer` renders
> the OpenAI list body (`data[].embedding`, the substrate model's `model`, a
> char/4 `usage`); with no source wired a well-formed request answers `501`
> (boot E.41+). The `GET /v1/models` route lists the persona vocabulary:
> `ModelsResponseRenderer` renders the OpenAI models-list body
> (`object: "list"`, `data[].id`, `object: "model"`, a fixed `created`
> constant, `owned_by: "tom-brain"`) over exactly
> `OpenAiPersonaMapping.knownModels`. It needs no injected source (the
> vocabulary is a static, adapter-owned list), so it always answers `200`,
> never `501`. An unmatched path/verb returns the OpenAI `404` envelope.
> Locked by `test/adapters/openai_http_sse_adapter_test.dart`,
> `test/adapters/chat_completion_request_test.dart`,
> `test/adapters/chat_completion_sse_test.dart`,
> `test/adapters/chat_completion_json_test.dart`,
> `test/adapters/persona_mapping_test.dart`,
> `test/adapters/embeddings_test.dart`,
> `test/adapters/models_test.dart`, and
> `test/adapters/openai_wire_format_conformance_test.dart`. The `serve` command is
> still a not-yet-wired stub; full boot (substrate, memory isolate, engine,
> dispatcher, adapters wired, `/healthz`) lands at E.41 – E.45.

## Role in the quest

This is the only package in the Tom Brain prototype that ships a running
process (`bin/tom_brain_access_prototype.dart`, lands at E.9). Everything
upstream of it — `tom_brain_memory`, `tom_brain_substrate`,
`tom_brain_procedure_prototype` — is a library that this process composes.

## What lives here (by plan step)

| Concern | Folder (lands at) | Plan steps |
|---|---|---|
| OpenAI HTTP/SSE adapter | `lib/src/adapters/openai_http_sse/` (E.8) | E.11 – E.18 |
| Telegram adapter | `lib/src/adapters/telegram/` (E.8) | E.19 – E.23 |
| Identity / session / persona | `lib/src/identity/` (E.8) | E.24 – E.27 |
| Edge security | `lib/src/edge_security/` (E.8) | E.28 – E.32 |
| Cheap kind-hint classifier | `lib/src/heuristic_classifier/` (E.8) | E.33 – E.35 |
| Outbound delivery | `lib/src/delivery/` (E.8) | E.36 – E.40 |
| Boot + running process | `lib/src/boot/`, `bin/` (E.8 / E.9) | E.41 – E.45 |
| Configuration | `lib/src/config/` (E.8) | E.44, E.47 |
| Public surface | `lib/src/api/` (E.8) | E.51 – E.52 |

## What does NOT live here

- Memory storage / retrieval / cognitive agents — `tom_brain_memory`.
- LLM / embedding / web / MCP-client surfaces — `tom_brain_substrate`.
- The procedure engine + dispatcher — `tom_brain_procedure_prototype`.
- Identifier / vector / budget / result / event / time / version /
  anchor / `Access` primitives — `tom_brain_shared`.

## Driving documents

- `_ai/quests/tom_brain/tom_brain_access_prototype_specification.md` —
  the authoritative contract.
- `_ai/quests/tom_brain/prototype_implementation_plan.md` — Phase E.
- `_ai/quests/tom_brain/prototype_implementation_details.md` —
  append-per-step build log.
- `_ai/quests/tom_brain/prototype_implementation_questions.md` — open
  questions tagged `Q-E.<step>.<n>`.
