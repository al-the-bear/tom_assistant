// Plan-2 item 11 — file-backed role loader.
//
// `bootstrapRoleRegistry()` (B.22 / § 6.2b) materialises the six core roles
// entirely in code. This loader is the on-disk counterpart the
// bootstrap-file header has pointed at since B.22: it reads each role's
// voice from `<promptsDir>/<role>.system.md` when present, and falls
// back to the in-code bootstrap template when the file is absent (or
// blank). The result is an ordinary [RoleRegistry] — the same value the
// facade (B.41) holds — so nothing downstream changes shape.
//
// Design decision (Q-P2.11.1 — recorded here because the plan's one-line
// *Test* directive leaves it open):
//
//   The `.system.md` file overrides **only** the role's `personaText`
//   (its first-person voice). The structured policy — `objective`,
//   `allowedActions`, `forbiddenActions`, `outputSchema`,
//   `budgetDefaults` — is *always* taken from the in-code bootstrap
//   template. A markdown file therefore tunes how a role speaks but can
//   never widen what a role is permitted to do, change its declared
//   objective, or relax its output contract. That keeps the capability
//   surface (Postulate 3 / spec § 6.2) authoritative in code, where it
//   is reviewed, rather than editable from a prose file on disk.
//
//   The persona file is read, trimmed, and — if non-empty — substituted
//   for `RoleTemplate.personaText`. A missing file, an unreadable file,
//   or a file that is empty / whitespace-only all fall back to the
//   bootstrap persona. Falling back on blank content is required, not
//   incidental: `RoleTemplate` rejects an empty persona at construction,
//   so a blank file must not reach the constructor.
//
// Anchor invariant (unchanged): a file-loaded role assembles its prompt
// through the very same `RoleTemplate.assemble` path as a bootstrap
// role. Every emitted `WirePrompt` therefore still begins with
// `AssistantDedicationAnchor.text` and records `AnchorRegistry.
// currentHash` on `anchorHash`. There is no per-role "skip anchor"
// branch and this loader adds none.
//
// What this loader deliberately does NOT do at item 11:
//
//   - It does not populate `WirePrompt.templateSha` with a git sha of
//     the source file. The `templateSha` field stays `null` (as it is
//     for bootstrap roles); a content-addressed template ref is a
//     separate concern not required by the item-11 *Test* line.
//   - It does not read a `roles_registry.yaml` to discover *new* roles.
//     The roster is fixed to `prototypeRoleIds`; on-disk files can only
//     re-voice an existing prototype role, not add one.
//   - It does no `${ENV}` expansion or templating on the file body — the
//     persona is taken verbatim (after trimming).

import 'dart:io';

import 'bootstrap_roles.dart';
import 'role_registry.dart';
import 'role_template.dart';

/// Loads the six core roles, preferring an on-disk persona from
/// `<`[promptsDir]`>/<role>.system.md` and falling back to the in-code
/// [bootstrapRoleRegistry] template for any role whose file is absent or
/// blank.
///
/// The returned [RoleRegistry] always contains exactly the
/// [prototypeRoleIds] roster, in canonical order. Only `personaText` is
/// ever sourced from disk; every other [RoleTemplate] attribute is the
/// bootstrap authority (see the file header for the rationale).
///
/// [promptsDir] need not exist — a missing directory simply yields the
/// full bootstrap roster (every role is a fallback).
RoleRegistry loadFileBackedRoleRegistry({required Directory promptsDir}) {
  final bootstrap = bootstrapRoleRegistry();
  final templates = <RoleTemplate>[];

  for (final base in bootstrap.templates) {
    final override = _readPersonaOverride(promptsDir, base.id);
    if (override == null) {
      templates.add(base);
    } else {
      templates.add(_withPersona(base, override));
    }
  }

  return RoleRegistry(templates: templates);
}

/// Reads `<promptsDir>/<roleId>.system.md` and returns its trimmed
/// content, or `null` when the file is absent, unreadable, or blank.
String? _readPersonaOverride(Directory promptsDir, String roleId) {
  final file = File('${promptsDir.path}/$roleId.system.md');
  if (!file.existsSync()) return null;
  final String raw;
  try {
    raw = file.readAsStringSync();
  } on FileSystemException {
    // An unreadable file is treated like an absent one: the in-code
    // bootstrap is always a valid fallback, so a transient read error
    // never leaves a role un-loadable.
    return null;
  }
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Returns a copy of [base] with [personaText] replaced; every other
/// attribute is carried through unchanged.
RoleTemplate _withPersona(RoleTemplate base, String personaText) {
  return RoleTemplate(
    id: base.id,
    personaText: personaText,
    objective: base.objective,
    allowedActions: base.allowedActions,
    forbiddenActions: base.forbiddenActions,
    outputSchema: base.outputSchema,
    budgetDefaults: base.budgetDefaults,
  );
}
