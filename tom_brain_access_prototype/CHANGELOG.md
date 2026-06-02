# Changelog

## 0.0.1 — 2026-06-02 (Phase E.8)

`lib/src/` module layout established:

- Nine leaf-module subfolders created under `lib/src/`, two of them
  nested under a shared `adapters/` grouping directory:
  `adapters/openai_http_sse/`, `adapters/telegram/`, `identity/`,
  `edge_security/`, `heuristic_classifier/`, `delivery/`, `boot/`,
  `config/`, `api/`. Each carries an intentionally-empty per-folder
  barrel (`//` comment header naming its ownership and the E-steps that
  populate it — no symbols yet).
- Top-level barrel `lib/tom_brain_access_prototype.dart` now re-exports
  all nine module barrels in request-flow order, so the package surface
  mirrors the internal layout from day one.
- Stale E.6 placeholder `lib/src/.gitkeep` removed.
- `test/folder_layout_test.dart` — locks the leaf-module inventory, the
  per-folder barrel convention, the top-level re-export, the placeholder
  removal, and the absence of stray directories (incl. under
  `adapters/`).

## 0.0.1 — 2026-06-02 (Phase E.7)

Runtime dependencies wired:

- `pubspec.yaml` — the six plan-named runtime dependencies added:
  `tom_brain_shared`, `tom_brain_procedure_prototype` (interface boundary
  — dispatcher only), `tom_basics`, `tom_core_kernel`, `tom_core_server`
  (path deps), and `tom_chattools: ^1.0.2` (the E.4 pin). `mocktail`
  reserved under `dev_dependencies`.
- `test/dependency_surface_test.dart` — locks the dependency surface and
  the specific identifiers the access layer leans on from each library
  (incl. `Access` / `Dispatcher` / `ChatApi` / `TomBearerAuthentication`).
- `shelf` / `shelf_router` deliberately NOT direct deps — the E.11
  mounting strategy (Q-E.3.2) decides whether they are added later.

## 0.0.1 — 2026-06-02 (Phase E.6)

Initial project scaffold:

- `pubspec.yaml` — minimal skeleton, no runtime dependencies yet
  (deferred to E.7 per the plan).
- Empty barrel `lib/tom_brain_access_prototype.dart`.
- `lib/src/` placeholder for the module layout that lands in E.8.
- Smoke test verifying the package loads (`test/package_loads_test.dart`).
- Local copilot guidelines at `_copilot_guidelines/index.md`.
- `analysis_options.yaml` with `package:lints/recommended.yaml`.
