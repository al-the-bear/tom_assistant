// Memory provisioning — the dispatcher's seam for obtaining the
// `TomBrainMemoryClient` it (and the engine behind it) talks to
// (Plan step D.43; `tom_brain_procedure_prototype_specification.md`
// § 12).
//
// D.43's contract is narrow and exact: "Adopt the
// `TomBrainMemoryIsolateHost` + `…Client` pair from Phase A. Wire the
// dispatcher to instantiate one isolate-hosted memory by default;
// allow in-process via config flag for tests." This file is that
// wiring — nothing more. The full process boot orchestration
// (`BrainProcessBoot`, which uses this seam to bring substrate +
// memory + engine + dispatcher up together) is D.44; clean shutdown
// is D.45; the crash-surfaces-as-typed-startup-error guarantee is
// D.46. Here we provision *memory only*, and we provision it the way
// both later steps need it: one isolate-hosted memory by default,
// with an in-process flag the tests flip.
//
// ── Why a provisioning seam rather than a hard-coded host ─────────
//
// The `MemoryBridge` (C.12) — and through it every procedure — talks
// to a `TomBrainMemoryClient`, the interface boundary (PE-10). It
// cannot tell whether that client marshals across an isolate
// boundary (`TomBrainMemoryIsolateClient`) or calls an in-process
// implementation directly. D.43 turns that indifference into a
// single decision point: the dispatcher provisions one client, the
// transport is a config flag, and everything downstream is identical
// across the two transports. That parity is exactly what the D.53
// conformance suite asserts ("isolate-mode + in-process-mode
// parity").
//
// ── Why the default is the isolate ───────────────────────────────
//
// In production the memory store owns a SQLite database, a vector
// index, an FTS index, and the cognitive-agent sleep cycles. Running
// it in its own isolate keeps that work off the dispatcher's event
// loop so a long recall or a sleep pass never stalls inbound
// admission. The in-process transport exists for tests (and a future
// single-isolate deployment): it needs no spawned isolate, so a test
// can inject a fake `TomBrainMemoryClient` and assert post-conditions
// synchronously.

import 'package:tom_brain_memory/tom_brain_memory.dart'
    show
        MemoryConfig,
        MemoryFactory,
        TomBrainMemoryClient,
        TomBrainMemoryIsolateClient,
        TomBrainMemoryIsolateHost;

/// Which transport the dispatcher provisions memory over.
///
/// The flag the D.43 contract names. [isolate] is the production
/// default; [inProcess] is the test (and single-isolate) path.
enum MemoryTransport {
  /// Memory runs in its own Dart isolate, reached through a
  /// [TomBrainMemoryIsolateHost] + [TomBrainMemoryIsolateClient]
  /// pair. The default.
  isolate,

  /// Memory runs in the dispatcher's own isolate; the dispatcher
  /// uses an injected [TomBrainMemoryClient] directly. For tests
  /// (and a future single-isolate deployment).
  inProcess,
}

/// Declares how the dispatcher should provision its memory client.
///
/// Constructed through one of the two named constructors so an
/// invalid combination (isolate transport without a factory,
/// in-process transport without a client) is unrepresentable. The
/// [transport] field is the config flag a reader inspects; the
/// branch-specific fields are non-null exactly for their branch.
class MemoryProvisioningConfig {
  /// The transport flag. [MemoryTransport.isolate] by default —
  /// produced by [MemoryProvisioningConfig.isolate].
  final MemoryTransport transport;

  /// Passed to `memory.open(config)` once the client exists. The
  /// same config is used for both transports.
  final MemoryConfig memoryConfig;

  /// Isolate transport only: the top-level/static factory the host
  /// hands the spawned isolate to construct its in-isolate
  /// `TomBrainMemory`. Non-null iff [transport] is
  /// [MemoryTransport.isolate]. Must be a top-level or static
  /// function — closures captured from the spawning isolate cannot
  /// cross the boundary (see [MemoryFactory]).
  final MemoryFactory? isolateFactory;

  /// Isolate transport only: forwarded to the host for
  /// `TomWorker`-level isolate naming.
  final String isolateNamePrefix;

  /// In-process transport only: the client the dispatcher uses
  /// directly. Non-null iff [transport] is
  /// [MemoryTransport.inProcess]. Injected by the caller (tests
  /// pass a fake; a single-isolate deployment passes a concrete
  /// in-process memory).
  final TomBrainMemoryClient? inProcessClient;

