// Prompt-restructuring plan step 6 (Phase 3) — the shared role-preamble
// *system scaffold*, externalised from the string concatenation the
// (now-removed) `_composeBody` / the interim in-code `_composeSystem` used.
//
// `prompt_configuration.md` § 13.1 ("Every prompt is a registered system +
// user template pair") calls for the role-preamble scaffolding — the
// `PERSONA:` / `OBJECTIVE:` / `OUTPUT SCHEMA:` framing — to live "as literal
// text inside the `.system.md` template", injection-driven, not hardcoded in
// Dart. This file is that scaffold for Phase 3: a single shared,
// placeholder-bearing template plus a renderer that resolves it through the
// one shared `PlaceholderResolver` (`tom_core_agentic`).
//
// Two deliberate deviations from the spec's § 13.1 literal block, recorded in
// `prompt_restructuring_and_configuration_decisions.md` (D6.x) and reflected
// back into § 13.1:
//
//   1. **One shared scaffold, not per-prompt.** The framing is identical for
//      every role; only the injected values (persona / objective / output
//      schema) vary. A single shared template is the DRY realisation; the
//      per-prompt `.system.md` files (Phase 4 / steps 8–9) reference this same
//      framing rather than each re-authoring it.
//
//   2. **Whitespace adjacency around the optional slots.** The spec's block
//      writes a blank line after `${role.anchor}` and before
//      `${output_schema?}`. But the anchor constant already ends in a newline
//      and the output-schema section already carries its own leading
//      separator, so the spec's literal blank lines would produce a
//      triple-newline artifact after the anchor and a trailing blank line when
//      no schema is present. Placing `${role.anchor}` adjacent to `PERSONA:`
//      and `${output_schema?}` adjacent to `${objective}` keeps the assembled
//      bytes identical to the prior in-code render, so every prompt-hash and
//      golden-wire assertion across the conformance suite stays byte-stable
//      (the wire-text-preservation intent of step 9).
//
// **The anchor is injected, never authored (spec § 13.1).** The template
// *begins with* `${role.anchor}` so an operator editing the scaffold can see
// where the dedication anchor lands. That placeholder is a courtesy, not the
// guarantee: `RoleTemplate.assemble` runs the rendered scaffold through
// `AssistantDedicationAnchor.ensurePrefix`, which is idempotent — if the
// placeholder is present the prefix is already there and `ensurePrefix` is a
// no-op; if an author deletes `${role.anchor}`, `ensurePrefix` re-prepends it.
// Either way the system channel begins with the anchor (Postulate 3). The
// anchor cannot be defeated by editing the template.

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show AssistantDedicationAnchor;
import 'package:tom_core_agentic/tom_core_agentic.dart'
    show PlaceholderResolver, PlaceholderStack;

/// The shared system-channel scaffold every role's framing is rendered from.
///
/// A namespace, not an instantiable type: the scaffold is one shared template
/// plus a pure render function. There is no per-role state — the per-role
/// variation (persona / objective / output schema) is passed to [render].
abstract final class SystemScaffold {
  /// The placeholder-bearing scaffold template.
  ///
  /// Literal `${…}` tokens (not Dart interpolation — the `$` is escaped) the
  /// [PlaceholderResolver] expands:
  ///
  ///   - `${role.anchor}` — the assistant-dedication anchor (§6 built-in),
  ///     bound to [AssistantDedicationAnchor.text]. Adjacent to `PERSONA:`
  ///     because the anchor constant ends in a newline (see the file header,
  ///     deviation 2).
  ///   - `${persona}` / `${objective}` — the role's prose, bound by [render].
  ///   - `${output_schema?}` — the optional structured-output section. The
  ///     `?` makes the slot *vanish* when [render] is called without a schema
  ///     section, so a free-text role gets no `OUTPUT SCHEMA:` block and no
  ///     trailing whitespace.
  ///
  /// The author can edit every label and blank line here; only the injected
  /// values flow in through the placeholders.
  static const String template = '\${role.anchor}'
      'PERSONA:\n'
      '\${persona}\n'
      '\n'
      'OBJECTIVE:\n'
      '\${objective}'
      '\${output_schema?}';

  /// Renders [template] with the role's [persona] and [objective], and the
  /// optional [outputSchemaSection].
  ///
  /// [outputSchemaSection] is the *fully composed* output-schema block
  /// (including its own leading `\n\n` separator and the `OUTPUT SCHEMA:`
  /// header), or the empty string for a free-text role. When empty the
  /// `${output_schema?}` slot is left unbound, so the optional form resolves
  /// it to the empty string and the block vanishes.
  ///
  /// The returned text is the system channel *before* the anchor guarantee —
  /// `RoleTemplate.assemble` still runs it through
  /// [AssistantDedicationAnchor.ensurePrefix] (idempotent here, since the
  /// rendered text already leads with the anchor via `${role.anchor}`).
  static String render({
    required String persona,
    required String objective,
    String outputSchemaSection = '',
  }) {
    final stack = PlaceholderStack()
      ..bind('role.anchor', AssistantDedicationAnchor.text)
      ..bind('persona', persona)
      ..bind('objective', objective);
    if (outputSchemaSection.isNotEmpty) {
      stack.bind('output_schema', outputSchemaSection);
    }
    final resolver = PlaceholderResolver(stack: stack, strict: true);
    return resolver.resolveSync(template);
  }
}
