// ReloadingRoleRegistry — a refreshable holder around a [RoleRegistry] that
// lets an operator edit a role's prose files (`<role>.persona.md` /
// `<role>.objective.md`) and have the next LLM call pick them up without a
// restart (`prompt_tracing.md` § 6.3, AUTH-5 — the brain pulls source on
// re-read; nothing pushes into it).
//
// Role prose is the one externalized prompt-construction file the substrate
// otherwise freezes: `loadFileBackedRoleRegistry` overlays it onto the in-code
// roster *once* at boot, and the resulting [RoleRegistry] is immutable. (The
// cognition prompt *template body* already reloads — `buildPromptResolver`
// re-reads the template file on every `sub.run`.) This holder closes that gap
// for prose while keeping [RoleRegistry] itself an immutable value: it never
// mutates a registry, it swaps the *current* overlay for a freshly-built one
// when the prose files' cheap signature (path + mtime + size per
// persona/objective file) changes.
//
// Within-call purity: a call asks for [current], gets one fixed [RoleRegistry]
// snapshot, and assembles its whole prompt from it. The roster (ids + order) is
// invariant across reloads — only the prose of existing roles changes — so a
// reload can never add, drop, or reorder a role, and the capability surface
// (allowed/forbidden actions, output schema, budgets) stays the in-code
// authority `loadFileBackedRoleRegistry` carries through.
//
// Two shapes, mirroring `ProcedureResolverHandle`:
//   - [ReloadingRoleRegistry.fixed] — no rolesDir, [current] always returns the
//     wrapped registry. The default for tests and any deployment without a
//     cognition roles directory.
//   - [ReloadingRoleRegistry.reloading] — backed by an in-code [base] roster and
//     a `rolesDir`; built (and fingerprinted) up front so a no-change [current]
//     is a true no-op, and rebuilt only when the signature changes.

import 'dart:io';

import 'file_backed_role_loader.dart';
import 'role_registry.dart';

/// Holds the substrate's *current* prose-overlaid [RoleRegistry] and, when
/// backed by a `rolesDir`, rebuilds it on demand when the prose files change.
final class ReloadingRoleRegistry {
  RoleRegistry _current;

  /// The in-code roster the overlay is rebuilt from. Equal to [_current] for a
  /// [fixed] holder. Kept (rather than re-deriving from the overlay) so a
  /// *deleted* prose file correctly reverts that half to the in-code value.
  final RoleRegistry _base;

  /// The directory holding `<role>.persona.md` / `<role>.objective.md`, or
  /// `null` for a [fixed] holder that never reloads.
  final Directory? _rolesDir;

  /// The prose-file signature captured at the last (re)build.
  String? _signature;

  ReloadingRoleRegistry._(
    this._current,
    this._base,
    this._rolesDir,
    this._signature,
  );

  /// A holder over a fixed [registry] that never reloads. [current] always
  /// returns [registry].
  factory ReloadingRoleRegistry.fixed(RoleRegistry registry) =>
      ReloadingRoleRegistry._(registry, registry, null, null);

  /// A reloading holder over the in-code [base] roster and the prose
  /// [rolesDir]. The overlay is built and fingerprinted up front, so a
  /// no-change [current] is a true no-op from the first call; a later edit to a
  /// prose file rebuilds the overlay on the next [current].
  factory ReloadingRoleRegistry.reloading({
    required RoleRegistry base,
    required Directory rolesDir,
  }) =>
      ReloadingRoleRegistry._(
        loadFileBackedRoleRegistry(base: base, rolesDir: rolesDir),
        base,
        rolesDir,
        _signatureOf(base, rolesDir),
      );

  /// Whether this holder can reload (is backed by a `rolesDir`).
  bool get reloads => _rolesDir != null;

  /// The last-built overlay snapshot, without forcing a refresh. Use [current]
  /// when an up-to-date snapshot is required.
  RoleRegistry get latest => _current;

  /// Returns the current overlay, re-reading the prose files **iff** their cheap
  /// signature changed since the last build. A [fixed] holder returns the
  /// wrapped registry without touching the filesystem.
  RoleRegistry current() {
    final rolesDir = _rolesDir;
    if (rolesDir == null) return _current;
    final signature = _signatureOf(_base, rolesDir);
    if (signature != _signature) {
      _current = loadFileBackedRoleRegistry(base: _base, rolesDir: rolesDir);
      _signature = signature;
    }
    return _current;
  }

  /// A cheap fingerprint of every role's prose files: for each base role id, the
  /// `persona` and `objective` file's mtime + size (or an absent marker),
  /// sorted so the result is order-independent. No file body is read — an edit
  /// changes mtime/size, an add/remove flips the absent marker.
  static String _signatureOf(RoleRegistry base, Directory rolesDir) {
    final parts = <String>[];
    for (final id in base.ids) {
      for (final part in const ['persona', 'objective']) {
        final stat = File('${rolesDir.path}/$id.$part.md').statSync();
        final fingerprint = stat.type == FileSystemEntityType.notFound
            ? '-'
            : '${stat.modified.microsecondsSinceEpoch}|${stat.size}';
        parts.add('$id.$part|$fingerprint');
      }
    }
    parts.sort();
    return parts.join('\n');
  }
}
