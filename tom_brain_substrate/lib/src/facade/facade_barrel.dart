// Barrel for the `facade/` module (B.41 / substrate_specification.md
// § 3.1 + spec § 16 composition root).
//
// Owns the v1 in-process facade `InProcessTomBrainSubstrate` — the
// concrete implementation of `TomBrainSubstrate` (the in-process
// marker base) that composes a role registry, a provider map, an
// `LlmRouter`, an `EmbeddingService`, a `WebSearch`, a `WebFetch`,
// a `SubstrateEventBus`, and a lazy MCP-client cache.
//
// The isolate adapter variant the substrate spec § 16 mentions is
// deferred to `completion_steps.tom_brain.md`; the prototype ships
// the in-process variant only, and the engine binds against
// `TomBrainSubstrateClient` (B.40 boundary lock) so a future isolate
// adapter ships through the same consumer surface.

export 'in_process_tom_brain_substrate.dart';
