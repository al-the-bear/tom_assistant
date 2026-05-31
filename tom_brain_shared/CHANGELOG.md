# Changelog

## 0.1.0 — 2026-05-30 (Phase A.20)

First stable contract release of `tom_brain_shared`. Cuts the v0.1.0 line so
that downstream Tom Brain components (`tom_brain_memory`, `tom_brain_substrate`,
`tom_brain_procedure_engine`, `tom_brain_procedure_dispatcher`,
`tom_brain_access`) can lock against a concrete version instead of a path
override. Per the workspace dependency-discipline rule, all consumers will
take this as a pinned `^0.1.0` constraint; path dependencies are forbidden.

Surface frozen at v0.1.0:

- `ids/` — `Ulid`, `PrefixedUlidId<TSelf>`, and the five identifier types
  (`NodeId`, `EdgeId`, `TrailId`, `StackEntryId`, `ProcedureId`).
- `embedding/` — `Vec` (`Float32List`-backed), `cosine`, `dot`, `l2`, `mean`.
- `budget/` — `Budget`, `TokenSpend`, `BudgetDelta`, `WriteBudget`.
- `result/` — sealed `Result<T, E>` (`Ok` / `Err`), sealed `Maybe<T>`
  (`Some` / `None`), `MaybeMap` / `MaybeWhen` extensions.
- `events/` — `BrainEvent` base, `DiagnosticEnvelope`, `DiagnosticSeverity`.
- `time/` — `BrainTime`, `Clock` (abstract interface), `SystemClock` /
  `FixedClock` / `MutableTestClock` reference impls.
- `version/` — `BrainVersion` (monotonic, numeric-not-lexical `compareTo`).
- `anchor/` — `AssistantDedicationAnchor` constants + `wrap` / `wrapAll`
  helpers that prepend the assistant-dedication anchor to every prompt
  before substrate dispatch (per `tom_brain_definition.md` § 3).

Quality gates passed at this version:

- `dart analyze` — `No issues found!` (A.19).
- `dart test` — 434 / 434 passing, no skips, no failures (A.18).
- `package:coverage` — 553 / 553 lines covered (100.0 %) with two
  structurally-uncoverable lines marked `// coverage:ignore-*` and
  explained in the A.18 details section.
- Dependency discipline — single runtime dependency `tom_basics: ^1.0.0`
  enforced by `test/dependency_discipline_test.dart` (A.9).

Publish posture: `publish_to: none` is retained because no central
pub server is configured for this workspace yet. Consumers within
`tom_assistant/` resolve through the workspace pubspec resolution
(monorepo siblings). When the local pub server lands, the `publish_to`
field will be repointed at that endpoint in a follow-up; the *version
number* of this release does not change. See Q-A.20.1 in
`prototype_implementation_questions.md`.

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
