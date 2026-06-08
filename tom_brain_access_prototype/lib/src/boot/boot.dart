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
// - E.43 ✅ — `HealthCheck` (`health_check.dart`): the `GET /healthz` liveness
//   endpoint. Exposes a mountable `shelf` handler rendering
//   `{ status, uptime_s, queues }` — `status` is `ok` while serving and
//   `draining` once the coordinator is draining (E.42), `uptime_s` is whole
//   seconds since construction, `queues` is the live coordinator snapshot read
//   through an injectable `QueueSnapshotSource` seam (the access layer holds
//   only a `Dispatcher`, so the running process — E.45, which owns the
//   `RunCoordinator` — projects its getters onto the `QueueSnapshot`). The boot
//   root that mounts it on a live port alongside the `/v1/` routes is E.45.
// - E.45 ✅ — the boot root that ties the running process together. The
//   `BrainProvisioner` seam (`brain_provisioner.dart`) hands the access process
//   a booted cognition as a `ProvisionedBrain` (a `Dispatcher`, a
//   `QueueSnapshotSource`, and a teardown) without importing substrate / memory
//   — the CLI default `unsupportedBrainProvisioner` refuses, because only a
//   higher assembly may boot `BrainProcessBoot`. `OpenAiAccessEdge`
//   (`openai_access_edge.dart`) is the live, auth-gated `/v1/` channel driving
//   `AccessAssembler.admitOpenAi`; `TelegramAccessEdge`
//   (`telegram_access_edge.dart`) drives `admitTelegram` over the adapter's
//   whitelist-gated inbound stream. `startBrainAccessProcess`
//   (`brain_access_process.dart`) maps `AccessConfig` → `BrainAccessConfig`,
//   composes the admission core (E.41), stands up the OpenAI + `/healthz`
//   socket (one `Cascade`, one port) through the injectable `AccessServeSeam`,
//   optionally stands up the Telegram edge through the `TelegramChatApiFactory`
//   seam, and installs `GracefulShutdown` (E.42) over the ordered teardown,
//   returning a `BrainAccessProcess` handle.

export 'access_assembler.dart' show AccessAssembler;
export 'access_event_bus.dart' show AccessEventBus;
export 'brain_access_boot.dart'
    show BootedAccessLayer, BrainAccessBoot, BrainAccessConfig;
export 'brain_access_process.dart'
    show
        AccessServeSeam,
        AccessServer,
        BrainAccessProcess,
        TelegramChatApiFactory,
        defaultTelegramChatApiFactory,
        serveWithShelfIo,
        startBrainAccessProcess;
export 'brain_provisioner.dart'
    show
        BrainProvisioner,
        BrainProvisioningException,
        ProvisionedBrain,
        unsupportedBrainProvisioner;
export 'graceful_shutdown.dart'
    show
        GracefulShutdown,
        ProcessTerminator,
        ShutdownAction,
        shutdownExitError,
        shutdownExitOk;
export 'health_check.dart'
    show HealthCheck, QueueSnapshot, QueueSnapshotSource;
export 'incoming_trail_record.dart' show IncomingTrailRecord, IncomingTrailSink;
export 'anthropic_access_edge.dart' show AnthropicAccessEdge;
export 'ollama_access_edge.dart' show OllamaAccessEdge;
export 'openai_access_edge.dart' show OpenAiAccessEdge;
export 'telegram_access_edge.dart'
    show
        TelegramAccessEdge,
        telegramStartupAnnouncement,
        telegramProcessingAcknowledgement,
        telegramProcessingPreviewLength;
