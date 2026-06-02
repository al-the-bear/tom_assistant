// E.31 — The anchor pre-check at the edge.
//
// The plan line for E.31 reads "Implement the anchor pre-check: a
// configurable list of disallowed prompt-fragment signatures (e.g., obvious
// prompt-injection patterns). Pre-check happens before the prompt ever
// reaches the dispatcher." This is the fourth and last of the four
// edge-security checks (proto spec § 8; AC-3). Like every edge check it runs
// *before* an `Access` is constructed: a prompt that trips a disallowed
// signature is refused at the edge and never becomes an `Access`. On the
// OpenAI channel a failure surfaces as a `400` JSON envelope
// ([anchorPreCheckHttpStatus]); on Telegram it surfaces as the graceful
// "cannot process" message ([telegramAnchorMessage]).
//
// Position in the edge chain (proto spec § 7.1 / § 8.0):
//
//     bearer auth / whitelist → rate-limit → quota → anchor pre-check
//
// The anchor pre-check runs *last* — after the credential is validated
// (E.28 / E.22) and the principal has cleared both the short-horizon burst
// throttle (E.29) and the long-horizon daily quota (E.30). By that point the
// request is otherwise admissible; the only remaining gate is the *content*
// screen. Putting it last means a rejected/throttled principal never even has
// its prompt content inspected, and the cheaper identity/rate checks shed load
// before the content scan.
//
// Why this is a *safety lever*, not a rate limit. The anchor pre-check is the
// access-side half of the assistant-dedication safety lever (Postulate 3;
// def § 14.5; thinking spec § 10). The substrate-side half — anchor
// *injection* of the assistant-dedication framing into every emitted prompt
// (substrate invariant 1, B.46) — is the second, structural half; together the
// two close the lever. The pre-check's job is to refuse, at the very edge,
// inbound prompts whose obvious intent is to subvert that framing (classic
// prompt-injection signatures such as "ignore previous instructions" /
// "disregard your system prompt"). E.56 proves no inbound prompt reaches the
// dispatcher without passing this pre-check.
//
// Unlike the rate limiter (E.29) and the quota (E.30), the anchor pre-check is
// *stateless and content-keyed*, not principal-keyed: it screens the prompt
// *text*, not the identity behind it. There is therefore no per-principal map,
// no clock, and no notion of "spending" — the same prompt always yields the
// same verdict. Identity is irrelevant to the decision (a disallowed fragment
// is disallowed regardless of who sent it), so [check] takes only the prompt
// text. The boot/observability layer that catches the rejection is free to
// associate the principal with the `access.anchor.precheck.rejected` event
// (proto spec § 13.1); that association is the adapter's concern, not this
// component's — the same channel-blind discipline E.28 – E.30 follow.
//
// Matching — case-insensitive substring. A signature matches when it appears,
// case-insensitively, anywhere in the prompt text. Prompt-injection phrasings
// vary in case ("Ignore Previous Instructions", "IGNORE previous…") so a
// case-folded substring scan is the robust prototype choice; it has no false
// negatives from casing and is cheap (a single lowercase pass over the prompt,
// then a substring test per signature). More sophisticated normalisation
// (whitespace collapse, unicode confusable folding, token-level matching) is a
// final-layer hardening concern (Q-E.31.1), deliberately out of the prototype.
//
// Configuration. The disallowed-signature list comes from the `AccessConfig`
// anchor section ("the anchor pre-check signature list", proto spec § 11.4 /
// § 13.1), loaded at boot (E.41+). The list MAY be empty — an empty list is a
// pre-check that admits every prompt (the screen is disabled), a valid
// configuration (e.g. a deployment that relies solely on the substrate-side
// injection half). An empty *signature string* within the list, however, is a
// misconfiguration: an empty substring matches every prompt and would reject
// all traffic, so it is rejected at construction with a loud `ArgumentError`
// rather than silently bricking the edge.
//
// Scope discipline (per the strict per-substep log; mirrors E.24 – E.30).
// E.31 is the anchor pre-check only. It does NOT:
//
//   * map the rejection onto a shelf `Response` or a Telegram send — the
//     OpenAI adapter / Telegram adapter own the wire shape (E.41+); this file
//     exposes only the typed [AnchorPreCheckRejected], the documented `400`
//     status constant, and the graceful anchor-message constant the adapters
//     read. Channel-blind, exactly like E.28's `BearerAuthFailure`, E.29's
//     `RateLimitExceeded`, E.30's `DailyQuotaExceeded`.
//   * inject the anchor framing into outbound prompts — that is the
//     substrate-side half (B.46), a different package entirely.
//   * authenticate (E.28), rate-limit (E.29), apply the quota (E.30), or
//     resolve identity (E.24).
//   * wire into the adapter route flow or boot (E.41+), or emit the
//     observability event (E.41+ / § 13.1).

/// The graceful message the Telegram adapter (E.41+) sends when a prompt trips
/// the anchor pre-check (proto spec § 8: Telegram failure → graceful message).
/// The request is still dropped — no `Access` is built; this is the
/// user-visible courtesy, not a retry channel. Deliberately neutral and
/// non-specific: it does not name which signature matched (that would hand a
/// probing caller a map of the screen) — it states only that the request
/// cannot be processed.
const String telegramAnchorMessage =
    'Sorry, I cannot process that request.';

