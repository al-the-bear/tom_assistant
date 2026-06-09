# `scripts/` — on-disk procedure tree

This directory is the disk-backed half of the procedure store
(`DiskProcedureStore`, Plan step C.23;
`tom_brain_procedure_specification.md` § 9). It is split into two
origins, matching `ProcedureOrigin.system` / `ProcedureOrigin.user`:

| Directory        | Origin                     | Purpose |
| ---------------- | -------------------------- | ------- |
| `scripts/system/` | `ProcedureOrigin.system`   | Shipped, well-known procedures — the permanent safety net (PE-6). Never demoted. `answer_with_memory_v1` lands here (D.8/D.36). The `think_v1` no-op stub already ships here. |
| `scripts/user/`   | `ProcedureOrigin.user`     | User-authored procedures. Optional: a missing or empty `scripts/user/` is normal, not an error (`DiskProcedureStore` contributes nothing from a directory that does not exist or holds no `.dart` files). |

The default config paths (`EngineConfig`) point here:

- `defaultSystemScriptsPath` → `scripts/system`
- `defaultUserScriptsPath`   → `scripts/user`

`DiskProcedureStore.list()` enumerates only `*.dart` files directly inside
each directory (non-recursive); non-`.dart` files such as these READMEs are
ignored. Procedure identity (id + version) lives in each file's structured
header, not in its path — see `ProcedureLoader` (C.24).

The third origin, `ProcedureOrigin.brain` (brain-authored procedures stored
as `Procedure` nodes in memory), is served by the memory backend and has no
on-disk directory here.
