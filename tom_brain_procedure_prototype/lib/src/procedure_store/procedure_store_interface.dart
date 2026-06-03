// ProcedureStore — the one interface both procedure backends sit behind
// (Plan step C.23; `tom_brain_procedure_prototype_specification.md`
// § 9).
//
// The spec puts it plainly: "`ProcedureStore` has two backends behind
// one interface". This file is that interface. Two concrete backends
// implement it — `DiskProcedureStore` (system + user scripts on disk)
// and `MemoryProcedureStore` (brain-authored `Procedure` nodes) — and a
// `CompositeProcedureStore` presents an ordered fan of backends as a
// single store so a consumer sees disk + memory through one handle.
//
// The interface is intentionally minimal and I/O-only:
//
//   - `list()`   enumerates the references a store can serve, *without*
//                reading source bodies (cheap: directory listing / node
//                id scan). The memory backend in particular loads source
//                lazily, so enumeration must not pull every body.
//   - `read(ref)` reads the raw source for one reference.
//   - `handles(ref)` lets the composite route a `read` to the backend
//                that owns the reference.
//
// What the store does NOT do (by design, deferred to later C-steps):
// parse the structured header (loader, C.24) or resolve a fallback
// version chain (resolver, C.25). The store traffics in raw bytes keyed
// by physical location; identity and versioning are layered on top.

import 'procedure_ref.dart';
import 'procedure_source.dart';

/// The substitutable contract for procedure storage.
///
/// Every backend (disk, memory) and the composite implement this. A
/// consumer holds a `ProcedureStore` reference and stays ignorant of
/// whether a given procedure lives on disk or in memory — exactly the
/// "two backends behind one interface" the spec § 9 calls for.
abstract interface class ProcedureStore {
  /// Enumerates every procedure reference this store can serve, without
  /// reading source bodies.
  ///
  /// The returned list is ordered deterministically (by origin then
  /// locator) so callers and tests see a stable enumeration. An empty
  /// list means the store holds no procedures (e.g. a disk backend whose
  /// configured directories do not exist).
  Future<List<ProcedureRef>> list();

  /// Whether this store owns [ref] and can [read] it.
  ///
  /// The composite uses this to route a read to the right backend; a
  /// concrete backend uses it to reject a reference it does not own
  /// (a defensive boundary check, since refs are minted by `list`).
  bool handles(ProcedureRef ref);

  /// Reads the raw source for [ref], or `null` when the reference no
  /// longer resolves (file deleted, node tombstoned, wrong type).
  ///
  /// Throws [ArgumentError] when [ref] is not [handles]d by this store —
  /// a programmer error, since refs come from this store's own `list`.
  Future<ProcedureSource?> read(ProcedureRef ref);
}
