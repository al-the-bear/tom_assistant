# `scripts/user/` — user-authored procedures (`ProcedureOrigin.user`)

This directory holds user-authored procedure scripts (`*.dart`), served by
`DiskProcedureStore` and tagged with `ProcedureOrigin.user` (Plan step C.23;
`tom_brain_procedure_prototype_specification.md` § 9).

It is **empty in the prototype** and that is intentional: the prototype ships
its procedures under `scripts/system/` only. A missing or empty `scripts/user/`
is normal, not an error — `DiskProcedureStore` contributes nothing from a
directory that does not exist or holds no `.dart` files (see
`disk_procedure_store.dart`).

This README exists solely so the empty directory is tracked in git, confirming
the `system` / `user` split that Plan step D.7 establishes. It is not a
procedure: `DiskProcedureStore.list()` enumerates only `*.dart` files, so this
file is never loaded.

Add user procedures here as `*.dart` files with a valid structured header (see
`scripts/system/think_v1.dart` for the header grammar).
