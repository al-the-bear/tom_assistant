# Changelog

## 0.0.1 — 2026-06-02 (Phase E.40)

Delivery test sweep — the final step of `## E.8 — Outbound delivery` (Plan E.40;
proto spec § 10.1; AC-2). An integration-level sweep over both delivery paths,
wired the way boot wires them (through the `DeliveryRegistry`, over the runtime
sinks), complementing the per-step E.37 / E.38 / E.39 unit suites.

- `test/delivery/delivery_sweep_test.dart` — **new** (6 tests). (1) Each path
  delivers correctly: a multi-chunk SSE answer through `StreamControllerSseSink`
  arrives on the decoded UTF-8 wire in order, `[DONE]`-terminated, with a
  correlated `AccessDelivered`; a buffered, overflowing Telegram answer through
  `ChatApiTelegramSink` arrives as ordered plain-text messages with a correlated
  `AccessDelivered`. (2) The backpressure signal surfaces on both paths
  (terminal SSE stall through the backpressure stream; transient Telegram stall
  through `delivered`). (3) A disconnected SSE does not leak the run: cancelling
  the runtime sink's body subscription sets `isDisconnected`, fires
  `onClientDisconnect`, makes the next chunk stall terminally without rendering
  into the dead wire, and terminates the run (a later chunk throws); no
  `AccessDelivered` is emitted for the un-shipped answer.
- `lib/tom_brain_access_prototype.dart` / `lib/src/delivery/delivery.dart` —
  E.40 roadmap bullet flipped to ✅; pending range advanced to `E.41 – E.50 ⏳`.
  `## E.8 — Outbound delivery` is complete.

## 0.0.1 — 2026-06-02 (Phase E.39)

Delivery backpressure — the two delivery paths now surface a `DeliveryStalled`
through the `DeliverCallback`'s backpressure `Stream<OutboundChunk>` when the
channel cannot accept further chunks (Plan E.39; proto spec § 10.1; AC-2). The
signal types live in `tom_brain_shared` (engine + paths share them); the paths
produce them, the engine reacts (the engine wiring is a later step).

- `tom_brain_shared` `lib/src/access/backpressure.dart` — **new** (in the
  shared package). `BackpressureSignal` (sealed, `implements Exception`),
  `DeliveryStalled` (the one concrete signal — channel wire name, `StallReason`,
  `isTerminal`, optional `retryAfter`, `detail`; a terminal stall cannot carry a
  `retryAfter`, a negative `retryAfter` is rejected), `StallReason`
  (`clientDisconnected` / `rateLimited` / `channelClosed`), and `Backpressure`
  (`clear` / `stalled(signal)` stream builders). Exported from
  `tom_brain_shared.dart` and `src/access/access.dart`.
- `lib/src/delivery/sse_delivery.dart` — `SseSink` gains `isDisconnected`;
  `StreamControllerSseSink` sets it on a mid-stream subscription cancel (not on
  a normal close). `SseChannelDelivery.bindDeliver` checks `isDisconnected`
  before each write and, when set, terminates the binding and returns a
  *terminal* `DeliveryStalled` (`clientDisconnected`) via `Backpressure.stalled`
  rather than rendering into a dead wire (no leak).
- `lib/src/delivery/telegram_delivery.dart` — the buffered path cannot stall
  mid-stream, so the per-chunk stream is always `Backpressure.clear`; a backend
  rate limit (a transient `DeliveryStalled`) surfaces at flush through the
  binding's `delivered` future.
- `lib/tom_brain_access_prototype.dart` / `lib/src/delivery/delivery.dart` —
  E.39 roadmap bullet; pending range advanced to `E.40 – E.50 ⏳`.
- `test/delivery/backpressure_test.dart` — **new**. The E.39 delivery
  backpressure suite. `tom_brain_shared` `test/access/backpressure_test.dart` —
  **new**. The shared `DeliveryStalled` / `Backpressure` unit suite.

## 0.0.1 — 2026-06-02 (Phase E.38)

Telegram delivery path — the second of `## E.8`'s two `ChannelDelivery` slots
(Plan E.38; proto spec § 6.3 / § 10.1; AC-2). The concrete delivery path the
`DeliveryRegistry` (E.36) dispatches `AccessChannel.telegram` to. Unlike the
SSE path (which streams per chunk), Telegram is **buffered**: the callback
accumulates every `OutboundChunk` and, on the final chunk, consolidates the
answer into the minimum number of size-compliant messages and sends them in
order (one consolidated message, or N append-only overflow parts — def § Q13 /
Q-E.2.6).

- `lib/src/delivery/telegram_delivery.dart` — **new**. `TelegramChannelDelivery`
  (the `ChannelDelivery` for `AccessChannel.telegram`; `bindDeliver` mints the
  buffered per-`Access` `DeliverCallback`, holding the E.21
  `TelegramOutboundConsolidator` as channel policy), `TelegramDeliveryBinding`
  (its `DeliveryBinding` subtype carrying the `TelegramSink` and exposing a
  `delivered` future for actual-send completion), `TelegramSink` (the wire
  abstraction) and `ChatApiTelegramSink` (the runtime sink — each part sent
  through `tom_chattools` `ChatApi.sendMessage` as plain text). A chunk after
  the final one throws `StateError`; an empty answer sends nothing (Q-E.21.1).
  The returned backpressure stream is empty in the prototype (`DeliveryStalled`
  is E.39 / E.40).
