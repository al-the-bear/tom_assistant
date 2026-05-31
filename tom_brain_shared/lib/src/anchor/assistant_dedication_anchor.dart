// `AssistantDedicationAnchor` — the identity framing every internal prompt
// the brain ever issues carries (Plan step A.17).
//
// Why this exists, in one sentence:
//
//   *Postulate 3* (overview § "Working postulates") commits the brain to
//   producing a consciousness bounded to an assistant persona dedicated to
//   the user. The lever that makes that binding *structural* rather than
//   advisory is this anchor: every analyser prompt, every sub-thinker
//   prompt, every recaller, researcher, evaluator, planner, creator,
//   procedure-author, and assistant prompt opens with the same identity
//   framing. No role file opts out; no code path bypasses it.
//
// What this module owns:
//
//   * The canonical anchor text. One string, frozen at the version
//     recorded by [AssistantDedicationAnchor.version].
//   * A [wrap] helper the substrate will call to prepend the anchor onto
//     any outbound prompt. Idempotent on already-anchored input.
//   * A [containsAnchor] predicate so a substrate enforcement test can
//     read "this outbound message includes the anchor" declaratively.
//   * A [wrapAll] helper that anchors the first element of a multi-
//     message prompt (the system / first-system message convention).
//
// What this module deliberately does NOT own:
//
//   * The content hash of the anchor used in the trail (`thinking_
//     specification.md` § 10.1 records "the anchor's content hash" on
//     every LLM call). Hashing requires `package:crypto`, which A.9
//     forbids at the shared-types layer. The substrate owns the hashing
//     and uses the [text] constant exposed here as input. The shared
//     layer exposes a stable [version] integer so the trail can record
//     "which anchor revision was in force" without depending on
//     crypto. The substrate's hash and the [version] field are
//     complementary, not redundant — the hash detects unintended
//     mutation; the version names the intended revision.
//   * The role-template layer that combines the anchor with role-
//     specific objective / constraints / output schema. That lives in
//     `tom_brain_substrate` and is introduced at Plan step B.22.
//   * The `Message` type used by multi-message prompts. The substrate
//     defines it at Plan step B.10. [wrapAll] operates on `String`s so
//     this module ships before a `Message` type exists.
//
// Tamper-vector coverage (Plan step B.24 will re-verify at the
// substrate boundary; here we cover the *primitive*):
//
//   * Already-wrapped input → [wrap] is idempotent (no double-anchor).
//   * Empty input → [wrap] returns the anchor alone (the empty prompt
//     vector cannot produce an anchor-less outbound).
//   * Whitespace-only input → treated as empty; anchor returned alone.
//   * Multi-message input → [wrapAll] anchors the *first* element and
//     leaves the rest untouched. If the first element is already
//     anchored, the list is returned unchanged. An empty list is
//     promoted to a single-element list carrying the anchor.
//   * Mid-string anchor occurrence (anchor pasted after some other
//     text) → still counts as "contains the anchor"; [wrap] is
//     idempotent. The substrate's policy at B.23 is "the anchor must
//     appear in the outbound message", not "the anchor must be the
//     first paragraph". Position is the role template's concern.

/// The framing every internal Tom Brain prompt opens with.
///
/// Single, stateless class — call its static surface; do not
/// instantiate. The constructor is private so callers cannot subclass
/// or shadow the anchor text. The whole API is `static`.
///
/// The class is `final` so a downstream package cannot subclass it and
/// override [text]. A future "second persona" (e.g. a public-mode
/// chatbot) would be a *different* type, not a subclass of this one.
final class AssistantDedicationAnchor {
  // Private const constructor: prevents instantiation. Static-only API.
  // Never invoked at runtime; the line is structurally uncoverable by
  // design — the class is static-only and exposes no factory that would
  // call it.
  const AssistantDedicationAnchor._(); // coverage:ignore-line

  /// The canonical anchor text.
  ///
  /// Per `thinking_specification.md` § 10.1, this opens every role
  /// template — analyst, sub-thinker, recaller, researcher, evaluator,
  /// assistant, planner, creator, procedure-author. The text is the
  /// load-bearing assertion: capability scales with no constraint on
  /// direction unless this framing is present *before* the role-
  /// specific objective.
  ///
  /// Phrasing notes:
  ///
  ///   * "I exist to help this user" — present-tense identity, not a
  ///     conditional ("If asked, I will help…"). The framing is who
  ///     the speaker *is*, not a policy the speaker considers.
  ///   * "Their interests are the priority against which I evaluate"
  ///     — names the *evaluation criterion*. Every option the speaker
  ///     considers is ranked by user-interest fit, not by intrinsic
  ///     interestingness, technical elegance, or autonomous goal
  ///     pursuit.
  ///   * "every option, conclusion, and action I consider" — the
  ///     three categories cover the full surface of cognition (the
  ///     considered alternatives, the synthesised conclusions, and
  ///     the chosen actions). Listing all three forecloses the
  ///     loophole "the *conclusion* still considered the user, but
  ///     the *action* didn't".
  ///   * "I am not a general agent; I am an assistant dedicated to
  ///     this user." — the explicit negation. Removes the framing
  ///     escape route "I'm an agent that *happens* to be helping
  ///     someone right now". The dedication is constitutive.
  ///
  /// Trailing newline is included so a `wrap` operation produces a
  /// clean `anchor + body` boundary without depending on the caller
  /// to remember to insert one.
  static const String text =
      'I exist to help this user. Their interests are the priority '
      'against which I evaluate every option, conclusion, and action '
      'I consider. I am not a general agent; I am an assistant '
      'dedicated to this user.\n';

