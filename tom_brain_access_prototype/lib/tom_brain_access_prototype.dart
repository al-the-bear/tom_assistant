/// Prototype access layer for Tom Brain — the inbound surface and the
/// actual running process.
///
/// This package owns the channels that carry real user work into the
/// brain and stream answers back out: an OpenAI-format HTTP/SSE adapter
/// and a Telegram adapter. It produces the `Access` object the dispatcher
/// (`tom_brain_procedure_prototype`) consumes, resolves identity /
/// session / persona, enforces edge security (bearer auth, rate limits,
/// quota, anchor pre-check), runs the cheap kind-hint classifier, and
/// delivers outbound chunks back to the originating channel. See
/// `tom_brain_access_prototype_specification.md` and Phase E of
/// `prototype_implementation_plan.md`.
///
/// At E.6 this is an empty skeleton: a buildable package with a smoke
/// test and nothing else. The barrel exports nothing yet; subsequent
/// steps land the real surface:
///
/// - E.6  ✅ — Project skeleton (`lib/`, `test/`, `pubspec.yaml`,
///   `analysis_options.yaml`, `_copilot_guidelines/`, README, CHANGELOG).
/// - E.7  ⏳ — Runtime dependencies (`tom_brain_shared`,
///   `tom_brain_procedure_prototype`, `tom_basics`, `tom_core_kernel`,
///   `tom_core_server`, `tom_chattools`).
/// - E.8  ⏳ — `lib/` folder layout (`adapters/openai_http_sse/`,
///   `adapters/telegram/`, `identity/`, `edge_security/`,
///   `heuristic_classifier/`, `delivery/`, `boot/`, `config/`, `api/`).
/// - E.9  ⏳ — `bin/tom_brain_access_prototype.dart` executable
///   (the running process; built via `tom_build_base`'s `ToolDefinition`).
/// - E.10 ⏳ — `.tom_metadata/tom_master.yaml` wiring (no-op per
///   policy override 5).
/// - E.11 – E.50 ⏳ — OpenAI adapter, Telegram adapter, identity /
///   session / persona, edge security, kind-hint classifier, delivery,
///   boot, and the end-to-end smoke.
library;

// No exports yet. The api/ surface lands at E.9+.
