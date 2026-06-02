# Changelog

## 0.0.1 — 2026-06-02 (Phase E.11)

OpenAI HTTP/SSE adapter — router scaffold:

- `lib/src/adapters/openai_http_sse/openai_http_sse_adapter.dart` —
  `OpenAiHttpSseAdapter`, a raw `shelf_router.Router` (Q-E.3.2 strategy 2)
  exposing `handler` (a `shelf.Handler`) with `POST /v1/chat/completions`,
  `POST /v1/embeddings`, and `GET /v1/models` mounted under `/v1/`. Routes
  are inert `501` stubs in the OpenAI error envelope until E.12 – E.18;
  unmatched path/verb returns the OpenAI `404` envelope.
- `lib/src/adapters/openai_http_sse/openai_http_sse.dart` — module barrel
  now exports the adapter.
- `pubspec.yaml` — `shelf: ^1.4.2` + `shelf_router: ^1.1.2` added as direct
  deps (Q-E.3.1 / Q-E.7.1; held out at E.7, decided here).
- `test/adapters/openai_http_sse_adapter_test.dart` — router-scaffold
  contract test (route paths, 501 stubs, 404 envelope, verb mismatch).
- `test/dependency_surface_test.dart` — locks the new `shelf` /
  `shelf_router` direct deps.

## 0.0.1 — 2026-06-02 (Phase E.9)

Executable entry point — the running process:

- `bin/tom_brain_access_prototype.dart` — a three-line shim over a
  `ToolRunner` wired to `accessPrototypeTool` + the serve executor.
  Non-zero exit on failure.
- `lib/src/api/access_prototype_tool.dart` — the `tom_build_base`
  `ToolDefinition` (`multiCommand` mode, default non-traversal `serve`
  command, framework-reserved `--config` / `-c` global option,
  version constants, running-process help footer).
- `lib/src/api/access_serve_executor.dart` — `AccessServeExecutor`
  (`executeWithoutTraversal` → status banner + `ToolResult.success`);
  reads `--config` from `CliArgs.configPath` (the framework's reserved
  field); `createAccessPrototypeExecutors()` factory.
- `lib/src/api/api.dart` — now exports the first concrete symbols.
- `pubspec.yaml` — `tom_build_base: ^2.6.21` added (workspace rule: every
  CLI tool is built on `tom_build_base`).
- `.gitignore` — `pubspec.lock` no longer ignored (Q-E.6.2: an
  application package that ships an executable commits its lock).
- `test/executable_test.dart` — black-box contract test for the tool
  shape, the executor map, and end-to-end `--version` / `--help` / bare
  `serve` / `--config` dispatch.
- `test/package_loads_test.dart` / `test/dependency_surface_test.dart` —
  updated to reference the first concrete exported symbols and lock the
  `tom_build_base` v2 framework surface.
- The `serve` command is a not-yet-wired stub; full boot lands at
  E.41 – E.45.

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
