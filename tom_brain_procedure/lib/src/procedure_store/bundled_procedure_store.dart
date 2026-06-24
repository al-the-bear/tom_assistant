// BundledProcedureStore — the compiled-in bundle backend of the procedure
// store (CLI plan step 3; `tom_brain_procedure_specification.md` § 9).
//
// The standalone `tom_brain` CLI ships its `scripts/system/` procedures as a
// *bundle* compiled into the executable, so a single-file CLI carries its
// safety-net procedures with no on-disk `scripts/` tree. This backend serves
// that bundle: an in-memory `locator → source` map fixed at construction
// (the codegen emits the map; CLI plan step 4 wires a real one in).
//
// Read-only by construction. There is no write path: the map is captured
// unmodifiable and the interface exposes only `list` / `read` / `signature`.
// This is what realizes the safety invariant "authored procedures require a
// writable disk `scripts/`" — you physically cannot author into the bundle,
// so a deployment that wants new procedures must provide a writable disk
// store (which then overlays the bundle by id; see `ShadowingProcedureStore`).
//
// Like the disk backend, this store is pure storage: it does not parse the
// header. It addresses each bundled procedure by its bundle-local locator
// (the codegen's per-source key — typically the source filename stem), which
// keeps the bundle ignorant of the header grammar exactly as the disk backend
// is. Identity (`id`, `version`) is the loader's concern.

import 'procedure_ref.dart';
import 'procedure_source.dart';
import 'procedure_store_interface.dart';

/// Read-only [ProcedureStore] over a compiled-in `locator → source` bundle.
///
/// The bundle is immutable for the process lifetime, so [signature] is a
/// constant fingerprint computed once at construction — a reload never has to
/// re-scan it.
final class BundledProcedureStore implements ProcedureStore {
  /// Bundle-local `locator → verbatim source` map, captured unmodifiable.
  final Map<String, String> _sources;

  /// A constant content fingerprint of the bundle (its sorted
  /// `locator|length` lines). The bundle cannot change at runtime, so this is
  /// computed once.
  final String _signature;

  /// Builds a bundle store over [sources] (`locator → verbatim d4rt source`).
  ///
  /// The map is copied unmodifiable so a caller's later mutation cannot reach
  /// the bundle. [buildHash], when given, is used verbatim as the
  /// [signature]; otherwise a fingerprint is derived from the keys and source
  /// lengths. Either way the value is constant for the store's lifetime.
  factory BundledProcedureStore(
    Map<String, String> sources, {
    String? buildHash,
  }) {
    final copy = Map<String, String>.unmodifiable(sources);
    final signature = buildHash ?? _deriveSignature(copy);
    return BundledProcedureStore._(copy, signature);
  }

  BundledProcedureStore._(this._sources, this._signature);

  static String _deriveSignature(Map<String, String> sources) {
    final parts = sources.entries
        .map((e) => '${e.key}|${e.value.length}')
        .toList()
      ..sort();
    return parts.join('\n');
  }

  @override
  bool handles(ProcedureRef ref) => ref.origin.isBundle;

  @override
  Future<List<ProcedureRef>> list() async {
    final keys = _sources.keys.toList()..sort();
    return keys.map(ProcedureRef.bundle).toList(growable: false);
  }

  @override
  Future<ProcedureSource?> read(ProcedureRef ref) async {
    if (!handles(ref)) {
      throw ArgumentError.value(
        ref,
        'ref',
        'BundledProcedureStore only handles bundle origins; '
            'got ${ref.origin.name}.',
      );
    }
    final source = _sources[ref.locator];
    if (source == null) return null;
    return ProcedureSource(ref: ref, source: source);
  }

  @override
  Future<String> signature() async => _signature;
}
