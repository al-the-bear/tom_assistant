// This file now owns only `LlmCall`. `LlmOptions`, `ToolCatalogue`,
// `ToolDescriptor`, and `LlmCallReport` were migrated to `tom_core_agentic`
// (TomSpecs editor §20 step 3 / §19 T3) and are re-exported below; the
// historical B.9–B.13 narrative that follows documents their original design.
//
// B.9  — `LlmCall`, `LlmOptions`, `LlmCallReport`, `ToolCatalogue`.
// B.12 — extended `LlmOptions` with the `model` field per plan text
//        (model, temperature, max tokens, stop sequences, tool catalogue).
// B.13 — ratified `LlmCallReport` against the plan-step text. The B.9
//        shape (`providerId`, `modelId`, `anchorHash`, `promptHash`,
//        `tokensIn`, `tokensOut`, `retries`, `wallClockMs`, `cost?`,
//        `templateSha?`, `notes`) already covers — and exceeds — the
//        plan-text "tokens in/out, wall-clock, provider id, model id,
//        retry count" requirement, so this step adds *no* field and
//        *no* runtime code. What B.13 lands is (a) a conformance suite
//        (`test/b13_llm_call_report_test.dart`) that pins the post-B.13
//        field set, the defaults on the two optional fields, the
//        constructor-required-vs-optional split, and the
//        const-canonicalisation of structurally identical instances;
//        and (b) this header line, recording that the ratification
//        pass examined the class and accepted the B.9 shape. A future
//        rename / drop of any field surfaces as a compile failure in
//        the conformance suite. The plan text's "retry count" maps
//        verbatim to the `retries` field (Dart-idiomatic plural is
//        kept rather than introducing a `retryCount` alias).
//
// substrate_specification.md § 3.1 names these as the consumer-facing
// vocabulary of a substrate LLM call:
//
//   - `LlmCall   { roleId, inputs, options, budget, cancellationToken }`
//     — never carries a raw prompt; the role template + inputs assemble
//     the wire prompt at submission. This is the assistant-dedication
//     anchor's structural guarantee (spec § 6.3 / Postulate 3): the
//     consumer cannot bypass the anchor because the consumer cannot
//     supply the prompt.
//
//   - `LlmOptions { model, temperature, maxOutputTokens, stopSequences,
//                   toolCatalogue, responseFormat }`
//     — per-call provider-tunable knobs. The router may downgrade
//     unsupported knobs (e.g. JSON-mode on a provider that lacks it)
//     and surface the downgrade on the report's `notes`. The `model`
//     field is the caller's optional override of the route-resolved
//     model id; see field doc on [LlmOptions.model] for the resolution
//     order at the router.
//
//   - `LlmCallReport { providerId, modelId, anchorHash, promptHash,
//                      tokensIn, tokensOut, retries, wallClockMs,
//                      cost? }`
//     — what came back. `anchorHash` is the load-bearing field: every
//     report's hash must equal `AnchorRegistry.currentHash`; a
//     mismatch surfaces as `AnchorViolation` (spec § 12) and is the
//     substrate's structural proof that the call carried the anchor.
//
// At B.9 these are value classes only — there are no providers yet.
// The fields and their semantics are frozen here so the provider
// implementations (B.11+), the router (B.18+), the role registry
// (B.21+), and the anchor enforcement test (B.46) all agree on the
// same vocabulary.
//
// What this file deliberately does NOT own:
//
//   - The `WirePrompt` type. That is the *post-assembly* shape the
//     `LlmProvider` interface (spec § 4.1) consumes, and it lives
//     under `lib/src/llm/` (B.11+). Keeping it out of the api/
//     surface enforces the rule: consumers handle `LlmCall`,
//     providers handle `WirePrompt`, and the role registry is the
//     sole bridge between them.
//   - The role template type. `roleId` is a `String` here because
//     B.21 owns the template registry; the api/ layer only needs the
//     key. Replacing `String` with a stronger `RoleId` type later is
//     a single-line aliasing change that does not propagate.

import 'package:tom_brain_shared/tom_brain_shared.dart' show Budget, TurnId;
// LlmOptions / ToolCatalogue / ToolDescriptor / LlmCallReport migrated to
// `tom_core_agentic` (TomSpecs editor §20 step 3 / §19 T3). `LlmCall` keeps
// living here because it couples to brain-domain types (`Budget`, `TurnId`,
// `RouteEntry`) that sit above the generic agent layer; it imports the migrated
// value types from `tom_core_agentic` for its own surface.
import 'package:tom_core_agentic/tom_core_agentic.dart' show LlmOptions;

import '../router/route_entry.dart';
import 'cancellation.dart';

// Re-export the migrated value types so the `api/llm_call.dart` import path and
// the `api/` barrel surface stay unchanged for every consumer.
export 'package:tom_core_agentic/tom_core_agentic.dart'
    show LlmOptions, ToolCatalogue, ToolDescriptor, LlmCallReport;

