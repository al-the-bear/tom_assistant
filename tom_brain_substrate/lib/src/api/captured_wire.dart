// `CapturedWirePrompt` — the api/-layer provenance DTO for the wire
// body a provider actually saw (`tom_brain_logging.md` §5.2 / §10 step #4).
//
// Why this type exists at all:
//
//   The raw LLM trail (`llm/<role>/…raw.json`, §5.2) needs the **full
//   wire body** — the anchor scaffold the provider received — to write
//   its `wire` block. That body lives only as a local `WirePrompt`
//   inside the facade's `_driveCompleteStream`; no event carried it
//   (the logging-spec "gap #3").
//
//   `WirePrompt` itself stays confined to `lib/src/llm/` (see the api/
//   barrel's "what this does NOT export" note): it is the
//   post-role-assembly provider shape, and exposing a constructible
//   `WirePrompt` on the consumer surface would let a consumer hand the
//   provider a body that never went through the role registry / anchor
//   injection. The role-registry chokepoint is a hard substrate
//   invariant, so the wire body crosses to consumers as this
//   **data-only** mirror instead: it carries the provenance a trail
//   writer needs (body + anchorHash + roleId + templateSha) and nothing
//   that lets a consumer reconstruct a wire and bypass assembly.
//
// One source of truth: the facade builds this from the very `WirePrompt`
// the provider saw, so its `anchorHash` / `templateSha` equal the
// matching fields on the terminal `LlmCallReport` (anchor invariant).
final class CapturedWirePrompt {
  /// The assembled wire body — the anchor scaffold string the provider
  /// received. This is the §5.2 `wire` payload, serialised verbatim by
  /// the trail writer; it is **not** re-rendered downstream.
  final String body;

  /// SHA of the dedication anchor block embedded in [body]. Equals the
  /// `anchorHash` of the call's terminal `LlmCallReport`.
  final String anchorHash;

  /// The role the wire was assembled for (e.g. `assistant_to_user`).
  /// Drives the §5.2 `llm/<role>/…` path segment.
  final String roleId;

  /// SHA of the role template that produced [body], when the role
  /// carried one. `null` for roles assembled without a template.
  final String? templateSha;

  const CapturedWirePrompt({
    required this.body,
    required this.anchorHash,
    required this.roleId,
    this.templateSha,
  });
}