- `lib/src/delivery/delivery.dart` — barrel now also exports the four E.38
  symbols.
- `lib/tom_brain_access_prototype.dart` — E.38 roadmap bullet; pending range
  advanced to `E.39 – E.50 ⏳`.
- `test/delivery/telegram_delivery_test.dart` — **new**. The E.38 contract
  suite (16 assertions).

## 0.0.1 — 2026-06-02 (Phase E.37)

SSE delivery path (OpenAI) — the first of `## E.8`'s two `ChannelDelivery`
slots (Plan E.37; proto spec § 5.3 / § 10.1; AC-2). The concrete delivery path
the `DeliveryRegistry` (E.36) dispatches `AccessChannel.openai` to: each
`OutboundChunk` becomes one `chat.completion.chunk` `data: …\n\n` frame; the
final chunk additionally writes `data: [DONE]\n\n` and closes the wire.

- `lib/src/delivery/sse_delivery.dart` — **new**. `SseChannelDelivery` (the
  `ChannelDelivery` for `AccessChannel.openai`; `bindDeliver` mints the
  per-`Access` `DeliverCallback`), `SseDeliveryBinding` (its `DeliveryBinding`
  subtype carrying the `SseSink` + the E.13 `ChatCompletionSseRenderer`, the
  latter bound per-`Access` so `id` / `created` repeat across the completion),
  `SseSink` (the wire abstraction) and `StreamControllerSseSink` (the runtime
  sink — UTF-8 frames onto a `StreamController` whose `body` is the
  `text/event-stream` response body; `onClientDisconnect` fires on body
  cancel). A chunk after the final one throws `StateError` (the wire is gone).
  The returned backpressure stream is empty in the prototype (`DeliveryStalled`
  is E.39 / E.40).
- `lib/src/delivery/delivery.dart` — barrel now also exports
  `SseChannelDelivery`, `SseDeliveryBinding`, `SseSink`,
  `StreamControllerSseSink`.
- `test/delivery/sse_delivery_test.dart` — **new** (17 assertions): path /
  binding channel; one content frame per non-final chunk with the OpenAI
  envelope (id / model / created repeated, `finish_reason` null); the final
  chunk writes its frame + `[DONE]` + closes; `[DONE]` is the last and only
  terminator line; single consolidated final chunk; empty backpressure stream;
  post-final `StateError`; per-`Access` independent termination; the runtime
  sink's UTF-8 body ordering, idempotent close, write-after-close `StateError`,
  and the client-disconnect callback; and dispatch + `AccessDelivered` through
  the E.36 registry.

Suite green at 397 / 397 (380 prior + 17 new E.37). `dart analyze` clean.

## 0.0.1 — 2026-06-02 (Phase E.36)

`DeliveryRegistry` — opens `## E.8 — Outbound delivery` (Plan E.36; proto spec
§ 10.1; AC-2). The channel-agnostic outbound-delivery dispatcher: "one
registry, two delivery paths". It registers one delivery path per channel and
per inbound request produces the per-`Access` `DeliverCallback` the engine
streams the answer through; the concrete wire translators (SSE E.37 / Telegram
E.38) implement the `ChannelDelivery` contract this step defines.

- `lib/src/delivery/channel_delivery.dart` — **new**. `DeliveryBinding` (the
  per-`Access` channel-bound context built before the `Access`) and
  `ChannelDelivery` (the contract one channel's delivery path implements:
  declares its `AccessChannel`, produces a per-`Access` `DeliverCallback` from
  a binding).
- `lib/src/delivery/delivery_registry.dart` — **new**. `DeliveryRegistry`
  (`register` one path per channel — duplicate is a `StateError`; `deliverFor`
  dispatches to the registered path; `UnknownDeliveryChannel` for an
  unregistered channel) and the terminal-success `AccessDelivered` emission on
  the final chunk through an injected `onDelivered` sink (boot wires it to the
  `AccessEventBus`, E.41).
- `lib/src/delivery/delivery.dart` — barrel now exports the four symbols.
- `test/delivery/delivery_registry_test.dart` — **new** (15 assertions):
  registration (empty → one → two paths; duplicate rejected); dispatch (binds
  the right path; passes chunks + backpressure through; `UnknownDeliveryChannel`
  for an unregistered channel); `AccessDelivered` emission (final chunk → one
  event with the chunk count + correlated identity; no sink → pure dispatcher;
  no second event after final; non-terminated → no event; UTC `occurredAt`;
  independent per-`Access` counters).

Suite green at 380 / 380 (365 prior + 15 new E.36). `dart analyze` clean.

## 0.0.1 — 2026-06-02 (Phase E.35)

`## E.7 — Cheap kind-hint classifier` test sweep — closes `## E.7`
(Plan E.35; proto spec § 9.1 + § 9.2; AC-9). The formal acceptance sweep over
the *integrated* surface: the `HeuristicKindHintClassifier` (E.33) with its
embed seam bound to the `EmbeddingCache` (E.34), exactly as boot (E.41+) wires
them.