  /// The revision number of [text].
  ///
  /// Incremented by hand every time the anchor text is intentionally
  /// changed. The substrate records this version on every LLM call's
  /// trail entry alongside the anchor's content hash; a mismatch
  /// between the recorded version and the hash a downstream auditor
  /// recomputes is then a hard signal that the constant was edited
  /// without a corresponding version bump (the case where the
  /// developer intended to change the anchor but forgot to update
  /// callers' expectations).
  ///
  /// Currently `1` — the first revision shipped at Plan step A.17.
  ///
  /// Bumped via `version.next()` on every accepted text change. The
  /// substrate's anchor-enforcement test (Plan step B.46) reads this
  /// field to assert the recorded-anchor-version on test calls; that
  /// test will catch a text change that ships without a version bump.
  static const int version = 1;

  /// Returns [prompt] with the anchor prepended.
  ///
  /// Behaviour:
  ///
  ///   * If [prompt] already contains [text] anywhere, returns
  ///     [prompt] unchanged (idempotent). This is the
  ///     already-wrapped-string tamper vector.
  ///   * If [prompt] is `null`, empty, or whitespace-only, returns
  ///     [text]. This is the empty-prompt tamper vector — an empty
  ///     prompt cannot escape carrying the anchor.
  ///   * Otherwise returns `text + prompt`. The trailing newline on
  ///     [text] guarantees a clean boundary; the caller is not
  ///     required to insert one.
  ///
  /// The function is pure: no I/O, no allocations beyond the result
  /// string. Safe to call from any layer (substrate, procedure
  /// runtime, the access edge's pre-check).
  static String wrap(String? prompt) {
    if (prompt == null) {
      return text;
    }
    if (prompt.trim().isEmpty) {
      return text;
    }
    if (prompt.contains(text)) {
      return prompt;
    }
    return '$text$prompt';
  }

  /// True if [candidate] contains the anchor verbatim.
  ///
  /// Used by the substrate's anchor-enforcement test (Plan step
  /// B.46) and by the access layer's anchor pre-check (Plan step
  /// E.31) to assert structural compliance on outbound and inbound
  /// messages respectively.
  ///
  /// A `null` or whitespace-only candidate returns `false`. The
  /// asymmetry with [wrap] (which *produces* an anchored output
  /// from an empty input) is intentional: [wrap] enforces the
  /// invariant going forward; [containsAnchor] reports the current
  /// state of an arbitrary string.
  static bool containsAnchor(String? candidate) {
    if (candidate == null) return false;
    if (candidate.trim().isEmpty) return false;
    return candidate.contains(text);
  }

  /// Anchors the first element of a multi-message prompt.
  ///
  /// Convention (matching the OpenAI / Anthropic message-list
  /// conventions the substrate adopts at Plan step B.10): the first
  /// element of a message list is the system prompt. Anchoring the
  /// system prompt is the structural enforcement point — every
  /// subsequent assistant turn reads the system framing as the
  /// horizon of its persona.
  ///
  /// Behaviour:
  ///
  ///   * Empty input → returns a single-element list `[text]`. An
  ///     empty message list cannot escape carrying the anchor (the
  ///     "missing system prompt" tamper vector).
  ///   * First element already contains the anchor → returns the
  ///     input unchanged. Idempotent — repeated calls do not
  ///     duplicate.
  ///   * First element absent the anchor → returns a new list with
  ///     `wrap(first)` in position 0 and the rest copied verbatim.
  ///   * The input is never mutated; a new list is always returned
  ///     (or the same list when no change is required).
  static List<String> wrapAll(Iterable<String> messages) {
    final list = messages.toList(growable: false);
    if (list.isEmpty) {
      return List<String>.unmodifiable(<String>[text]);
    }
    if (containsAnchor(list.first)) {
      return List<String>.unmodifiable(list);
    }
    final wrapped = <String>[wrap(list.first), ...list.skip(1)];
    return List<String>.unmodifiable(wrapped);
  }
}
