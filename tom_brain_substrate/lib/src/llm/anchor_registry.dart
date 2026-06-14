// B.23 — `AnchorRegistry`.
//
// Plan-step text (verbatim):
//
//   "B.23 Implement `AssistantDedicationAnchor` injection: every prompt
//    issued by the substrate is wrapped via `tom_brain_shared.anchor.
//    wrap(...)`. There is no path to bypass it."
//
// Substrate-side anchor accounting. Hashes the canonical
// [AssistantDedicationAnchor.text] (lives in `tom_brain_shared`,
// Plan step A.17) into the format the substrate's trail records on
// every LLM call. The shared layer cannot host the hash because A.9
// forbids `package:crypto` at the shared-types layer — the anchor
// constants live there, the hash is computed here via the generic
// `promptSha256` helper (`tom_core_agentic`, which may depend on
// `crypto`).
//
// What this file owns:
//
//   * [AnchorRegistry.currentHash] — `sha256:<lowercase-hex>` of
//     [AssistantDedicationAnchor.text]. Computed once and cached for
//     the process lifetime; the anchor text is a `const String` so
//     the digest is stable across calls and across isolates within
//     a single process.
//   * [AnchorRegistry.currentVersion] — re-export of
//     [AssistantDedicationAnchor.version] so the substrate's trail
//     records the revision number in the same place it records the
//     hash. Pairs with [currentHash]: a recorded version that
//     disagrees with a recorded hash flags an intentional text
//     change that shipped without bumping the version constant.
//   * [AnchorViolation] — typed exception the substrate raises when
//     an outbound report's `anchorHash` does not equal
//     [AnchorRegistry.currentHash]. Spec § 12 calls this a *fatal*
//     event. B.46 will land the conformance test that asserts every
//     emitted report carries [currentHash]; this exception is the
//     surface that test (and any future runtime check at the
//     `TomBrainSubstrate` facade) raises.
//
// What this file deliberately does NOT own:
//
//   * The wrap mechanics. Lives in [AssistantDedicationAnchor.wrap]
//     (Plan step A.17). The registry exposes the *post-wrap* hash;
//     callers that *produce* a wrapped prompt invoke
//     [AssistantDedicationAnchor.wrap] then stamp [currentHash] on
//     the resulting [WirePrompt.anchorHash].
//   * The role-template assembly path. Lives in
//     [RoleTemplate.assemble] (this same B.23 step). The registry
//     is consumed by `assemble`; it does not call back.
//   * The runtime enforcement at the `TomBrainSubstrate` facade
//     (Plan step B.40). The facade's `complete` / `completeStream`
//     methods will read [currentHash] off this registry and assert
//     equality with the returned report's `anchorHash`, throwing
//     [AnchorViolation] on mismatch. The hook lands at B.40; B.23
//     ships the registry + the exception so the hook lands by
//     consumption, not by invention.
//   * The provider-side hashing of `WirePrompt.combined`. Providers
//     (B.14 Ollama, B.15 OpenAI passthrough, B.16 Stub) call the same
//     `promptSha256` helper this registry does, but on a different
//     input and lifecycle — the body hash is per-call and
//     per-provider, the anchor hash is process-wide. Shared helper,
//     different ownership.
//
// Why a static-only class, not a top-level constant or function:
//
//   * The hash is *computed*, not declared — a `const` would require
//     `promptSha256` to be const-evaluable (it is not). The static
//     method gives us lazy initialisation and a single owner.
//   * Mirrors the `AssistantDedicationAnchor` static-only shape so
//     a reader who finds one finds the other.
//   * The class is `final` so a downstream package cannot subclass
//     it and override [currentHash]. The substrate's anchor identity
//     is structural, not configurable.

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show AssistantDedicationAnchor;
import 'package:tom_core_agentic/tom_core_agentic.dart' show promptSha256;

/// Substrate-side accounting for the assistant-dedication anchor.
///
/// Static-only class. Holds the canonical hash of
/// [AssistantDedicationAnchor.text] in the
/// `sha256:<lowercase-hex>` format the trail records on every LLM
/// call. The hash is computed once and cached; subsequent reads
/// return the cached value.
///
/// **Anchor invariant** (Plan step B.23 / Postulate 3 in
/// `_ai/quests/tom_brain/overview.tom_brain.md`):
///
/// 1. Every [WirePrompt] the substrate emits has
///    [WirePrompt.combined] starting with [AssistantDedicationAnchor.text]
///    (enforced structurally: only [RoleTemplate.assemble] produces
///    [WirePrompt]; `assemble` wraps via
///    [AssistantDedicationAnchor.wrap]).
/// 2. Every [WirePrompt] the substrate emits has
///    [WirePrompt.anchorHash] equal to [AnchorRegistry.currentHash]
///    (enforced by `assemble` stamping this constant).
/// 3. Every [LlmCallReport] returned by a provider has
///    [LlmCallReport.anchorHash] equal to the
///    [WirePrompt.anchorHash] of the prompt it consumed (enforced
///    by each provider; B.14 / B.15 / B.16 already comply; B.46
///    conformance suite proves it).
///
/// Invariants (1) + (2) compose at the role layer; invariant (3)
/// composes at the provider layer; B.46 + the runtime hook at B.40
/// compose all three into the structural proof of Postulate 3.
final class AnchorRegistry {
  // Private const constructor: prevents instantiation. Static-only API.
  // Structurally uncoverable by design (no factory calls it).
  const AnchorRegistry._(); // coverage:ignore-line

