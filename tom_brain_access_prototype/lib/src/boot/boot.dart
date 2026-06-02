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
// - E.42 ✅ — `GracefulShutdown` (`graceful_shutdown.dart`): watches OS
//   termination signals (SIGINT / SIGTERM) and runs an async process teardown
//   to completion before the process exits. The teardown itself is phase D's
//   `BootedBrain.shutdown` (stop access → drain foreground → close memory →
//   close substrate); E.42 wires the signal to it via an injectable
//   `ShutdownAction` seam, so the coordinator depends on no concrete boot type
//   and is driven in tests with synthetic signal streams + a recording
//   terminator. Mirrors D.45 shutdown orchestration.

export 'access_assembler.dart' show AccessAssembler;
export 'access_event_bus.dart' show AccessEventBus;
export 'brain_access_boot.dart'
    show BootedAccessLayer, BrainAccessBoot, BrainAccessConfig;
export 'graceful_shutdown.dart'
    show
        GracefulShutdown,
        ProcessTerminator,
        ShutdownAction,
        shutdownExitError,
        shutdownExitOk;
