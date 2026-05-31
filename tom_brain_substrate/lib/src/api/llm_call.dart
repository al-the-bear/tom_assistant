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

import 'package:tom_brain_shared/tom_brain_shared.dart' show Budget;

import 'cancellation.dart';

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

  const LlmCall({
    required this.roleId,
    required this.inputs,
    this.options = LlmOptions.empty,
    required this.budget,
    this.cancellationToken = CancellationToken.none,
  });
}

/// Per-call provider-tunable knobs.
///
/// Every field is optional. The router resolves unset fields against
/// the role's `budgetDefaults` (spec § 6.1). Providers that do not
/// support a given knob downgrade gracefully and append a note to
/// [LlmCallReport.notes]; substrate does not fail the call just
/// because a knob did not apply.
///
/// At plan step B.12 the field set landed as
/// `(model, temperature, maxOutputTokens, stopSequences, toolCatalogue,
/// responseFormat)`. `responseFormat` is an additive extension of the
/// plan-text list — it was already shipped at B.9 and is kept because
/// it does not collide with any other knob and consumers that do not
/// supply it pay zero cost.
final class LlmOptions {
  /// Optional override of the route-resolved model id.
  ///
  /// Resolution order at the router (B.18+):
  ///
  ///   1. If [model] is non-null, the router uses it verbatim, subject
  ///      to availability on the selected provider's route chain. A
  ///      route chain that does not expose this model surfaces a typed
  ///      `ModelNotAvailableInRoute` (no silent fallback).
  ///   2. If [model] is null, the router consults the role's
  ///      `budgetDefaults.modelPreference` (spec § 6.1) — a list of
  ///      preferred model ids, in priority order, the first
  ///      route-available one wins.
  ///   3. If neither yields a model, the route's provider default
  ///      (e.g. Ollama's `OLLAMA_DEFAULT_MODEL`) applies.
  ///
  /// The resolved model id is stamped onto [LlmCallReport.modelId]
  /// for trail attribution regardless of which step in the
  /// resolution chain produced it.
  ///
  /// Stored as `String?` (not a stronger `ModelId` type) for the same
  /// reason [LlmCall.roleId] is `String`: model ids are configured
  /// (`providers[*].models[*].id`), not enumerated in code, and a
  /// per-provider registry would force a substrate rebuild every time
  /// a new model becomes available.
  ///
  /// Plan step B.12 named this field "model" verbatim; the public
  /// getter follows that name. Equivalent terms ("modelId",
  /// "modelName") deliberately do not exist on this surface to keep
  /// one canonical spelling across config, trail, and code.
  final String? model;

  /// Sampling temperature in `[0.0, 2.0]`. `null` ⇒ provider /
  /// role default.
  final double? temperature;

  /// Hard cap on the response token count. `null` ⇒ provider /
  /// role default.
  ///
  /// The plan text at B.12 says "max tokens"; the field keeps the
  /// fuller name `maxOutputTokens` because every prototype provider
  /// (Ollama `/api/chat`'s `num_predict`, OpenAI `max_tokens`)
  /// applies the cap to output only — input-token bounding lives on
  /// [LlmCall.budget] (token-spend ceiling), not on this knob.
  final int? maxOutputTokens;

  /// Generation halts when any of these strings appears in the
  /// emitted text. Always treated as an unordered set (the provider
  /// may reorder for prefix matching).
  ///
  /// Defaults to `const <String>[]` (no stop sequences). Consumers
  /// that pass `null` for this field would defeat the const default;
  /// the constructor signature therefore makes it non-nullable with
  /// an empty-list default rather than accepting `null`.
  final List<String> stopSequences;

  /// Tools the role is allowed to call during this completion.
  /// Empty ⇒ no tool calls permitted. The provider must surface
  /// proposed tool calls as `LlmStreamEvent.toolCallProposed`
  /// events and wait for the dispatcher's tool-call adapter to
  /// resolve them.
  final ToolCatalogue toolCatalogue;

  /// Optional structured-response declaration. Currently a JSON
  /// schema as a `Map<String, Object?>`; later phases may swap to
  /// a stronger type. `null` ⇒ free-form text response.
  ///
  /// Not named by the B.12 plan text but additive; see the class
  /// docstring on why it stays.
  final Map<String, Object?>? responseFormat;

  const LlmOptions({
    this.model,
    this.temperature,
    this.maxOutputTokens,
    this.stopSequences = const <String>[],
    this.toolCatalogue = ToolCatalogue.empty,
    this.responseFormat,
  });

  /// The all-defaults instance. Used as the default value on
  /// [LlmCall.options]; consumers that need to tweak one field
  /// build a new instance.
  ///
  /// Equivalent to `const LlmOptions()` — every field is at its
  /// "router resolves" default ([model]/[temperature]/[maxOutputTokens]
  /// null, [stopSequences] empty, [toolCatalogue] empty,
  /// [responseFormat] null).
  static const LlmOptions empty = LlmOptions();

