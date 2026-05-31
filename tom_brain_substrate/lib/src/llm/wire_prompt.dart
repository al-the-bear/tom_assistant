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
/// **Anchor invariant.** Every `WirePrompt` is the output of
/// `tom_brain_shared.anchor.wrap(roleTemplateBody)`:
///   - [body] begins with the anchor block followed by the
///     role-assembled body.
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
  /// The fully assembled prompt text, anchor-first.
  ///
  /// Guaranteed shape (by `RoleTemplate.assemble`):
  ///
  /// ```
  /// <anchor block (constant from tom_brain_shared)>
  ///
  /// <role-assembled body (persona + objective + template + inputs)>
  /// ```
  ///
  /// Providers send this string as the user/system message to their
  /// backend. The substrate does not split it back into anchor /
  /// body components for the wire format — the model sees one
  /// coherent prompt whose first paragraph is the anchor.
  final String body;

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
    required this.body,
    required this.anchorHash,
    required this.roleId,
    this.templateSha,
  });
}
