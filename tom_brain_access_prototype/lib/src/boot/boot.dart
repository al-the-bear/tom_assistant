// Boot + the running process.
//
// Owns `BrainAccessBoot` (composes the inbound access layer — identity, edge
// security, the three `Access`-filling resolvers, the optional kind-hint
// classifier, and outbound delivery — over a *booted dispatcher*, plugging
// into `BrainProcessBoot`'s `AccessLayerInstaller` seam), the
// `AccessEventBus` (the access edge's lifecycle fan-in), and the
// `AccessAssembler` (the per-request admission pipeline the channel edges
// drive). See `tom_brain_access_prototype_specification.md` § Boot and Plan
// steps E.41 – E.45.
//
// - E.41 ✅ — `AccessEventBus` (the `AccessEvent` fan-in), `AccessAssembler`
//   (the admission pipeline: auth → identity → rate-limit → quota → anchor →
//   session → classify → bind delivery → build `Access` → emit
//   `AccessCreated` → dispatch), and `BrainAccessBoot` (`install` assembles
//   the surface over a `Dispatcher`; `installer` adapts it to the
//   `AccessLayerInstaller` seam). The live HTTP serve loop / Telegram
//   inbound-stream driving (the edges that *call* the assembler) are E.45.

export 'access_assembler.dart' show AccessAssembler;
export 'access_event_bus.dart' show AccessEventBus;
export 'brain_access_boot.dart'
    show BootedAccessLayer, BrainAccessBoot, BrainAccessConfig;