/// One submission to the substrate's LLM path.
///
/// A `LlmCall` carries the *intent* of the call (which role,
/// what inputs to plug into the role's template, what knobs apply,
/// what budget, what cancellation token). It does **not** carry a
/// pre-assembled prompt — assembling the wire prompt is the
/// substrate's job, via the role registry, with the
/// assistant-dedication anchor prepended unconditionally
/// (substrate_specification.md § 6.3 + Postulate 3 in
/// `overview.tom_brain.md`).
///
/// Why `inputs` is `Map<String, Object?>` rather than typed
/// per-role: the role registry validates the inputs against the
/// role's declared schema at assembly time, and surfaces a typed
/// `RoleInputInvalid` on mismatch. Typing each role's inputs as a
/// distinct Dart class would force a procedure dispatcher (Phase D)
/// rewrite every time a new role lands; the schema validation path
/// keeps role authoring config-only.
final class LlmCall {
  /// Key into the role registry (`assistant_to_user`, `analyser`,
  /// `sub_thinker`, `recaller`, `evaluator` for the prototype).
  ///
  /// Adding a sixth role is a registry change (template file +
  /// registry entry), not a code change. `String` rather than a
  /// strongly-typed `RoleId` for that reason; the registry rejects
  /// unknown ids at submission with `RoleNotFound`.
  final String roleId;

  /// Inputs for the role's template. Keys are template variable
  /// names; values must be JSON-encodable (`String`, `num`, `bool`,
  /// `null`, `List<Object?>`, `Map<String, Object?>`). The registry
  /// validates the shape against the role's declared input schema.
  final Map<String, Object?> inputs;

  /// Per-call knobs. Defaults to [LlmOptions.empty]; the router /
  /// provider apply the role's `budgetDefaults` for any field the
  /// caller did not override.
  final LlmOptions options;

  /// Resource cap for this call. The router and provider charge
  /// tokens / wall-clock against the budget; an underflow raises
  /// `BudgetExceededError` (`tom_brain_shared`).
  ///
  /// Pass `Budget.unlimited` (a sentinel agreed with the budget
  /// module) for diagnostic / boot-time paths that are not under
  /// procedure control.
  final Budget budget;

  /// Read-only cancellation channel. Defaults to
  /// [CancellationToken.none] — i.e., uncancellable.
  final CancellationToken cancellationToken;

  /// The turn this call belongs to (logging-spec §3). Stamped by the
  /// procedure engine's per-run `SubstrateBridge` as the call is built — the
  /// "→ substrate" end of the `turnId` thread-through (§9). `null` for the
  /// internal / free-time / dream paths that do not run inside a user turn.
  final TurnId? turnId;

  /// This call's ordinal within its turn (logging-spec §3). Together with
  /// [turnId] it uniquely names any LLM call across the whole system. Starts
  /// at 1 and increments per LLM call of the turn (embeddings do not consume a
  /// seq). `null` whenever [turnId] is `null`.
  final int? callSeq;

  /// Optional **explicit** route chain to dispatch over, instead of the
  /// role-keyed `roleRoutes[roleId]` chain.
  ///
  /// This is the cognition-config `llm:` routing seam
  /// (`prompt_configuration.md` §8): a prompt selects its LLM route **by
  /// name**, the bridge resolves the name to a chain, and the substrate
  /// dispatches over that chain. The wire prompt is still assembled from
  /// [roleId]'s template — persona + assistant-dedication anchor and all — so
  /// the anchor invariant (Postulate 3) is untouched; only *route selection*
  /// moves off the role.
  ///
  /// `null` (every legacy caller) ⇒ route by [roleId] exactly as before. A
  /// non-empty list ⇒ route over it. An empty list is a config error and
  /// surfaces as `EmptyRouteChain` at dispatch.
  final List<RouteEntry>? routeChain;

  /// Per-run anchoring toggle (`session_configuration.md` § 3.4, plan step 9 /
  /// SCP-36). `true` (the default and every legacy caller) ⇒ the substrate
  /// assembles the wire prompt with the assistant-dedication anchor leading the
  /// `system` channel and stamps [AnchorRegistry.currentHash] — the Postulate-3
  /// path. `false` ⇒ the substrate omits the anchor and stamps
  /// [AnchorRegistry.unanchoredHash]; the anchor-enforcement check accepts the
  /// sentinel **only** because this flag declared the call un-anchored, so an
  /// un-anchored run is a deliberate, auditable choice and can never happen by a
  /// dropped hash. The procedure engine binds this from `Access.profile.anchored`
  /// per run; a script never sets it (the anchor is not a procedure concern).
  final bool anchored;

  const LlmCall({
    required this.roleId,
    required this.inputs,
    this.options = LlmOptions.empty,
    required this.budget,
    this.cancellationToken = CancellationToken.none,
    this.turnId,
    this.callSeq,
    this.routeChain,
    this.anchored = true,
  });
}

// ─── Migrated to tom_core_agentic ────────────────────────────────────────────
//
// `LlmOptions`, `ToolCatalogue`, `ToolDescriptor`, and `LlmCallReport` were
// moved verbatim into `tom_core_agentic` (the generic agent layer) so the LLM
// provider seam is reusable outside the brain. They are imported above for
// `LlmCall`'s own surface and re-exported above so this file's public surface is
// unchanged. The definitions live in:
//   - llm_options.dart      (LlmOptions, ToolCatalogue, ToolDescriptor)
//   - llm_call_report.dart  (LlmCallReport)
// inside `tom_core_agentic/lib/src/llm/`.
