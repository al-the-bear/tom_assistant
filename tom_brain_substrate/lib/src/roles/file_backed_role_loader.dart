// File-backed role loader — externalizes role *prose* to `roles/*.md`
// (`prompt_configuration.md` §7.1 / §10 / §11, increment 8).
//
// `bootstrapRoleRegistry()` (and the wider live-roster factories such as
// `bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningAndDream()`)
// materialise every role entirely in code. This loader is the on-disk
// counterpart §7.1 calls for: it overlays each role's prose — its persona
// (first-person voice) and its objective — from
// `<rolesDir>/<role>.persona.md` and `<rolesDir>/<role>.objective.md`
// when those files are present, and falls back to the in-code template
// for any role (or any half) whose file is absent or blank. The result
// is an ordinary [RoleRegistry] — the same value the facade (B.41) holds
// — so nothing downstream changes shape.
//
// What the file can and cannot change (the capability-surface decision,
// Q-P2.11.1 carried forward to increment 8):
//
//   The `.persona.md` / `.objective.md` files override **only** the
//   role's *prose* — `personaText` and `objective`. The capability
//   surface — `allowedActions`, `forbiddenActions`, `outputSchema`,
//   `budgetDefaults` — is *always* taken from the in-code template. A
//   markdown file therefore tunes how a role speaks and what it is asked
//   to do, but can never widen what a role is *permitted* to do or relax
//   its output contract. That keeps the security-relevant surface
//   (Postulate 3 / spec § 6.2) authoritative in code, where it is
//   reviewed, rather than editable from a prose file on disk.
//
//   Each prose file is read, trimmed, and — if non-empty — substituted
//   for the corresponding [RoleTemplate] field. A missing file, an
//   unreadable file, or a file that is empty / whitespace-only falls back
//   to the in-code value. Falling back on blank content is required, not
//   incidental: [RoleTemplate] rejects an empty persona / objective at
//   construction, so a blank file must never reach the constructor.
//
// Why the in-code prose is kept (not deleted): the substrate's own unit
// tests build the in-code registries directly (with no `rolesDir`), so
// the in-code prose remains the reviewed structural authority and the
// fallback. The `roles/*.md` files are the *live* prose source the run
// reads; the in-code copy is the fallback the tests and a file-less boot
// rely on. (§11's "moved to roles/*.md" is realised as "sourced from
// roles/*.md when present, in-code is the reviewed fallback".)
//
// Anchor invariant (unchanged): a file-loaded role assembles its prompt
// through the very same `RoleTemplate.assemble` path as an in-code role.
// Every emitted `WirePrompt` therefore still begins with
// `AssistantDedicationAnchor.text` and records `AnchorRegistry.
// currentHash` on `anchorHash`. There is no per-role "skip anchor" branch
// and this loader adds none.

import 'dart:io';

import 'role_registry.dart';
import 'role_template.dart';

/// Overlays the file-backed prose under [rolesDir] onto [base], returning
/// a new [RoleRegistry] with the same roster (same ids, same order).
///
/// For every template in [base] the loader reads
/// `<rolesDir>/<id>.persona.md` and `<rolesDir>/<id>.objective.md`. A
/// present, non-blank file overrides that field; an absent / unreadable /
/// blank file keeps the in-code value. The capability surface
/// (`allowedActions`, `forbiddenActions`, `outputSchema`,
/// `budgetDefaults`) is always carried through from [base] unchanged.
///
/// [rolesDir] need not exist — a missing directory simply yields a
/// registry identical to [base] (every role is a fallback).
RoleRegistry loadFileBackedRoleRegistry({
  required RoleRegistry base,
  required Directory rolesDir,
}) {
  final templates = <RoleTemplate>[];

  for (final template in base.templates) {
    final persona = _readOverride(rolesDir, '${template.id}.persona.md');
    final objective = _readOverride(rolesDir, '${template.id}.objective.md');
    if (persona == null && objective == null) {
      templates.add(template);
    } else {
      templates.add(_withProse(template, persona, objective));
    }
  }

  return RoleRegistry(templates: templates);
}

/// Reads `<rolesDir>/<fileName>` and returns its trimmed content, or
/// `null` when the file is absent, unreadable, or blank.
String? _readOverride(Directory rolesDir, String fileName) {
  final file = File('${rolesDir.path}/$fileName');
  if (!file.existsSync()) return null;
  final String raw;
  try {
    raw = file.readAsStringSync();
  } on FileSystemException {
    // An unreadable file is treated like an absent one: the in-code
    // template is always a valid fallback, so a transient read error
    // never leaves a role un-loadable.
    return null;
  }
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Returns a copy of [base] with [personaText] and/or [objective] replaced
/// by the supplied (already-trimmed, non-blank) overrides; a `null`
/// override keeps the in-code value. Every other attribute — the
/// capability surface — is carried through unchanged.
RoleTemplate _withProse(RoleTemplate base, String? persona, String? objective) {
  return RoleTemplate(
    id: base.id,
    personaText: persona ?? base.personaText,
    objective: objective ?? base.objective,
    allowedActions: base.allowedActions,
    forbiddenActions: base.forbiddenActions,
    outputSchema: base.outputSchema,
    budgetDefaults: base.budgetDefaults,
  );
}
