// CompositeProcedureStore — the "two backends behind one interface"
// face of the procedure store (Plan step C.23;
// `tom_brain_procedure_prototype_specification.md` § 9).
//
// The engine consults disk + memory as a single store. This composite
// fans `list` across an ordered list of backends and routes each `read`
// to the backend that `handles` the reference. It is itself a
// `ProcedureStore`, so it nests cleanly and a consumer cannot tell a
// composite from a leaf backend.
//
// Ordering matters for `list` only as a stable presentation concern —
// backends are consulted in construction order and each backend's own
// `list` is already sorted. Routing in `read` is by `handles`, not by
// position, so two backends could never both claim the same reference
// (disk owns system/user, memory owns brain).

import 'procedure_ref.dart';
import 'procedure_source.dart';
import 'procedure_store_interface.dart';

/// A [ProcedureStore] that presents an ordered list of backends as one.
final class CompositeProcedureStore implements ProcedureStore {
  /// The backends consulted, in order. Typically `[disk, memory]`.
  final List<ProcedureStore> backends;

  CompositeProcedureStore(List<ProcedureStore> backends)
      : backends = List<ProcedureStore>.unmodifiable(backends);

  @override
  bool handles(ProcedureRef ref) =>
      backends.any((backend) => backend.handles(ref));

  @override
  Future<List<ProcedureRef>> list() async {
    final refs = <ProcedureRef>[];
    for (final backend in backends) {
      refs.addAll(await backend.list());
    }
    return refs;
  }

  @override
  Future<ProcedureSource?> read(ProcedureRef ref) async {
    for (final backend in backends) {
      if (backend.handles(ref)) return backend.read(ref);
    }
    throw ArgumentError.value(
      ref,
      'ref',
      'No backend in this composite handles origin ${ref.origin.name}.',
    );
  }
}
