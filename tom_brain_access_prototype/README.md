# tom_brain_access_prototype

Prototype **access layer** for Tom Brain — the inbound surface and the
actual running process. It accepts OpenAI-format HTTP/SSE and Telegram
inbound work, produces the `Access` object the dispatcher consumes, runs
`answer_with_memory_v1` through `tom_brain_procedure_prototype`, and
streams the answer back through the originating channel.

> **Status:** E.40 — **delivery test sweep**, the final step of
> `## E.8 — Outbound delivery`. `test/delivery/delivery_sweep_test.dart` is an
> integration-level sweep over both delivery paths wired the way boot wires them
> — through the `DeliveryRegistry`, over the *runtime* sinks
> (`StreamControllerSseSink` / `ChatApiTelegramSink`), not the in-memory fakes
> the per-step E.37 / E.38 / E.39 suites use. It locks the three things the plan
> names (proto spec § 10.1; AC-2): **(1)** each path delivers correctly — a full
> multi-chunk SSE answer arrives on the decoded UTF-8 wire in order,
> `[DONE]`-terminated, with a correlated `AccessDelivered`, and a buffered,
> overflowing Telegram answer arrives as ordered plain-text messages through the
> real `ChatApi` sink; **(2)** the backpressure signal surfaces — the SSE path
> raises a terminal `DeliveryStalled` through the backpressure stream, the
> Telegram path a transient one through `delivered`; **(3)** a disconnected SSE
> does not leak the run — cancelling the runtime sink's body subscription (a real
> client disconnect) sets `isDisconnected`, fires `onClientDisconnect`, and makes
> the next chunk stall terminally instead of rendering into the dead wire, after
> which the run is terminated (a later chunk throws). `## E.8 — Outbound
> delivery` is complete; **E.41 (boot)** is next.
>
> E.39 — **delivery backpressure**: the two delivery paths now
> surface a `DeliveryStalled` through the `DeliverCallback`'s backpressure
> `Stream<OutboundChunk>` when the channel cannot accept further chunks (proto
> spec § 10.1; AC-2). The signal types — `BackpressureSignal` (sealed,
> `implements Exception`), `DeliveryStalled` (channel wire name, `StallReason`,
> `isTerminal`, optional `retryAfter`), `StallReason`, and the
> `Backpressure.clear` / `Backpressure.stalled(...)` stream builders — live in
> `tom_brain_shared`, because the paths produce them and the engine reacts. The
> **SSE** path is per-chunk: while connected it returns `Backpressure.clear`;
> once the sink reports `isDisconnected` (the runtime `StreamControllerSseSink`
> sets it on a mid-stream subscription cancel, not on a normal close) it
> terminates the binding and returns a *terminal* `DeliveryStalled`
> (`clientDisconnected`) instead of rendering into the dead wire — so the engine
> cancels the run and nothing leaks. The **Telegram** path is buffered and
> cannot stall mid-stream, so its per-chunk stream is always clear; a backend
> rate limit is a *transient* `DeliveryStalled` (`rateLimited`, with
> `retryAfter`) surfaced at flush through the binding's `delivered` future. The
> engine's *reaction* to the signal (yield / cancel) is a later step.
>
> E.38 — the **Telegram delivery path** fills the second of the two
> `ChannelDelivery` slots `## E.8` opened. `TelegramChannelDelivery` is the path
> the `DeliveryRegistry` (E.36) dispatches `AccessChannel.telegram` to. Unlike
> the SSE path (which streams each chunk to the wire as it arrives), Telegram is
> **buffered**: the per-`Access` `DeliverCallback` accumulates every
> `OutboundChunk`'s text and, on the final chunk (`isFinal`), consolidates the
> buffered answer (via the E.21 `TelegramOutboundConsolidator`) into the minimum
> number of size-compliant messages and sends them in order — one consolidated
> message, or N append-only overflow parts, never an edit (def § Q13 / Q-E.2.6);
> an empty answer sends nothing (Q-E.21.1). Its `TelegramDeliveryBinding`
> carries the wire (`TelegramSink`) and exposes a `delivered` future that
> completes once the buffered answer has been fully sent (the synchronous
> callback cannot return it; the registry's `AccessDelivered` fires earlier, on
> the final chunk — Q-E.38.1). `ChatApiTelegramSink` is the runtime sink — each
> part sent through a `tom_chattools` `ChatApi.sendMessage` as plain text (boot
> wires it, E.41+). A rate-limit stall surfaces as a transient `DeliveryStalled`
> through `delivered` (E.39, above).
>
> E.37 — the **SSE delivery path** (OpenAI) fills the first of the
> two `ChannelDelivery` slots `## E.8` opened. `SseChannelDelivery` is the path
> the `DeliveryRegistry` (E.36) dispatches `AccessChannel.openai` to; per
> inbound streaming request its `SseDeliveryBinding` carries the wire
> (`SseSink`) and the E.13 `ChatCompletionSseRenderer` (bound per-`Access`, so
> its `id` / `created` repeat across every chunk as the OpenAI shape requires;
> its `model` is the resolved persona-as-model id, E.15). `bindDeliver` mints
> the per-`Access` `DeliverCallback`: each `OutboundChunk` becomes one
> `chat.completion.chunk` `data: …\n\n` frame written to the sink; the final
> chunk additionally writes the terminal `data: [DONE]\n\n` line and closes the
> wire, so `[DONE]` is always last (proto spec § 5.3). `StreamControllerSseSink`
> is the runtime wire — frames UTF-8 encoded onto a `StreamController` whose
> `body` stream the OpenAI adapter returns as the `text/event-stream` response
> body (boot wires it, E.41+); a client disconnect fires its optional
> `onClientDisconnect` seam, and a mid-stream cancel sets `isDisconnected` so
> the SSE path surfaces a terminal `DeliveryStalled` (E.39, above); the Telegram
> path is E.38.
>
> E.36 — the **`DeliveryRegistry`** opened `## E.8 — Outbound delivery`: the
> channel-agnostic dispatcher, "one registry, two delivery paths" (proto spec
> § 10.1). It registers one `ChannelDelivery` per `AccessChannel` (rejecting a
> duplicate per channel) and per inbound request produces the per-`Access`
> `DeliverCallback` the engine streams the answer through (`deliverFor`, AC-2).
> An unregistered channel throws `UnknownDeliveryChannel` (a loud boot-wiring
> fault). As the one channel-agnostic point in the outbound path the registry
> emits the terminal-success `AccessDelivered` on the answer's final chunk
> through an injected `onDelivered` sink (boot wires it to the
> `AccessEventBus`, E.41); with no sink it is a pure dispatcher.
>
> E.35 — the **`## E.7` test sweep** closed
> `## E.7 — Cheap kind-hint classifier`. The formal acceptance sweep
> (`test/heuristic_classifier/e7_kind_hint_sweep_test.dart`) exercises the
> *integrated* surface — the classifier with its embed seam bound to the cache,
> as boot wires it — and locks the three plan-named outcomes: confident
> classification produces a kindHint; uncertain / unknown leaves it null; a
> cache hit avoids the embed call.
>
> E.34 — the **in-process embedding cache** extends
> `## E.7 — Cheap kind-hint classifier`: `EmbeddingCache` (proto spec § 9.2) is
> keyed by *exact* inbound text with a 5-min TTL measured from compute time.
> `EmbeddingCache.embed` is itself a `KindHintEmbedder`, so the cache composes
> *in front of* the substrate seam without touching `HeuristicKindHintClassifier`
> — a cache hit returns the stored embedding and **saves the embed call** (the
> E.50 smoke and E.55 conformance assert the short-circuit). Only *resolved*
> embeddings are stored: a throwing embed call propagates and memoises nothing.
>
> E.33 — the **cheap kind-hint classifier** opened
> `## E.7 — Cheap kind-hint classifier`: `HeuristicKindHintClassifier` runs the
> three steps of proto spec § 9.1 — embed the inbound text (the `KindHintEmbedder`
> seam), `classify(embedding, ClassificationTarget.procedure)` (the
> `KindHintClassifier` seam, with the `ClassificationTarget.procedure` target
> fixed *inside* the seam so it never leaks into this package), and attach the
> returned procedure id as `InboundRequest.kindHint` *only* on a `confident`
> decision (else `null`, leaving the dispatcher's `classify_inbound_v1` to take
> over, D.15). `classifyKindHint(text)` returns the hint value; the access-local
> `KindHintClassification` / `KindHintDecision` mirror memory's
> `ClassificationResult` / `ClassificationDecision`, so the package depends on
> neither `tom_brain_substrate` nor `tom_brain_memory` (Plan E.7; AC-13). The
> classifier **never routes** (AC-9) and is allowed to be silent — uncertainty is
> a `null` hint, not an error; a confident-but-unroutable result (null / blank
> procedure id) also degrades to `null`. Seam *failures* propagate; the
> `access.classify.unavailable` graceful-degradation event is boot's (E.41+).
> E.32 — the **edge-security test sweep** closes
> `## E.6 — Edge security` on the test axis: a test-only composition of the four
> E.28 – E.31 checks in the documented chain order (auth → rate-limit → quota →
> anchor) locks the cross-cutting properties the per-component suites do not —
> auth failures surfacing per channel (OpenAI `401` vs. the Telegram whitelist
> decline), the rate-limit / quota `429` and anchor `400`, the distinctness of
> the three OpenAI statuses, and the short-circuit invariant (AC-4): no request
> becomes an `Access` unless it passes every check, and the first failing check
> stops the rest so the cheaper identity / throttle checks shed load before the
> content scan. E.32 is purely tests (no production change); boot wiring is E.41+.
> E.31 — the anchor pre-check is the fourth and last
> `## E.6 — Edge security` check: `AnchorPreCheck` is a stateless, content-keyed
> screen over an `AnchorPolicy`'s configurable list of disallowed prompt-fragment
> signatures (obvious prompt-injection patterns), matched case-insensitively as
> substrings. It runs last in the edge chain (after auth / rate-limit / quota) and
> before an `Access` exists (AC-3); `check` returns normally when nothing matches
> (or the screen is disabled — an empty list), or throws `AnchorPreCheckRejected`
> naming the matched signature. A rejection maps to `anchorPreCheckHttpStatus`
> (`400` — a structurally bad request, never the `429` of the rate/quota gates,
> OpenAI) / `telegramAnchorMessage` (a graceful, signature-blind "cannot process",
> Telegram). This is the access-side half of the assistant-dedication safety lever
> (def § 14.5); the substrate-side injection half is B.46; E.56 proves no inbound
> prompt reaches the dispatcher without passing it.
> E.30 — the per-principal daily LLM-call quota is the third
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
