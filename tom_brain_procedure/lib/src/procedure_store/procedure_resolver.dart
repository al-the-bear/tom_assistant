// ProcedureResolver — turns the loaded procedures into an `(id → version)`
// index and resolves a request to one [LoadedProcedure], with the fallback
// chain `[v_latest, …, v1]` (Plan step C.25;
// `tom_brain_procedure_specification.md` § 9, PE-6).
//
// The resolver sits one layer above the loader (C.24): the store (C.23)
// addresses procedures by physical location, the loader parses each
// source's header into a typed identity (`id`, `version`), and the
// resolver indexes those headers so a caller can ask for a procedure *by
// id* and get the right version. It also exposes the **fallback chain** —
// the ordered list of a procedure's versions from newest to `v1` — that
// the dispatcher's `FallbackExecutor` (D.29–D.32, PE-6) walks down when a
// run fails with one of the four typed failure classes. In the prototype
// only `v1` of any procedure exists, so a chain is a singleton; the chain
// *machinery* is present regardless, exactly as PE-6 requires, so the
// final subsystem inherits a working multi-version resolver unchanged.
//
// Separation of concerns (kept deliberately sharp across C.23–C.25):
//   - C.23 `CompositeProcedureStore` merges **backends** (disk + memory)
//     behind one I/O interface — "where does the source live".
//   - C.25 `ProcedureResolver` merges **versions** of one id over the
//     parsed header index — "which version answers this request".
// The two never overlap: the resolver consumes already-loaded headers and
// is ignorant of which backend each came from.

import 'procedure_loader.dart';
import 'procedure_not_found.dart';
import 'procedure_source.dart';
import 'procedure_store_interface.dart';

/// Indexes loaded procedures by `(id → version)` and resolves a request to
/// a single [LoadedProcedure], exposing the `[v_latest, …, v1]` fallback
/// chain (PE-6).
///
/// Immutable snapshot: the index is built once at construction. To reflect
/// a changed store (a new brain-authored `Procedure` node), build a fresh
/// resolver with [fromStore]. This keeps resolution a pure function of a
/// fixed index — a caller resolving the same id twice against one resolver
/// always gets the same answer.
final class ProcedureResolver {
  /// `id → versions`, each id's list ordered **descending** by version so
  /// `_byId[id].first` is the latest version and the whole list *is* the
  /// fallback chain `[v_latest, …, v1]`. Unmodifiable.
  final Map<String, List<LoadedProcedure>> _byId;

  ProcedureResolver._(this._byId);

  /// Builds a resolver from already-loaded procedures.
  ///
  /// The procedures may arrive in any order and may mix ids and versions;
  /// the resolver groups them by [LoadedProcedure.header] id and sorts each
  /// group's versions descending. Throws [ArgumentError] when two
  /// procedures share the same `(id, version)` — a deploy/programmer error
  /// (e.g. a disk script and a brain node both claiming `foo_v1` version 1)
  /// the resolver refuses to silently pick a winner for.
  factory ProcedureResolver(Iterable<LoadedProcedure> procedures) {
    final byId = <String, List<LoadedProcedure>>{};
    for (final proc in procedures) {
      final id = proc.header.id;
      final group = byId.putIfAbsent(id, () => <LoadedProcedure>[]);
      final clash = group.any((p) => p.header.version == proc.header.version);
      if (clash) {
        throw ArgumentError.value(
          proc.ref.toString(),
          'procedures',
          'duplicate procedure (id "$id" version ${proc.header.version}) — '
              'two sources claim the same identity',
        );
      }
      group.add(proc);
    }
    for (final group in byId.values) {
      group.sort((a, b) => b.header.version.compareTo(a.header.version));
    }
    return ProcedureResolver._(
      Map<String, List<LoadedProcedure>>.unmodifiable(
        byId.map(
          (id, group) => MapEntry(
            id,
            List<LoadedProcedure>.unmodifiable(group),
          ),
        ),
      ),
    );
  }

  /// Builds a resolver by enumerating [store], reading each source, and
  /// parsing its header with [loader].
  ///
  /// This is the production path the engine (C.38) uses: `store.list` →
  /// `store.read` → `loader.load` → resolver. A ref that no longer resolves
  /// (read returns `null` — deleted between `list` and `read`) is skipped;
  /// it is a benign race, not an error. A source whose header is malformed
  /// propagates [ProcedureHeaderInvalid] from the loader unchanged — a
  /// broken procedure is a loud failure, not one the resolver hides.
  static Future<ProcedureResolver> fromStore(
    ProcedureStore store, {
    ProcedureLoader loader = ProcedureLoader.shared,
  }) async {
    final refs = await store.list();
    final loaded = <LoadedProcedure>[];
    for (final ref in refs) {
      final ProcedureSource? src = await store.read(ref);
      if (src == null) continue; // gone between list and read — benign race
      loaded.add(loader.load(src));
    }
    return ProcedureResolver(loaded);
  }

  /// Every procedure id the resolver knows, sorted lexicographically.
  List<String> get ids => (_byId.keys.toList())..sort();

  /// Whether any version of [id] is known.
  bool knows(String id) => _byId.containsKey(id);

  /// The versions of [id] the resolver knows, ordered **descending**
  /// (`[v_latest, …, v1]`), or an empty list when [id] is unknown.
  List<int> versions(String id) =>
      (_byId[id] ?? const <LoadedProcedure>[])
          .map((p) => p.header.version)
          .toList(growable: false);

  /// The latest (highest) known version of [id], or `null` when [id] is
  /// unknown.
  int? latestVersion(String id) {
    final group = _byId[id];
    return (group == null || group.isEmpty) ? null : group.first.header.version;
  }

  /// Resolves [id] to a single [LoadedProcedure].
  ///
  /// When [version] is `null`, returns the latest known version. When
  /// [version] is given, returns exactly that version. Throws
  /// [ProcedureNotFound] when [id] is unknown, or when [id] is known but
  /// the requested [version] is not.
  LoadedProcedure resolve(String id, {int? version}) {
    final group = _byId[id];
    if (group == null || group.isEmpty) {
      throw ProcedureNotFound(id, version: version);
    }
    if (version == null) return group.first; // latest (descending order)
    for (final proc in group) {
      if (proc.header.version == version) return proc;
    }
    throw ProcedureNotFound(id, version: version);
  }

  /// The fallback chain for [id]: its versions ordered newest-first down to
  /// `v1`, as [LoadedProcedure]s.
  ///
  /// When [from] is `null` the chain is the full `[v_latest, …, v1]`. When
  /// [from] is given the chain starts at that version and steps down — the
  /// shape the dispatcher's `FallbackExecutor` (PE-6) needs after a run at
  /// version [from] fails: it walks the remaining chain `[from-?, …, v1]`,
  /// i.e. the versions strictly below [from], plus [from] itself at the
  /// head so the caller sees where it started.
  ///
  /// Throws [ProcedureNotFound] when [id] is unknown, or when [from] is
  /// given but no such version of [id] exists.
  List<LoadedProcedure> fallbackChain(String id, {int? from}) {
    final group = _byId[id];
    if (group == null || group.isEmpty) {
      throw ProcedureNotFound(id, version: from);
    }
    if (from == null) return group; // already unmodifiable + descending
    final startIndex = group.indexWhere((p) => p.header.version == from);
    if (startIndex == -1) {
      throw ProcedureNotFound(id, version: from);
    }
    return List<LoadedProcedure>.unmodifiable(group.sublist(startIndex));
  }
}