  /// Returns a copy of this instance with selected fields replaced.
  ///
  /// The B.12 plan text does not name `copyWith`; it is added here
  /// because the conformance test for `LlmOptions` (and the router's
  /// future field-merge logic at B.18+) need a zero-allocation path
  /// to override one knob without re-listing the rest. Naming the
  /// sentinel `_unset` (private) prevents callers from passing it by
  /// accident: passing `null` for [model], [temperature],
  /// [maxOutputTokens], or [responseFormat] explicitly clears the
  /// field (sets it to null), while omitting the parameter leaves
  /// the existing value untouched.
  LlmOptions copyWith({
    Object? model = _unset,
    Object? temperature = _unset,
    Object? maxOutputTokens = _unset,
    List<String>? stopSequences,
    ToolCatalogue? toolCatalogue,
    Object? responseFormat = _unset,
  }) {
    return LlmOptions(
      model: identical(model, _unset) ? this.model : model as String?,
      temperature: identical(temperature, _unset)
          ? this.temperature
          : temperature as double?,
      maxOutputTokens: identical(maxOutputTokens, _unset)
          ? this.maxOutputTokens
          : maxOutputTokens as int?,
      stopSequences: stopSequences ?? this.stopSequences,
      toolCatalogue: toolCatalogue ?? this.toolCatalogue,
      responseFormat: identical(responseFormat, _unset)
          ? this.responseFormat
          : responseFormat as Map<String, Object?>?,
    );
  }

  /// Private sentinel used by [copyWith] to distinguish "omit" from
  /// "explicitly set to null" on nullable fields. Not exported.
  static const Object _unset = Object();
}

/// The catalogue of tools a role may invoke during a completion.
///
/// A separate type rather than a `List<ToolDescriptor>` so the
/// substrate can later attach catalogue-level metadata (provenance
/// hash, supported-by-provider matrix, etc.) without churning every
/// call site.
final class ToolCatalogue {
  /// The tools available, in declaration order. Provider adapters
  /// translate these into provider-native tool schemas.
  final List<ToolDescriptor> tools;

  const ToolCatalogue(this.tools);

  /// The catalogue with zero tools. Use this when the role is not
  /// allowed to invoke any tool during the completion.
  static const ToolCatalogue empty = ToolCatalogue(<ToolDescriptor>[]);

  bool get isEmpty => tools.isEmpty;
  bool get isNotEmpty => tools.isNotEmpty;
}

/// One tool the LLM may propose calling during a completion.
///
/// Mirrors the OpenAI-compatible tool-use shape (`{name, description,
/// parameters}` with a JSON schema for parameters) rather than the
/// MCP `Tool` shape, because the LLM-facing surface speaks the
/// OpenAI dialect at every passthrough provider. The
/// `procedure_dispatcher` adapts MCP tools to this shape at submission.
final class ToolDescriptor {
  /// Canonical tool name. The LLM proposes calls keyed by this name;
  /// the dispatcher resolves the name back to a callable tool.
  final String name;

  /// Human-readable description fed to the LLM as part of the
  /// system prompt. Tone is "what the tool does and when to call
  /// it", not "how it is implemented".
  final String description;

  /// JSON-schema-shaped parameter spec. Pass `{}` for parameter-less
  /// tools (rare).
  final Map<String, Object?> parametersSchema;

  const ToolDescriptor({
    required this.name,
    required this.description,
    required this.parametersSchema,
  });
}

/// Report produced when an LLM call completes (successfully or with
/// failure that the router could classify).
///
/// Carries enough provenance for the trail (`memory_specification.md`
/// § 8) to attribute every byte of LLM activity:
///
///   - `providerId` / `modelId` — which route served the call.
///   - `anchorHash` — content hash of the anchor block that was
///     prepended. Compared against `AnchorRegistry.currentHash` on
///     every report; a mismatch is `AnchorViolation` (spec § 12)
///     and is the substrate's structural proof of Postulate 3.
///   - `promptHash` — content hash of the assembled wire prompt
///     (anchor + role text + inputs). Lets the trail correlate
///     prompts across runs without storing the body.
///   - `tokensIn` / `tokensOut` — when the provider returns usage
///     fields; else estimated via the per-model-family tokeniser
///     (B.13 / spec § 4.4).
///   - `retries` — how many in-router retries happened before this
///     report. 0 on a first-shot success.
///   - `wallClockMs` — total wall-clock between submission and
///     completion (includes retry waits).
///   - `cost` — `null` when the price table has no entry for
///     `(providerId, modelId)`; never silently zero.
///   - `templateSha` — git sha of the role template that produced
///     the prompt (spec § 6.1). Lets the trail tie a call back to
///     the exact template version.
///   - `notes` — free-form provider-side notes the router may
///     attach (e.g. "response_format downgraded to text"). Carried
///     verbatim into the trail.
final class LlmCallReport {
  final String providerId;
  final String modelId;
  final String anchorHash;
  final String promptHash;
  final int tokensIn;
  final int tokensOut;
  final int retries;
  final int wallClockMs;
  final double? cost;
  final String? templateSha;
  final List<String> notes;

  const LlmCallReport({
    required this.providerId,
    required this.modelId,
    required this.anchorHash,
    required this.promptHash,
    required this.tokensIn,
    required this.tokensOut,
    required this.retries,
    required this.wallClockMs,
    this.cost,
    this.templateSha,
    this.notes = const <String>[],
  });
}