/// The HTTP status an [AnchorPreCheckRejected] maps to on the OpenAI channel
/// (proto spec § 8 / § 13.1: anchor pre-check failure → `400`). Unlike the
/// rate-limit / quota failures (`429`, a "come back later" signal) an anchor
/// rejection is a *bad request* — the prompt is structurally disallowed and
/// retrying it unchanged will never succeed — so it maps to `400`, not `429`.
const int anchorPreCheckHttpStatus = 400;

/// Immutable configuration of the anchor pre-check.
///
/// Holds the list of disallowed prompt-fragment signatures. A prompt is
/// rejected when any signature appears (case-insensitively) anywhere within
/// it. Boot (E.41+) builds one policy from the `AccessConfig` anchor section
/// (proto spec § 11.4). The list may be empty (the pre-check then admits every
/// prompt — a disabled screen); each individual signature must be non-empty
/// (an empty substring would match everything and reject all traffic).
final class AnchorPolicy {
  /// The disallowed signatures exactly as configured (order and casing
  /// preserved — this is what an operator reads back). May be empty.
  final List<String> disallowedSignatures;

  /// The signatures pre-folded to lower case once at construction, so [check]
  /// does not re-lowercase the configured list on every request (only the
  /// inbound prompt is lowercased per call). Parallel to [disallowedSignatures].
  final List<String> _foldedSignatures;

  AnchorPolicy._(this.disallowedSignatures, this._foldedSignatures);

  /// Builds a policy over [disallowedSignatures].
  ///
  /// The list itself may be empty (the pre-check admits everything). Each
  /// signature, however, must be non-empty — an empty signature would match
  /// every prompt and turn the screen into a deny-all, which is a
  /// misconfiguration, not a screen.
  factory AnchorPolicy({required List<String> disallowedSignatures}) {
    for (final signature in disallowedSignatures) {
      if (signature.isEmpty) {
        throw ArgumentError.value(
          disallowedSignatures,
          'disallowedSignatures',
          'signatures must be non-empty (an empty signature matches every '
              'prompt and would reject all traffic)',
        );
      }
    }
    // Defensive copy so a later mutation of the caller's list cannot silently
    // change the screen after construction (the policy is immutable).
    final configured = List<String>.unmodifiable(disallowedSignatures);
    final folded = List<String>.unmodifiable(
      disallowedSignatures.map((s) => s.toLowerCase()),
    );
    return AnchorPolicy._(configured, folded);
  }

  /// Whether the screen is disabled — an empty signature list admits every
  /// prompt.
  bool get isEmpty => disallowedSignatures.isEmpty;
}

/// Raised when a prompt trips the anchor pre-check.
///
/// Carries the [matchedSignature] — the disallowed signature (as configured,
/// original casing) that was found in the prompt. The signature is *config*,
/// not user content, so it is safe to log and surface to the
/// `access.anchor.precheck.rejected` observability event (§ 13.1); the prompt
/// text itself is **not** carried (the screen does not echo the rejected
/// content). On the OpenAI channel the adapter maps this to
/// [anchorPreCheckHttpStatus] (`400`); on Telegram it sends
/// [telegramAnchorMessage]. Either way the prompt never becomes an `Access`
/// (AC-3).
final class AnchorPreCheckRejected implements Exception {
  /// The configured disallowed signature (original casing) that matched the
  /// prompt. Safe to log — it is configuration, never user content or a token.
  final String matchedSignature;

  /// Builds the rejection for the signature that matched.
  const AnchorPreCheckRejected(this.matchedSignature);

  @override
  String toString() =>
      'AnchorPreCheckRejected: prompt matched disallowed signature '
      '"$matchedSignature"';
}

/// The anchor pre-check (E.31).
///
/// A stateless content screen: it owns no per-principal state, no clock, and
/// no I/O. Call [check] once per inbound prompt *after* the identity / rate /
/// quota checks (E.28 – E.30) have admitted the request and *before* the
/// prompt becomes an `Access`. [check] returns normally when no disallowed
/// signature appears in the prompt, or throws [AnchorPreCheckRejected] (naming
/// the matched signature) when one does — mirroring E.28 – E.30's
/// validate-or-throw contract so the edge chain composes uniformly.
final class AnchorPreCheck {
  /// The disallowed-signature configuration this screen applies.
  final AnchorPolicy policy;

  /// Builds a pre-check over [policy].
  const AnchorPreCheck(this.policy);

  /// Screens [promptText] against the disallowed signatures.
  ///
  /// Returns normally if the screen is disabled (empty policy) or no signature
  /// appears in [promptText]; throws [AnchorPreCheckRejected] naming the first
  /// matching signature otherwise. Matching is case-insensitive substring: a
  /// signature matches when it appears, ignoring case, anywhere in the prompt.
  ///
  /// The match is computed by lowercasing [promptText] once and testing each
  /// pre-folded signature; the first match short-circuits (the screen's job is
  /// to refuse, not to enumerate every offending fragment).
  void check(String promptText) {
    if (policy.isEmpty) {
      return;
    }
    final foldedPrompt = promptText.toLowerCase();
    for (var i = 0; i < policy._foldedSignatures.length; i++) {
      if (foldedPrompt.contains(policy._foldedSignatures[i])) {
        // Report the signature with its original configured casing — that is
        // what an operator recognises in the audit log.
        throw AnchorPreCheckRejected(policy.disallowedSignatures[i]);
      }
    }
  }
}
