// LayeredPromptResolver — a profile template overlay over the base prompt
// registry (`session_configuration.md` § 3.5; plan step 8 (b); SCP-32).
//
// A profile may name a `templateOverlay`: a `<cognition.root>/overlays/<name>/`
// directory whose prompt files shadow the base registry for that profile's
// runs, while every id the overlay does *not* define falls through to base.
// The engine binds one of these per run when `Access.profile.templateOverlay`
// is set, composing the base [PromptResolver] with an overlay [PromptResolver]
// the host builds from the overlay directory.
//
// ── Why a thin compose, not a merged registry ───────────────────────
//
// Both layers are live, file-reading [PromptResolver]s (the base reads the
// registry; the overlay reads the overlay dir). Composing them at resolve time
// — overlay first, base on a `null` — preserves each layer's live re-read: an
// edit to either an overlay file or a base file is picked up on the next
// resolve with no rebuild (the per-prompt-tracing AUTH-5 / live-edit guarantee
// the base resolver already gives, extended to the overlay). A missing overlay
// id is the overlay resolver returning `null`, which is exactly the
// fall-through signal — so "shadow when present, base otherwise" is the whole
// rule, and an id absent from *both* layers stays `null` (the §7.3
// unregistered-prompt-is-fatal contract is untouched).

import 'substrate_run_seams.dart' show ResolvedPrompt;
import 'substrate_bridge.dart' show PromptResolver;

/// Resolves a prompt id against an [overlay] resolver first, falling through to
/// [base] when the overlay does not define it.
final class LayeredPromptResolver {
  /// The base prompt registry resolver (the cognition's configured prompts).
  final PromptResolver base;

  /// The profile's template-overlay resolver — shadows [base] for the ids it
  /// defines, returns `null` for the ids it does not (the fall-through signal).
  final PromptResolver overlay;

  /// Composes [overlay] over [base].
  const LayeredPromptResolver({required this.base, required this.overlay});

  /// Resolves [promptId]: the overlay's prompt when it defines one, else the
  /// base's. `null` only when *neither* layer defines the id (still fatal at
  /// the call site, §7.3).
  Future<ResolvedPrompt?> resolve(
    String promptId,
    Map<String, Object?> inputs,
  ) async =>
      (await overlay(promptId, inputs)) ?? (await base(promptId, inputs));

  /// The composed lookup as a plain [PromptResolver], for binding onto the
  /// per-run `SubstrateBridge` (which takes the typedef, not this class).
  PromptResolver get asResolver => resolve;
}
