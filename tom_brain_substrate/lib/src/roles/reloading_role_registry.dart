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
// The stat signature alone misses one edit: a rewrite of the same length that
// lands in the same modification-time tick as the write before the last build
// (`OLD OBJECTIVE` → `NEW OBJECTIVE`, or a one-character fix made quickly). So
// every prose file modified within [ReloadingRoleRegistry.tickWindow] of a
// build is also hashed at that build, and compared by content while it is
// pending. Once the window has passed a later write necessarily carries a newer
// mtime, so the files settle after one more comparison and a no-change
// [current] is a stat walk again.
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

import 'package:tom_basics/utilities.dart' show tomSha256Hex;

import 'file_backed_role_loader.dart';
import 'role_registry.dart';

/// Holds the substrate's *current* prose-overlaid [RoleRegistry] and, when
/// backed by a `rolesDir`, rebuilds it on demand when the prose files change.
final class ReloadingRoleRegistry {
  /// How close to a build a prose file's modification time must be for the
  /// file to share a timestamp tick with a later write. Two seconds covers the
  /// coarsest common granularity (FAT); ext4, APFS and NTFS are far finer.
  static const tickWindow = Duration(seconds: 2);

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

  /// When the last (re)build started.
  DateTime _builtAt;

  /// Content hashes of the prose files whose modification time fell within
  /// [tickWindow] of the last build, by path. Empty once they have settled.
  Map<String, String> _pendingHashes;

  ReloadingRoleRegistry._(
    this._current,
    this._base,
    this._rolesDir,
    this._signature,
    this._builtAt,
    this._pendingHashes,
  );

  /// A holder over a fixed [registry] that never reloads. [current] always
  /// returns [registry].
  factory ReloadingRoleRegistry.fixed(RoleRegistry registry) =>
      ReloadingRoleRegistry._(
        registry,
        registry,
        null,
        null,
        DateTime.now(),
        const {},
      );

  /// A reloading holder over the in-code [base] roster and the prose
  /// [rolesDir]. The overlay is built and fingerprinted up front, so a
  /// no-change [current] is a true no-op from the first call; a later edit to a
  /// prose file rebuilds the overlay on the next [current].
  factory ReloadingRoleRegistry.reloading({
    required RoleRegistry base,
    required Directory rolesDir,
  }) {
    // The fingerprint is taken before the files are read, so a write between
    // the two leads to one extra rebuild rather than to a missed edit.
    final builtAt = DateTime.now();
    final signature = _signatureOf(base, rolesDir);
    final pending = _recentHashes(base, rolesDir, builtAt);
    return ReloadingRoleRegistry._(
      loadFileBackedRoleRegistry(base: base, rolesDir: rolesDir),
      base,
      rolesDir,
      signature,
      builtAt,
      pending,
    );
  }

  /// Whether this holder can reload (is backed by a `rolesDir`).
  bool get reloads => _rolesDir != null;

  /// How many prose files [current] still compares by content: those modified
  /// within [tickWindow] of the last build, until they settle.
  int get pendingContentChecks => _pendingHashes.length;

  /// The last-built overlay snapshot, without forcing a refresh. Use [current]
  /// when an up-to-date snapshot is required.
  RoleRegistry get latest => _current;

  /// Returns the current overlay, re-reading the prose files **iff** they
  /// changed since the last build: their stat signature differs, or a file
  /// still pending a content check (see [pendingContentChecks]) has new
  /// content. A [fixed] holder returns the wrapped registry without touching
  /// the filesystem.
  RoleRegistry current() {
    final rolesDir = _rolesDir;
    if (rolesDir == null) return _current;
    final now = DateTime.now();
    final signature = _signatureOf(_base, rolesDir);
    if (signature != _signature || _pendingContentChanged()) {
      _pendingHashes = _recentHashes(_base, rolesDir, now);
      _current = loadFileBackedRoleRegistry(base: _base, rolesDir: rolesDir);
      _signature = signature;
      _builtAt = now;
    } else if (_pendingHashes.isNotEmpty &&
        !now.isBefore(_builtAt.add(tickWindow))) {
      // Every write that could share a tick with the build has happened by
      // now, and none changed the content, so later writes show in the stat
      // signature.
      _pendingHashes = const {};
    }
    return _current;
  }

  bool _pendingContentChanged() {
    for (final entry in _pendingHashes.entries) {
      if (_hashOf(File(entry.key)) != entry.value) return true;
    }
    return false;
  }

  /// A cheap fingerprint of every role's prose files: for each base role id, the
  /// `persona` and `objective` file's mtime + size (or an absent marker),
  /// sorted so the result is order-independent. No file body is read — an edit
  /// changes mtime/size, an add/remove flips the absent marker.
  static String _signatureOf(RoleRegistry base, Directory rolesDir) {
    final parts = <String>[];
    for (final file in _proseFiles(base, rolesDir)) {
      final stat = file.statSync();
      final fingerprint = stat.type == FileSystemEntityType.notFound
          ? '-'
          : '${stat.modified.microsecondsSinceEpoch}|${stat.size}';
      parts.add('${file.path}|$fingerprint');
    }
    parts.sort();
    return parts.join('\n');
  }

  /// The content hash of every existing prose file modified within
  /// [tickWindow] of [builtAt] (or after it), by path.
  static Map<String, String> _recentHashes(
    RoleRegistry base,
    Directory rolesDir,
    DateTime builtAt,
  ) {
    final since = builtAt.subtract(tickWindow);
    final hashes = <String, String>{};
    for (final file in _proseFiles(base, rolesDir)) {
      final stat = file.statSync();
      if (stat.type == FileSystemEntityType.notFound) continue;
      if (stat.modified.isBefore(since)) continue;
      hashes[file.path] = _hashOf(file);
    }
    return hashes;
  }

  static Iterable<File> _proseFiles(RoleRegistry base, Directory rolesDir) => [
    for (final id in base.ids)
      for (final part in const ['persona', 'objective'])
        File('${rolesDir.path}/$id.$part.md'),
  ];

  /// The file's content hash, or `-` when it cannot be read (deleted since).
  static String _hashOf(File file) {
    try {
      return tomSha256Hex(file.readAsBytesSync());
    } on FileSystemException {
      return '-';
    }
  }
}
