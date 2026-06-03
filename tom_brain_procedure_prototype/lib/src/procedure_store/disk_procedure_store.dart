// DiskProcedureStore — the disk backend of the procedure store (Plan
// step C.23; `tom_brain_procedure_prototype_specification.md` § 9).
//
// Serves the two shipped/on-disk origins: `scripts/system/` (well-known,
// shipped — the permanent safety net, PE-6) and `scripts/user/`
// (user-authored). Each procedure is a `.dart` file; the file's contents
// are the verbatim source the loader (C.24) later parses for its header.
//
// Of the shipped `scripts/system/` procedures, only `answer_with_memory_v1`
// is a behavioural example that meaningfully exercises the bridges.
// `think_v1` is a *machinery fixture*, not a behavioural example: a pure
// no-op (`requires: []`, touches no effect surface) that exists solely to
// give the `think(…)` sugar verb and the depth-cap / fallback machinery a
// real callable target until the Phase-D thinking loop lands (Q-C.2.1).
//
// The backend is pure I/O. It does NOT derive a procedure's id/version
// from the filename — identity lives in the in-source header and is the
// loader's concern. It addresses procedures purely by file path, which
// keeps the disk backend ignorant of the header grammar (the same reason
// the interface keeps `read` keyed on a `ProcedureRef`, not an id).

import 'dart:io';

import 'procedure_origin.dart';
import 'procedure_ref.dart';
import 'procedure_source.dart';
import 'procedure_store_interface.dart';

/// Disk-backed [ProcedureStore] over a system directory and an optional
/// user directory.
///
/// `list` enumerates the `.dart` files directly inside each configured
/// directory (non-recursive), tagging system-directory files with
/// [ProcedureOrigin.system] and user-directory files with
/// [ProcedureOrigin.user]. A configured directory that does not exist
/// contributes nothing — a missing `scripts/user/` is normal, not an
/// error.
final class DiskProcedureStore implements ProcedureStore {
  /// Directory of shipped, well-known procedures (`scripts/system/`).
  final Directory systemDir;

  /// Directory of user-authored procedures (`scripts/user/`); `null`
  /// when the deployment ships no user scripts directory.
  final Directory? userDir;

  /// File-name suffix that marks a procedure source file. Defaults to
  /// `.dart` (which also matches `.d4rt.dart`).
  final String extension;

  DiskProcedureStore({
    required this.systemDir,
    this.userDir,
    this.extension = '.dart',
  });

  @override
  bool handles(ProcedureRef ref) => ref.origin.isDisk;

  @override
  Future<List<ProcedureRef>> list() async {
    final refs = <ProcedureRef>[
      ...await _listDir(systemDir, ProcedureOrigin.system),
      if (userDir != null) ...await _listDir(userDir!, ProcedureOrigin.user),
    ];
    refs.sort(_compareRefs);
    return refs;
  }

  @override
  Future<ProcedureSource?> read(ProcedureRef ref) async {
    if (!handles(ref)) {
      throw ArgumentError.value(
        ref,
        'ref',
        'DiskProcedureStore only handles disk origins '
            '(system / user); got ${ref.origin.name}.',
      );
    }
    final file = File(ref.locator);
    if (!await file.exists()) return null;
    final source = await file.readAsString();
    return ProcedureSource(ref: ref, source: source);
  }

  Future<List<ProcedureRef>> _listDir(
    Directory dir,
    ProcedureOrigin origin,
  ) async {
    if (!await dir.exists()) return const <ProcedureRef>[];
    final refs = <ProcedureRef>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File && entity.path.endsWith(extension)) {
        refs.add(ProcedureRef(origin: origin, locator: entity.path));
      }
    }
    return refs;
  }

  static int _compareRefs(ProcedureRef a, ProcedureRef b) {
    final byOrigin = a.origin.index.compareTo(b.origin.index);
    return byOrigin != 0 ? byOrigin : a.locator.compareTo(b.locator);
  }
}