  /// The production default: one isolate-hosted memory.
  const MemoryProvisioningConfig.isolate({
    required MemoryFactory factory,
    required this.memoryConfig,
    this.isolateNamePrefix = 'TomBrainMemory',
  })  : transport = MemoryTransport.isolate,
        isolateFactory = factory,
        inProcessClient = null;

  /// The test (and single-isolate) flag: the dispatcher uses
  /// [client] in its own isolate.
  const MemoryProvisioningConfig.inProcess({
    required TomBrainMemoryClient client,
    required this.memoryConfig,
  })  : transport = MemoryTransport.inProcess,
        inProcessClient = client,
        isolateFactory = null,
        isolateNamePrefix = 'TomBrainMemory';
}

/// A provisioned, opened memory client plus its teardown.
///
/// [client] is ready to use the moment [MemoryProvisioner.provision]
/// resolves — the underlying memory has already been opened with the
/// config's [MemoryProvisioningConfig.memoryConfig]. The caller owns
/// the lifetime: call [dispose] exactly once when finished. For the
/// isolate transport [dispose] shuts the worker isolate down cleanly
/// (which flushes writes and checkpoints the WAL first); for the
/// in-process transport it closes the client.
class ProvisionedMemory {
  /// The memory client the dispatcher / engine / bridge talk to.
  /// Indifferent to the transport behind it (PE-10).
  final TomBrainMemoryClient client;

  /// The transport this memory was provisioned over.
  final MemoryTransport transport;

  /// The isolate host, exposed *only* for the isolate transport so
  /// the boot orchestration (D.44) can observe the worker's
  /// readiness and the shutdown sequence (D.45) can confirm a clean
  /// close. `null` for the in-process transport.
  final TomBrainMemoryIsolateHost? host;

  final Future<void> Function() _dispose;
  bool _disposed = false;

  ProvisionedMemory._({
    required this.client,
    required this.transport,
    required this.host,
    required Future<void> Function() dispose,
  }) : _dispose = dispose;

  /// Tears the provisioned memory down. Idempotent — a second call
  /// is a no-op, so it is safe in a `finally` block.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _dispose();
  }
}

/// Instantiates the dispatcher's memory client per a
/// [MemoryProvisioningConfig].
///
/// One [provision] call yields one opened [ProvisionedMemory]. The
/// provisioner holds no state beyond its config, so a fresh
/// [ProvisionedMemory] (and, for the isolate transport, a fresh
/// worker isolate) is produced on each call. Hosts are single-use
/// (Phase A): a disposed [ProvisionedMemory] cannot be reopened —
/// provision again for a fresh one.
class MemoryProvisioner {
  /// How to provision. The [MemoryProvisioningConfig.transport] flag
  /// selects the branch.
  final MemoryProvisioningConfig config;

  const MemoryProvisioner(this.config);

  /// Provisions and opens one memory client per [config].
  ///
  /// Isolate transport: spawns a [TomBrainMemoryIsolateHost] with
  /// the config's factory, waits for it to report ready, opens the
  /// memory inside the isolate, and wraps it in a
  /// [TomBrainMemoryIsolateClient]. [ProvisionedMemory.dispose]
  /// shuts the host down (closing memory first).
  ///
  /// In-process transport: opens the injected client and returns it
  /// directly. [ProvisionedMemory.dispose] closes the client.
  Future<ProvisionedMemory> provision() async {
    switch (config.transport) {
      case MemoryTransport.isolate:
        final host = TomBrainMemoryIsolateHost(
          factory: config.isolateFactory!,
          namePrefix: config.isolateNamePrefix,
        );
        await host.spawn();
        await host.openMemory(config.memoryConfig);
        final client = TomBrainMemoryIsolateClient(host);
        return ProvisionedMemory._(
          client: client,
          transport: MemoryTransport.isolate,
          host: host,
          // `host.shutdown()` sends `CloseMemoryRequest` first when
          // the memory is open, so it both closes memory and tears
          // the worker down.
          dispose: host.shutdown,
        );
      case MemoryTransport.inProcess:
        final client = config.inProcessClient!;
        await client.open(config.memoryConfig);
        return ProvisionedMemory._(
          client: client,
          transport: MemoryTransport.inProcess,
          host: null,
          dispose: client.close,
        );
    }
  }
}
