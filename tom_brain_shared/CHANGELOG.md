# Changelog

## 0.0.1 — 2026-05-30

- Initial project scaffold (Phase A step A.7).
- Empty barrel `lib/tom_brain_shared.dart`.
- Smoke test that the package loads.
- Local copilot guidelines at `_copilot_guidelines/index.md`.
- A.10 — `ids/` module: pure-Dart `Ulid` (Crockford base32, 26 chars,
  48-bit ms timestamp + 80-bit secure randomness), `PrefixedUlidId`
  abstract base, and the five Tom Brain identifier types: `NodeId`
  (`n_…`), `EdgeId` (`e_…`), `TrailId` (`t_…`), `StackEntryId` (`se_…`),
  `ProcedureId` (`p_<slug>_v<version>`). All `fromString` factories
  validate prefix + payload. 92 unit tests, all green.
