// ShadowingProcedureStore — presents "disk overlays bundle by procedure id"
// as one [ProcedureStore] (CLI plan step 3;
// `tom_brain_procedure_specification.md` § 9).
//
// The standalone CLI ships its safety-net procedures in a compiled-in bundle
// (`BundledProcedureStore`) but still lets a deployment drop `.dart` files
// into a writable disk `scripts/` directory. Those disk procedures **overlay
// the bundle by procedure id**: any disk version of an id suppresses *every*
// bundled version of that id, so editing a shipped procedure on disk fully
// replaces its bundled copy rather than merging versions with it.
//
// Why this is a distinct store and not just a `CompositeProcedureStore`:
// the composite merges backends without looking at identity — it would
// surface both the disk `foo_v1` and the bundled `foo_v2`, and the resolver
// would then expose *both* versions (a fallback chain `[v2(bundle), v1(disk)]`).
// That is wrong for the overlay semantics: a disk edit must win the whole id,
// not just contribute another version. Shadowing therefore has to know each
// ref's id, which means parsing — so, unlike the composite, this store reads
// and loads sources in `list()`.
//
// Cost: `list()` reads + parses the primary sources (to learn the disk ids)
// and the shadowed sources (to learn which to suppress). That parse is paid
// at boot and on each reload — never on a hot path — and it is inherent to
// id-level shadowing (you cannot decide what to suppress without knowing the
// ids). `read` stays cheap: it routes straight to the owning backend.
//
// Loud on a broken procedure: a malformed header in either backend
// propagates `ProcedureHeaderInvalid` from the loader (the same contract as
// `ProcedureResolver.fromStore`). A ref that vanished between enumerate and
// read (null source) is skipped as a benign race.

import 'procedure_loader.dart';
import 'procedure_ref.dart';
import 'procedure_source.dart';
import 'procedure_store_interface.dart';

/// A [ProcedureStore] where [primary] (the writable disk store) overlays
/// [shadowed] (the compiled-in bundle) by procedure id.
final class ShadowingProcedureStore implements ProcedureStore {
  /// The overlaying store — typically the writable disk `scripts/` store.
  /// Every primary ref is served; the primary's ids shadow the bundle.
  final ProcedureStore primary;

  /// The shadowed store — typically the compiled-in bundle. Only its refs
  /// whose parsed id is NOT among the primary ids survive enumeration.
  final ProcedureStore shadowed;

  /// Loader used to parse ids during enumeration. The loader is stateless;
  /// the shared instance suffices.
  final ProcedureLoader loader;

  ShadowingProcedureStore({
    required this.primary,
    required this.shadowed,
    this.loader = ProcedureLoader.shared,
  });

  @override
  bool handles(ProcedureRef ref) =>
      primary.handles(ref) || shadowed.handles(ref);

  @override
  Future<List<ProcedureRef>> list() async {
    // Enumerate + parse the primary refs to learn its ids; every primary ref
    // survives. A broken primary procedure is loud; a vanished ref is skipped.
    final primaryRefs = await primary.list();
    final primaryIds = <String>{};
    final kept = <ProcedureRef>[];
    for (final ref in primaryRefs) {
      final src = await primary.read(ref);
      if (src == null) continue; // gone between list and read — benign race
      primaryIds.add(loader.load(src).header.id);
      kept.add(ref);
    }

    // Keep only the shadowed refs whose id is NOT claimed by the primary.
    for (final ref in await shadowed.list()) {
      final src = await shadowed.read(ref);
      if (src == null) continue;
      if (primaryIds.contains(loader.load(src).header.id)) continue;
      kept.add(ref);
    }
    return kept;
  }

  @override
  Future<ProcedureSource?> read(ProcedureRef ref) {
    if (primary.handles(ref)) return primary.read(ref);
    if (shadowed.handles(ref)) return shadowed.read(ref);
    throw ArgumentError.value(
      ref,
      'ref',
      'Neither the primary nor the shadowed store handles origin '
          '${ref.origin.name}.',
    );
  }

  @override
  Future<String> signature() async =>
      'primary:${await primary.signature()}\n'
      '--\n'
      'shadowed:${await shadowed.signature()}';
}
