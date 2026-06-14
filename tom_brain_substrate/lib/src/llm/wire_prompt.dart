// B.11 — `WirePrompt`.
//
// `substrate_specification.md` § 4.1 + § 6.3:
//
//   - `LlmCall` (api/) is the *consumer-facing* intent: roleId +
//     inputs + options + budget + cancellation. It does NOT carry a
//     pre-assembled prompt.
//   - `WirePrompt` is the *post-role-assembly, post-anchor-injection*
//     prompt that providers actually see. The role registry
//     (B.21+) is the only producer of `WirePrompt` values; providers
//     are the only consumers.
//
// The split is the structural enforcement of the assistant-dedication
// anchor (Postulate 3 / spec § 6.3): there is no public way for a
// consumer to hand a provider a raw string, because the only
// provider-facing input type is `WirePrompt` and the only constructor
// runs through `RoleTemplate.assemble(...)`, which calls
// `tom_brain_shared.anchor.wrap(...)` unconditionally.
//
// Why this lives under `lib/src/llm/` and not `lib/src/api/`:
//
//   - The api/ surface (B.9) is what consumers import. Exposing
//     `WirePrompt` there would invite consumers to construct one
//     directly and bypass the role registry — exactly the bypass
//     this type is designed to prevent.
//   - Providers (B.14+ `OllamaLlmProvider`, B.15
//     `OpenAiPassthroughProvider`, B.16 `StubLlmProvider`) consume
//     `WirePrompt`. The router (B.18+) hands them to providers. The
//     role registry (B.21+) is the only producer.
//   - Keeping `WirePrompt` strictly inside `lib/src/llm/` means the
//     api/ barrel and the llm/ barrel are independently auditable:
//     a `package:tom_brain_substrate/tom_brain_substrate.dart` import
//     gets the api/ surface, and only deliberate downstream-of-router
//     code reaches into the provider-layer types.
//
// What this file deliberately does NOT own:
//
//   - The anchor wrapping mechanics. Lives in
//     `tom_brain_shared/lib/anchor/assistant_dedication.dart`. This
//     file only carries the *result* of having been wrapped: a string
//     that begins with the anchor block and the registry hash that
//     proves it.
//   - The role template type. Lives at `lib/src/roles/` (B.21+).
//     This file does not import roles — provider code does not need
//     to know which role produced the prompt; it needs only the
//     wire-level vocabulary (body text + anchor hash + provenance).
//   - The provider abstraction. Lives in `llm_provider.dart`
//     (this same B.11 step) — kept in a separate file so a future
//     refactor of either side does not churn the other.

/// The post-assembly, post-anchor-injection prompt a provider sees.
///
/// Only the role registry (`lib/src/roles/`, B.21+) constructs
/// `WirePrompt` values. The router (`lib/src/router/`, B.18+) hands
/// them to providers. Providers (`OllamaLlmProvider`,
/// `OpenAiPassthroughProvider`, `StubLlmProvider`; B.14–B.16) are
/// the only consumers — they translate `WirePrompt` into whatever
/// shape their backend expects (Ollama `/api/chat` JSON, OpenAI
/// `/v1/chat/completions` JSON, the stub's deterministic echo).
///
/// The class is `final` (no subclassing) because every provider
/// must consume the same shape and a subtype here would invite
/// per-provider variants that bypass the anchor guarantee.
///
/// **Two channels.** A `WirePrompt` carries the prompt as two separate
/// parts so providers can route each to its native channel (a top-level
/// `system` field on Anthropic, a `system`-role message on OpenAI /
/// Ollama; the Stub concatenates):
///   - [system] — the standing framing: the assistant-dedication anchor,
///     the role persona / objective, the structured-output declaration.
///     This is the part the model treats as instructions.
///   - [user] — the call-specific content (the inputs the caller injected
///     for this one prompt). May be empty for system-only roles.
///
/// The native-channel mapping is the provider's responsibility; a
/// provider that has no channel separation reads [combined].
///
/// **Anchor invariant.** Every `WirePrompt` is the output of
/// `RoleTemplate.assemble`, which runs the assembled system text through
/// `AssistantDedicationAnchor.ensurePrefix(...)`:
///   - [system] BEGINS with the anchor block. The anchor leads the
///     *system* channel — the part the model reads as instructions — so
///     the dedication framing is the first thing every backend sees,
///     regardless of how [user] is delivered.
///   - [anchorHash] is the content hash of the anchor block, used
///     by the router/provider to stamp `LlmCallReport.anchorHash`
///     so the conformance test (B.46) can prove the anchor was
///     present on every emitted prompt.
///
/// Constructing a `WirePrompt` outside the role registry is allowed
/// at the type level (Dart has no friend access) but every
/// construction path that ships in the substrate goes through the
/// registry. The B.46 conformance test asserts the anchor hash on
/// every emitted report and fails the build if a path produced a
/// prompt without it.
final class WirePrompt {
  /// The standing framing channel, anchor-first.
  ///
  /// Guaranteed shape (by `RoleTemplate.assemble`):
  ///
  /// ```
  /// <anchor block (constant from tom_brain_shared)>
  ///
  /// <role-assembled framing (persona + objective + output schema)>
  /// ```
  ///
  /// A provider routes this to its native system channel (Anthropic
  /// top-level `system`, OpenAI / Ollama `system`-role message). The
  /// first paragraph is always the assistant-dedication anchor.
  final String system;

  /// The call-specific content channel — the inputs the caller injected
  /// for this prompt.
  ///
  /// Empty (the default) for system-only roles that carry no per-call
  /// user text. A provider routes this to its native user channel; a
  /// provider with no channel separation appends it after [system] (see
  /// [combined]).
  final String user;

  /// Content hash of the anchor block that was prepended.
  ///
  /// Equals `tom_brain_shared.AnchorRegistry.currentHash` for every
  /// prompt the registry produced. The router records this on
  /// `LlmCallReport.anchorHash`; the B.46 conformance test asserts
  /// equality on every emitted report. A mismatch is
  /// `AnchorViolation` (spec § 12) — a fatal substrate event, not
  /// a recoverable error.
  final String anchorHash;

  /// The role id whose template produced this prompt.
  ///
  /// Carried for observability only. Providers do not branch on
  /// `roleId`; the router does not branch on `roleId` past selecting
  /// the route chain at submission. The trail records it so an
  /// audit can correlate a wire prompt with the role that emitted
  /// it without reading the prompt body.
  final String roleId;

  /// Git sha of the role template file that assembled the body.
  ///
  /// `null` when the substrate cannot resolve a sha (e.g. running
  /// against an unstaged template during development). The router
  /// records this on `LlmCallReport.templateSha`; a `null` here
  /// becomes a `null` there, never silently zeroed or "unknown".
  final String? templateSha;

  const WirePrompt({
    required this.system,
    this.user = '',
    required this.anchorHash,
    required this.roleId,
    this.templateSha,
  });

  /// The two channels joined into one string, with a blank line between
  /// them and empty parts dropped.
  ///
  /// This is what a provider sends when it has no native channel
  /// separation — permanently the Stub provider, and transitionally any
  /// provider until its native-channel mapping lands. Because [system]
  /// leads (and begins with the anchor), `combined` always begins with
  /// the anchor too.
  String get combined {
    if (user.isEmpty) return system;
    if (system.isEmpty) return user;
    return '$system\n\n$user';
  }
}
