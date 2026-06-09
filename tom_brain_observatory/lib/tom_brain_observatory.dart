/// Tom Brain Observatory — the read-only observability web app over a running
/// Tom Brain prototype (`prompt_tracing.md`).
///
/// This is the package scaffold (`prompt_tracing_plan.md` PT-0.2). The two
/// modules — Prompt Tracing (the trail tree, § 3–§ 4) and Memory Monitoring
/// (the memory MCP read API, § 5) — and the Trail Read API backend that serves
/// them (§ 8.3) land in later phases (PT-1.* onward). Until then this library
/// carries only the package identity so `lib/` is analyze-clean and importable.
///
/// Read-only is load-bearing (OBS-1…OBS-5, `prompt_tracing.md` § 6.2): no code
/// in this package ever writes a trail file, the memory store, or any brain
/// control surface.
library;

/// The observatory package version, mirroring `pubspec.yaml`'s `version`.
const String observatoryVersion = '0.0.1';