- `test/heuristic_classifier/e7_kind_hint_sweep_test.dart` — **new** (6 assertions).
  - Confident classification produces a kindHint (the matched procedure id).
  - Uncertain / unknown classification leaves the kindHint null (the cheap
    path is silent; AC-9).
  - A cache hit avoids the embed call: a repeat of the exact prompt within the
    TTL short-circuits the substrate embed while still yielding the same hint;
    a repeat past the TTL re-embeds; a distinct prompt misses.

Suite green at 365 / 365 (359 prior + 6 new E.35). `dart analyze` clean.

## 0.0.1 — 2026-06-02 (Phase E.34)

In-process embedding cache — extends `## E.7 — Cheap kind-hint classifier`
(Plan E.34; proto spec § 9.2). `EmbeddingCache` memoises the substrate embed
call keyed by the *exact* inbound text, TTL 5 min (absolute, from compute
time). A cache hit returns the stored embedding and **saves the embed call**;
the cheap path gets cheaper on repeat prompts.

- `lib/src/heuristic_classifier/embedding_cache.dart` — **new**.
  - `EmbeddingCache.embed(text)` → `Future<List<double>>` is itself a
    `KindHintEmbedder`, so the cache composes *in front of* the substrate seam
    without touching `HeuristicKindHintClassifier`: boot binds the real
    `EmbeddingService` as the wrapped embedder and hands `cache.embed` to the
    classifier.
  - Absolute TTL from compute time (not sliding); a `DateTime Function() clock`
    seam (the edge-security limiter convention) makes expiry testable. A
    non-positive TTL is rejected at construction.
  - Resolved values only — a throwing embed call propagates and memoises
    nothing, so a transient substrate outage is not cached as a stale failure.
  - `size` (live, post-sweep) and `clear()` for tests / observability;
    expired entries are swept lazily on each access.
- `lib/src/heuristic_classifier/heuristic_classifier.dart` — exports
  `embedding_cache.dart`; E.34 note added.
- `lib/tom_brain_access_prototype.dart` — E.34 ✅ roadmap note; pending range
  advanced to `E.35 – E.50 ⏳`.