  /// Cache for [currentHash]. `null` until first read.
  ///
  /// The anchor text is a `const String` and `sha256` is a pure
  /// function over its bytes; the cache exists only to avoid
  /// recomputing the digest on every assemble call. A future test
  /// that wants to verify the digest formula can reset the cache by
  /// reconstructing the static state (currently not exposed — the
  /// computed value is the same on every call because the input is
  /// const).
  static String? _cachedHash;

  /// `sha256:<lowercase-hex>` of [AssistantDedicationAnchor.text].
  ///
  /// The format matches the providers' body hashes (B.14 Ollama,
  /// B.15 OpenAI passthrough, B.16 Stub) — all compute through the
  /// same `promptSha256` helper — so a trail reader does
  /// not have to switch parsers between the prompt hash and the
  /// anchor hash. The two hashes carry different semantics — the
  /// prompt hash is per-call body fingerprint; the anchor hash is
  /// the process-wide proof that the anchor was present — but
  /// share one wire shape.
  ///
  /// First call computes the digest; subsequent calls return the
  /// cached value. Thread-safe in the single-isolate sense Dart
  /// guarantees (no preemption inside a synchronous block).
  static String get currentHash {
    final cached = _cachedHash;
    if (cached != null) return cached;
    return _cachedHash = promptSha256(AssistantDedicationAnchor.text);
  }

  /// Re-export of [AssistantDedicationAnchor.version].
  ///
  /// Carried here so the substrate has a single accounting surface
  /// for anchor identity — hash + version side by side. A trail
  /// reader compares the recorded version against the recorded hash;
  /// a disagreement (recorded version `N` but recorded hash `H` ≠
  /// the hash of revision-`N` text) flags an unannotated text
  /// change.
  static int get currentVersion => AssistantDedicationAnchor.version;

  /// True if [candidate] equals [currentHash].
  ///
  /// Convenience predicate for the B.40 runtime hook and the B.46
  /// conformance test. Equivalent to `candidate == currentHash`;
  /// kept as a named method so the call sites read declaratively
  /// ("does this report carry the current anchor?") rather than as
  /// an opaque string equality.
  static bool isCurrent(String candidate) => candidate == currentHash;
}

/// Raised when an outbound report's anchor hash does not equal
/// [AnchorRegistry.currentHash].
///
/// Spec § 12 calls this a **fatal** substrate event: the trail
/// records the report regardless (so the violation is auditable),
/// but no consumer ever sees the response — the substrate fails
/// the call.
///
/// The exception carries enough context for the trail / observability
/// layer to diagnose without re-reading the report:
///
///   * [expected]  — `AnchorRegistry.currentHash` at the moment the
///                   check ran.
///   * [actual]    — the report's `anchorHash` that did not match.
///   * [providerId]— the route the report came from (for the
///                   "did this provider drop the hash?" diagnosis).
///   * [modelId]   — the resolved model id.
///   * [roleId]    — the role whose assemble path produced the
///                   prompt; the substrate-side culprit if the
///                   provider hash is right (which would mean
///                   `assemble` stamped a wrong hash).
///
/// Implements [Exception] so generic `try/catch` works; subclasses
/// not anticipated — every anchor mismatch is the same defect
/// shape.
final class AnchorViolation implements Exception {
  /// The hash the substrate expected the report to carry.
  final String expected;

  /// The hash the report actually carried.
  final String actual;

  /// `LlmProvider.id` of the provider that returned the report.
  final String providerId;

  /// Resolved `modelId` stamped on the report.
  final String modelId;

  /// `roleId` of the role whose `assemble` produced the prompt.
  final String roleId;

  const AnchorViolation({
    required this.expected,
    required this.actual,
    required this.providerId,
    required this.modelId,
    required this.roleId,
  });

  @override
  String toString() => 'AnchorViolation('
      'roleId: $roleId, '
      'providerId: $providerId, '
      'modelId: $modelId, '
      'expected: $expected, '
      'actual: $actual)';
}
