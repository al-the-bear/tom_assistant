/// Substrate layer for Tom Brain — LLM provider abstraction, role /
/// persona system, embedding service, web tools, MCP client.
///
/// Every prompt the brain issues is dispatched through this layer
/// wrapped in the `AssistantDedicationAnchor` (from `tom_brain_shared`,
/// see `substrate_specification.md` § 5 and the quest overview
/// hard principle on the user-assistant framing being structural,
/// not advisory). There is no public path that bypasses the anchor;
/// B.23 will land a dedicated test that enforces this.
///
/// At B.6 the package is a buildable scaffold only — `lib/src/`
/// is empty and the barrel exports nothing. Subsequent steps fill
/// it in:
///
/// - B.6 ✅ — Project skeleton (`lib/`, `test/`, `pubspec.yaml`,
///   `_copilot_guidelines/`).
/// - B.7 — Runtime dependencies (`tom_brain_shared`, `tom_basics`,
///   `tom_core_kernel`, optionally `tom_core_server`, `dart_mcp`).
/// - B.8 — `lib/src/` folder layout (`llm/`, `roles/`, `embed/`,
///   `web/`, `mcp_client/`, `config/`, `api/`).
/// - B.9 — `TomBrainSubstrate` interface (the engine-side single
///   entry point).
/// - B.10 — `tom_master.yaml` wiring (no-op per policy override 5
///   on 2026-05-31; recorded for completeness only).
/// - B.11 – B.48 — provider impls, routing, roles, anchor injection,
///   embedding service, web tools, MCP client, config, observability,
///   in-process client, phase-end review.
///
/// See `_ai/quests/tom_brain/prototype_implementation_plan.md` Phase B
/// for the build order, and `_ai/quests/tom_brain/substrate_specification.md`
/// for the contract this package implements.
library;

// Exports land here, one per module, as B.8 – B.42 ship. At B.6 the
// barrel is intentionally empty — the smoke test compiles the import
// to prove the package resolves, and that is the load-bearing
// assertion at this step.