- `test/heuristic_classifier/embedding_cache_test.dart` — **new**, 12
  assertions: hit/miss, exact-text keying, TTL expiry + boundary, failure
  non-caching, classifier composition (hit saves the classifier's embed call),
  `size` / `clear`.

## 0.0.1 — 2026-06-02 (Phase E.33)

Cheap kind-hint classifier — opens `## E.7 — Cheap kind-hint classifier`
(Plan E.33; proto spec § 9.1; AC-9; def § 1.5). `HeuristicKindHintClassifier`
runs the three steps: embed the inbound text → classify the embedding against
the procedure centroids → attach the returned procedure id as
`InboundRequest.kindHint` *only* on a `confident` decision (else `null`,
leaving the dispatcher's `classify_inbound_v1` to take over). The classifier
never routes and is allowed to be silent.

- `lib/src/heuristic_classifier/heuristic_kind_hint_classifier.dart` — **new**.
  - `HeuristicKindHintClassifier.classifyKindHint(text)` → `Future<String?>`:
    the confident-only hint, trimmed; non-confident → `null`; confident-but-
    unroutable (null / blank procedure id) → `null`.
  - `KindHintEmbedder` (text → vector) and `KindHintClassifier`
    (vector → `KindHintClassification`) injected seams keep the package free
    of a `tom_brain_substrate` / `tom_brain_memory` import (Plan E.7; AC-13;
    mirrors the E.16 `EmbeddingSource` decision). The
    `ClassificationTarget.procedure` target is fixed *inside* the classify
    seam, so it never leaks here.
  - `KindHintClassification` / `KindHintDecision` — access-local mirror of
    memory's `ClassificationResult` / `ClassificationDecision`.
- `lib/src/heuristic_classifier/heuristic_classifier.dart` — E.33 ✅ note +
  `export 'heuristic_kind_hint_classifier.dart';`.
- `lib/tom_brain_access_prototype.dart` — E.33 ✅ bullet; pending range
  advanced to E.34 – E.50.
- `test/heuristic_classifier/heuristic_kind_hint_classifier_test.dart` —
  **new**; 11 assertions (confident hint, trimming, uncertain / unknown
  silence, confident-but-unroutable degradation, embed→classify step ordering
  and wiring, seam-failure propagation, the `KindHintClassification` value
  type). Suite green at 347 / 347.
- `README.md` — status block updated E.32 → E.33.

## 0.0.1 — 2026-06-02 (Phase E.32)

Edge-security test sweep — closes `## E.6 — Edge security` on the test axis
(Plan E.32; proto spec § "Edge-security tests"; AC-4). The four E.28 – E.31
components each ship a per-component conformance suite; this sweep composes
them in the documented chain order (auth → rate-limit → quota → anchor) and
locks the cross-cutting properties those suites do not: auth failures
surfacing in each channel's own dialect, the throttle / quota `429` and anchor
`400`, the distinctness of the three OpenAI statuses, and the short-circuit
invariant — no request becomes an `Access` unless every check passes, and the
first failing check stops the rest. Purely tests; no production behaviour
changes.

- `test/edge_security/edge_security_sweep_test.dart` — **new**; 17 assertions.
  - A test-local `runOpenAiEdgeChain` / `runTelegramEdgeChain` composes the
    public E.28 – E.31 surface exactly as boot (E.41+) will, recording the
    visited stages per run to prove the short-circuit.
  - Happy path (both channels pass all four checks); per-channel auth failure
    (OpenAI `401` vs. Telegram whitelist decline); rate-limit trigger (`429` /
    slow-down message); daily-quota trigger (`429` / daily-limit message);
    anchor rejection of every configured test signature (`400` / cannot-process
    message); chain-ordering proofs (an anchor-tripping prompt from an
    unauthenticated / throttled caller fails earlier and never reaches the
    content scan); the three OpenAI statuses are distinct and the four Telegram
    messages are distinct + non-empty.
- `lib/src/edge_security/edge_security.dart` — E.32 ✅ note.
- `lib/tom_brain_access_prototype.dart` — E.32 ✅ bullet; pending range
  advanced to E.33 – E.50.
- `README.md` — status block updated E.31 → E.32.

## 0.0.1 — 2026-06-02 (Phase E.31)

Anchor pre-check — the fourth and last edge-security check (Plan E.31;
proto spec § 8 / § 14.5; AC-3). Runs after the daily quota (E.30) and before
an `Access` is constructed; a prompt that trips a disallowed signature is
refused at the edge and never becomes an `Access`. This is the access-side
half of the assistant-dedication safety lever (the substrate-side injection
half is B.46). A rejection surfaces as `400` (OpenAI — a structurally bad
request, never the `429` of the rate/quota gates) / a graceful, signature-blind
"cannot process" message (Telegram).

- `lib/src/edge_security/anchor_precheck.dart` — **new**.
  - `AnchorPolicy` — immutable, defensively-copied config holding the
    configurable list of disallowed prompt-fragment signatures; validates
    each signature is non-empty (an empty signature would match all traffic);
    the list itself may be empty (the screen is then disabled). Pre-folds the
    signatures to lower case once for case-insensitive matching.
  - `AnchorPreCheck` — stateless, content-keyed screen (no per-principal state,
    no clock, no I/O). `check(promptText)` returns normally when nothing
    matches (or the screen is disabled), or throws `AnchorPreCheckRejected`
    naming the first matching signature. Matching is case-insensitive substring.
  - `AnchorPreCheckRejected` — typed failure carrying the matched signature
    (config, non-secret — safe to log); never carries the rejected prompt text.
  - `anchorPreCheckHttpStatus` (`400`) and `telegramAnchorMessage` (a graceful,
    signature-blind "cannot process") — the single channel-mapping sources.
- `lib/src/edge_security/edge_security.dart` — exports `anchor_precheck.dart`;
  E.31 ✅ note (E.32 is the edge-security test sweep).
- `lib/tom_brain_access_prototype.dart` — E.31 ✅ bullet; pending range
  advanced to E.32 – E.50.
- `test/edge_security/anchor_precheck_test.dart` — **new**; 16 assertions
  (policy validation + immutability, reject/pass, case-insensitive substring
  matching, configured-casing reporting, disabled screen, first-match
  short-circuit, channel-mapping constants + barrel surface).

## 0.0.1 — 2026-06-02 (Phase E.30)

Per-principal daily LLM-call quota — the third edge-security check
(Plan E.30; proto spec § 8; AC-4). Runs after the token-bucket rate limiter
(E.29) and before an `Access` is constructed; a request that has spent its
principal's daily allowance never becomes an `Access`. A failure surfaces as
`429` (OpenAI) / a graceful "daily limit reached" message (Telegram).

- `lib/src/edge_security/quota.dart` — **new**.
  - `DailyQuotaPolicy` — immutable cap config (`dailyCap`); validates
    `dailyCap >= 1`.
  - `DailyQuotaLimiter` — one calendar-day counter per non-secret
    `principalId` (never the bearer token); `check(principalId)` counts one
    call and returns, or throws `DailyQuotaExceeded`. The counter resets on
    the calendar-day roll-over (in the clock's zone); a rejected request is
    not counted. Day boundary read through an injectable `clock` seam.
    In-process counter state for the prototype (Q-E.2.5 / Q-E.30.1).
  - `DailyQuotaExceeded` — typed failure carrying the non-secret
    `principalId` and a strictly-positive `retryAfter` (the wait until the
    next day boundary).
  - `quotaHttpStatus` (`429`, aliasing the rate limiter's
    `rateLimitHttpStatus` — one underlying source) / `telegramQuotaMessage`
    — the single channel-mapping constants the adapters (E.41+) read.
- `lib/src/edge_security/edge_security.dart` — exports `quota.dart`
  (E.30 ✅; E.31 still pending).
- `lib/tom_brain_access_prototype.dart` — E.30 ✅ note; pending range
  advanced `E.30 – E.50 ⏳` → `E.31 – E.50 ⏳`.
- `test/edge_security/quota_test.dart` — **new**, 16 assertions
  (policy validation, daily allowance, per-principal isolation, day-boundary
  reset, `retryAfter`, UTC day boundary, argument validation, channel-mapping
  constants + barrel surface). Suite green at 303 / 303.

## 0.0.1 — 2026-06-02 (Phase E.29)

Per-principal token-bucket rate limiting — the second edge-security check
(Plan E.29; proto spec § 8; AC-4). Runs after bearer auth (E.28) and before
an `Access` is constructed; a request that exceeds its principal's bucket
never becomes an `Access`. A failure surfaces as `429` (OpenAI) / a graceful
"slow down" message (Telegram).

- `lib/src/edge_security/rate_limiter.dart` — **new**.
  - `RateLimitPolicy` — immutable bucket config (`capacity` burst,
    `refillTokens` per `refillPeriod`); validates capacity >= 1,
    refillTokens > 0, refillPeriod > 0.
  - `RateLimiter` — one continuous-refill bucket per non-secret
    `principalId` (never the bearer token); `check(principalId)` consumes one
    token and returns, or throws `RateLimitExceeded`. Lazy wall-clock refill
    (no timer); idle principals cost nothing; refill read through an
    injectable `clock` seam. In-process bucket state for the prototype
    (Q-E.2.5).
  - `RateLimitExceeded` — typed failure carrying the non-secret
    `principalId` and a finite, strictly-positive `retryAfter` (the wait
    until one token refills; the OpenAI `Retry-After` value). A rejected
    request is not charged.
  - `rateLimitHttpStatus` (`429`) and `telegramRateLimitMessage` — the single
    channel-mapping sources the adapters (E.41+) read.
- `lib/src/edge_security/edge_security.dart` — `export 'rate_limiter.dart';`
  + E.29 ✅ note; E.30 / E.31 remain pending.
- `lib/tom_brain_access_prototype.dart` — E.29 ✅ bullet; pending range
  advanced E.29 – E.50 → E.30 – E.50.
- `test/edge_security/rate_limiter_test.dart` — **new** (18 assertions).

## 0.0.1 — 2026-06-02 (Phase E.28)

Bearer-token auth — the first edge-security check, opening
`## E.6 — Edge security` (Plan E.28; proto spec § 8; AC-4). The
OpenAI-channel credential check runs *before* an `Access` is constructed; a
failure maps to `401` and the request never becomes an `Access`. Mirrors the
Phase-A A.76 bearer contract (same interface / failure taxonomy / `Jwt…` +
`Static…` implementations), re-implemented here because the access prototype
must not depend on `tom_brain_memory` (a phase-end E.52 extraction into
`tom_brain_shared` is the place to unify them — Q-E.28.2).

- `lib/src/edge_security/bearer_auth.dart` — **new**.
  - `BearerTokenAuthenticator` — the synchronous validate-or-throw contract
    (`authenticate(token) → TomPrincipal`).
  - `StaticBearerTokenAuthenticator` — the prototype default; a closed,
    defensively-copied token→principal map (opaque shared secrets).
  - `JwtBearerTokenAuthenticator` — the canonical
    `TomBearerAuthentication.convertTokenPayloadToPrincipal` path; rejects
    guest / non-authenticated principals.
  - `BearerAuthFailure` / `BearerAuthFailureReason` (`missing` / `malformed`
    / `rejected`) — the closed failure taxonomy; the token string never
    appears in the message (no token-introspection side channel).
  - `parseBearerHeader` — lifts the token out of `Authorization: Bearer
    <token>` (scheme matched case-insensitively); `authenticateBearerHeader`
    composes parse + authenticate.
  - `bearerAuthHttpStatus` (`401`), `bearerScheme`, `authorizationHeaderName`
    — the single-source constants the OpenAI adapter (E.41+) reads.
- `lib/src/edge_security/edge_security.dart` — exports `bearer_auth.dart`;
  E.28 ✅ note + the E.29 – E.31 pending list.
- `lib/tom_brain_access_prototype.dart` — E.28 ✅ bullet; pending range
  advanced to E.29 – E.50.
- `test/edge_security/bearer_auth_test.dart` — **new**. 23 assertions:
  header parsing (every missing / malformed shape, case-insensitive scheme,
  no header echo), the static + JWT authenticators, the composed
  `authenticateBearerHeader`, the `401` / scheme / barrel-surface contract,
  and the no-token-leak guarantee.

## 0.0.1 — 2026-06-02 (Phase E.27)

Resolution-test sweep — the cross-resolver suite closing
`## E.5 — Identity, session, persona` (Plan E.27). Tests-only; no new
source.

- `test/identity/identity_resolution_sweep_test.dart` — **new**. 13
  assertions across four groups, exercising the three resolvers
  (`IdentityResolver` E.24, `SessionManager` E.25, `PersonaResolver` E.26)
  the way the edge composes them:
  - **token / user-id resolution** — a bound bearer token and a bound
    Telegram user id each resolve to the configured identity; both channels
    of one person resolve to the *same* `ResolvedIdentity` (AC-7); the
    principal id never echoes the secret token; an unbound credential throws
    `IdentityResolutionException` with the right channel.
  - **session reuse across calls** — repeated calls on one identity +
    channel + conversation reuse the same node (AC-8); the channel splits one
    person into two sessions; different conversations are different sessions.
  - **persona defaulting** — a recognised model id round-trips; `null` and an
    unrecognised id both fall back to `Persona.assistant()` (AC-5).
  - **cohesion** — a multi-turn conversation keeps identity + persona stable
    while the session accumulates turns and stays keyed by the resolved
    principal id; the `Session` handle projection carries the resolved
    conversation id.

## 0.0.1 — 2026-06-02 (Phase E.26)

`PersonaResolver` — the third and last of the three `Access`-filling
resolvers (proto spec § 7.3, Plan E.26, AC-5). Maps a model id (or its
absence) to the `Persona` the dispatcher hands to substrate.

- `lib/src/identity/persona_resolver.dart` — **new**. Symbol:
  - `PersonaResolver` — `resolve(String? modelId)` yields a `Persona`
    carrying the recognised id and the prototype substrate role
    `assistant_to_user`; a `null` or unrecognised id falls back to
    `Persona.assistant()` (AC-5 — an unknown model is not an error).
    `isKnown(String?)` mirrors the recognition test. `knownModels` defaults
    to the shared `OpenAiPersonaMapping.knownModels` (the single id-list
    source of truth E.15 established) and is injectable + copied
    unmodifiable for the `AccessConfig` persona vocabulary at boot (E.41+).
- `lib/src/identity/identity.dart` — barrel now exports the persona resolver.
- `lib/tom_brain_access_prototype.dart` — E.26 ✅ bullet; pending range
  narrowed to E.27 – E.50.
- `test/identity/persona_resolver_test.dart` — **new** (13 assertions):
  default vocabulary is the shared list + unmodifiable; each of the three
  ids round-trips to `assistant_to_user`; `null` / unknown / empty default
  to `Persona.assistant()`; `isKnown` matches; an injected vocabulary
  widens/narrows the recognised set and is copied unmodifiable.

## 0.0.1 — 2026-06-02 (Phase E.25)

`SessionManager` — the second of the three `Access`-filling resolvers
(proto spec § 7.2, Plan E.25, AC-8). Resolves an inbound request to a
sliding-window session keyed by (principal, channel, conversation id);
reuse is *by key, not by re-creation*.

- `lib/src/identity/session_manager.dart` — **new**. Symbols:
  - `SessionManager` — `resolve({identity, channel, envelope})` builds the
    key from `identity.principalId` + `channel` + `envelope.conversationId`,
    reuses the existing node (appending the turn, sliding the window) or
    creates one, and returns the node. `peek(key)` reads without mutating.
    Injectable `sessionIdFactory` and `now` clock for deterministic tests;
    `maxWindowTurns` (default 20) caps the window.
  - `AccessChannel` — the channel discriminator (`openai` / `telegram`),
    the second key component; wire names match E.24's `channel` strings.
  - `SessionKey` — the (principal, channel, conversation id) triple; a Dart
    `record` form keys the store so distinct triples never collide.
  - `SessionTurn` / `SessionNode` — one recorded turn and the rich
    sliding-window node; `toSessionHandle()` projects onto the shared
    `Session`. The node store is in-process (the access layer never depends
    on `tom_brain_memory`; memory-node persistence is wired through the
    dispatcher at E.27 / E.55).
- `lib/src/identity/identity.dart` — barrel now exports the session manager.
- `lib/tom_brain_access_prototype.dart` — E.25 ✅ bullet; pending range
  narrowed to E.26 – E.50.
- `test/identity/session_manager_test.dart` — **new** (20 assertions):
  channel wire names; key guards / equality / record-collision-safety;
  create / reuse-by-key (AC-8); channel + conversation-id key splitting;
  null-conversation rolling session; sliding window at capacity with
  running `totalTurns`; `Session` handle projection; construction guards;
  injected clock + id factory; `peek`.

## 0.0.1 — 2026-06-02 (Phase E.24)

`IdentityResolver` — the first of the three `Access`-filling resolvers
(proto spec § 7.1, Plan E.24, AC-7). Maps an inbound credential to a
`ResolvedIdentity` once at the edge; the dispatcher reads only
`identity.principalId` and never re-authenticates.

- `lib/src/identity/identity_resolver.dart` — **new**. Three symbols:
  - `IdentityResolver` — `resolveOpenAiBearer(token)` /
    `resolveTelegramUser(userId)` look the credential up in a per-channel
    registry, build a `tom_core_kernel` `TomPrincipal`, and project it to a
    `tom_brain_shared` `ResolvedIdentity`.
  - `IdentityBinding` — the prototype principal-facts record per known
    credential: a stable, non-secret `principalId` (never derived from the
    bearer token), `username` (defaults to `principalId`), `numericId`,
    optional `displayName`, unmodifiable `claims`.
  - `IdentityResolutionException` — typed failure for an unbound credential
    (config drift between auth and identity), carrying a non-secret detail
    (the OpenAI variant never echoes the token).
- `lib/src/identity/identity.dart` — barrel now exports the resolver.
- `lib/tom_brain_access_prototype.dart` — E.24 ✅ bullet; pending range
  narrowed to E.25 – E.50.
- `test/identity/identity_resolver_test.dart` — **new** (12 assertions):
  binding guards/defaults/defensive-copy; bearer-token resolution + the
  no-token-leak guard; Telegram resolution + the unbound-throw; cross-channel
  identity (one binding on both channels yields one `ResolvedIdentity`,
  AC-7); empty resolver throws for every credential.

Tests: 200 passed (188 prior + 12 new). `dart analyze` clean.

## 0.0.1 — 2026-06-02 (Phase E.23)

Telegram channel conformance suite (proto spec § 6, Plan E.23). The whole
Telegram surface is now exercised end-to-end through the in-process
`LoopbackChatApi` double — the black-box conformance the substep tests
(E.19 – E.22) build toward.

- `test/adapters/telegram_roundtrip_conformance_test.dart` — **new** (9
  assertions). Three groups:
  - **Roundtrip** (2): a whitelisted message round-trips
    inbound→authorise→outbound on one running adapter (the mapped
    `InboundRequest` is answered on its own conversation via `sendAnswer`,
    plain text, no decline); the roundtrip survives the full lifecycle
    (nothing after `stop()`, one disconnect).
  - **Whitelist enforcement** (3): a non-whitelisted sender is declined and
    never produces a request; mixed traffic passes only whitelisted senders
    with one decline each; the default (unconfigured) whitelist rejects
    everyone (fail-closed, Q-E.22.1).
  - **Large-answer chunking at the real 4096 limit** (4): a 10000-unit answer
    splits into the minimum 3 size-compliant messages (lossless, same
    receiver, plain text); a many-chunk over-limit answer chunks correctly
    after buffering; an astral-heavy (emoji) over-limit answer never splits a
    character and stays within the limit; an answer exactly at the limit is
    one message.
- No production code changed — E.23 is a tests-only conformance step. Suite
  green at 188 / 188 (179 prior + 9 new). `dart analyze` clean.

## 0.0.1 — 2026-06-02 (Phase E.22)

Telegram edge auth gate — the user-id whitelist (proto spec § 6.4 / § 8,
Plan E.22). A non-whitelisted sender is rejected before any `Access` is
constructed.

- `lib/src/adapters/telegram/telegram_whitelist.dart` — `TelegramWhitelist`:
  the pure, immutable configured set of allowed Telegram user ids;
  `isAllowed(senderId)` is an exact, case-sensitive match. `.empty()` (and a
  whitelist built from no ids) allows no one — a fail-closed default
  (Q-E.22.1). Public constant `telegramNotAuthorisedMessage` (the graceful
  plain-text decline).
- `lib/src/adapters/telegram/telegram_adapter.dart` — adds the injectable
  `whitelist` (constructor + `fromConfig`, default `TelegramWhitelist.empty()`)
  and the `authorizedInboundRequests` stream: `inboundRequests` gated by the
  whitelist via `asyncExpand`. A non-whitelisted sender draws
  `telegramNotAuthorisedMessage` (sent back through `sendMessage`) and the
  request is dropped — nothing surfaces, so no `Access` is built (AC-3, AC-4).
  Auth is the outermost gate (runs before the inbound text mapping). The
  ungated `inboundRequests` stays exposed for observability.
- `test/adapters/telegram_whitelist_test.dart` — the E.22 contract test (13
  assertions: pure-policy membership / closed default / defensive copy /
  unmodifiable view; adapter gate — surface, decline, interleaving, silent
  non-text drop, auth-outermost, default-closed, ungated view unaffected).

## 0.0.1 — 2026-06-02 (Phase E.21)

Telegram outbound mapping (proto spec § 6.3, Plan E.21). An answer's
streamed `Stream<OutboundChunk>` is consolidated into one Telegram message —
or, on overflow, the minimum number of size-compliant messages.

- `lib/src/adapters/telegram/telegram_outbound_mapping.dart` —
  `TelegramOutboundConsolidator`: `consolidate(Stream<OutboundChunk>)`
  buffers every chunk's `textDelta` into the full answer (symmetric with
  `ChatCompletionJsonRenderer`, E.14), then `split(String)` packs whole
  Unicode characters greedily by **UTF-16 code-unit** length into the fewest
  messages each ≤ `telegramMaxMessageLength` (4096) — never cutting a
  character, minimal among character-safe splits. An empty answer yields no
  messages (Q-E.21.1). Public constant `telegramMaxMessageLength`.
- `lib/src/adapters/telegram/telegram_adapter.dart` — adds
  `Future<List<ChatMessage>> sendAnswer({receiver, answer})`: consolidates
  the answer and sends each part through `ChatApi.sendMessage` as plain text
  (no `parseMode`, typing indicator, or inline buttons — Stage-1, def § Q13).
  The `TelegramOutboundConsolidator` is injectable on the constructor /
  `fromConfig` (default: the real 4096 limit; tests lower it).
- `test/adapters/telegram_outbound_mapping_test.dart` — 14 assertions: pure
  split (empty, fit, one-over, minimal count, whole-rune safety, UTF-16
  counting), chunk buffering (concat, final-chunk text, empty stream / empty
  deltas, overflow), and `sendAnswer` (plain-text single send, minimum-count
  overflow send to one receiver, empty-answer-sends-nothing).

## 0.0.1 — 2026-06-02 (Phase E.20)

Telegram inbound mapping (proto spec § 6.2, Plan E.20). A Telegram
`ChatMessage` is projected onto the channel-agnostic `InboundRequest` the
dispatcher consumes.

- `lib/src/adapters/telegram/telegram_inbound_mapping.dart` —
  `TelegramInboundMapping.toInboundRequest()` (extension on `ChatMessage`):
  `text` from the body, `messageId` from `platformMessageId ?? id`,
  `conversationId` from `rawData['telegram_chat_id']` (falling back to the
  sender id for a private chat — Q-E.20.1), the sender id on
  `metadata[telegramSenderIdMetadataKey]` for `IdentityResolver` (E.24,
  Q-E.20.2), `streaming: false`. A non-text Stage-1 message returns
  `Err(TelegramInboundError)` with `TelegramInboundRejection.noText` (ignored
  + logged, proto spec § 12). Public constants `telegramSenderIdMetadataKey`
  and `telegramChatIdRawDataKey`.
- `lib/src/adapters/telegram/telegram_adapter.dart` — adds
  `Stream<InboundRequest> get inboundRequests`: `inboundMessages` projected
  through the mapping, emitting one request per text message and dropping
  non-text messages.
- `lib/src/adapters/telegram/telegram.dart` — barrel now also exports the
  inbound mapping.
- `test/adapters/telegram_inbound_mapping_test.dart` — 11 assertions (field
  mapping, private-chat fallback, message-id fallback, unmodifiable metadata,
  non-text rejection, and the adapter's mapped/filtered `inboundRequests`).
- `lib/tom_brain_access_prototype.dart` — E.20 ✅ bullet; pending range
  narrowed `E.20 – E.50` → `E.21 – E.50`.

## 0.0.1 — 2026-06-02 (Phase E.19)

Telegram adapter scaffold (proto spec § 6.1, Plan E.19). The prototype's
Telegram channel, built on `tom_chattools`' `ChatApi` + `TelegramChatConfig`,
running long-polling. Scaffold only — the inbound mapping (E.20), outbound
consolidation (E.21), and whitelist (E.22) follow.

- `lib/src/adapters/telegram/telegram_adapter.dart` — `TelegramAdapter`:
  `start()` initialises the backend and subscribes to its `onMessage` stream,
  relaying each inbound `ChatMessage` to `inboundMessages`; `stop()` cancels
  the subscription, disconnects, and closes the relay (both idempotent).
  `TelegramAdapter.fromConfig(config, {buildChatApi})` builds the real backend
  via `config.createApi(...)` by default, with a builder seam for tests.
- `lib/src/adapters/telegram/telegram.dart` — barrel now exports the adapter.
- `test/_support/loopback_chat_api.dart` — `LoopbackChatApi implements ChatApi`
  in-process double (E.5 decision; first authored here): broadcast `onMessage`
  + `injectText`/`injectInbound`, outbound recorder, counted lifecycle,
  `UnimplementedError` on the text-only-out-of-scope surface.
- `test/adapters/telegram_adapter_test.dart` — 13 contract assertions
  (lifecycle, idempotency, inbound relay order/close, factory seam).
- `lib/tom_brain_access_prototype.dart` — E.19 ✅ bullet; pending range
  narrowed `E.19 – E.50` → `E.20 – E.50`.

## 0.0.1 — 2026-06-02 (Phase E.18)

OpenAI HTTP/SSE adapter — wire-format conformance suite (AC-6, proto spec
§ 13). No production code change; E.18 is the consolidated contract suite
proving the whole adapter speaks the OpenAI wire format through its public
`handler`.

- `test/adapters/openai_wire_format_conformance_test.dart` — 9 black-box
  assertions over one fully-wired adapter (both the `ChatAnswerStream` and the
  `EmbeddingSource` seams injected): the full `chat.completion` non-streaming
  envelope + buffered-body completeness + seam pass-through; the streaming
  path's ordered `chat.completion.chunk` frames, repeated completion id,
  per-chunk `finish_reason`, terminal `data: [DONE]`, and `cache-control`;
  the embeddings list envelope (substrate `model` echo); the models-list
  envelope (exactly the persona vocabulary); and the cross-route invariants
  (per-route content-type; the OpenAI `400` / `404` error envelope shape).
- `lib/tom_brain_access_prototype.dart` — E.18 ✅ bullet added; trailing
  pending range narrowed `E.18 – E.50` → `E.19 – E.50`.
- `lib/src/adapters/openai_http_sse/openai_http_sse_adapter.dart` — file-header
  route map notes E.18 is proven (no code change).
- `README.md` — status block E.17 → E.18 (the conformance suite + the new
  test file in the lock list).

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
