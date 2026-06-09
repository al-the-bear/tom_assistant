// standUpSmokeProcess + SmokeProcess — the end-to-end stand-up harness (E.46).
//
// Plan step E.46 (verbatim): "Stand up the process with a stub substrate + an
// in-isolate memory + the OpenAI adapter on a local port."
//
// ── What this harness does ───────────────────────────────────────────
//
// It is the higher assembly the access package's `BrainProvisioner` seam
// anticipates: the one place that may import substrate + memory and boot the
// whole cognition, then point the access process at it.
//
//   1. Boot the cognition. `BrainProcessBoot.boot` brings up the stub
//      [SmokeSubstrate] (in-process) and an in-isolate [SmokeMemory] (the
//      production isolate transport, via the top-level [spawnSmokeMemory]
//      factory), then assembles the engine + dispatcher. No access layer is
//      installed through the boot's own installer seam — the access process is
//      stood up *separately* over the booted dispatcher.
//   2. Project the cognition into a [ProvisionedBrain]. The access process
//      holds only a `Dispatcher` and a `QueueSnapshotSource`; here — the side
//      that owns the `RunCoordinator` — we project the coordinator's live
//      getters onto a `QueueSnapshot` for the health endpoint, and hand
//      `BootedBrain.shutdown` as the teardown.
//   3. Stand the access process up. `startBrainAccessProcess` composes the
//      admission core over the dispatcher and binds the OpenAI + `/healthz`
//      socket on a local port through an injected serve seam.
//
// ── Why the serve seam binds the port, not `AccessConfig.openAiPort` ──
//
// `AccessConfig` validates `openAiPort > 0`, so it cannot carry the ephemeral
// port `0`. The smoke binds an OS-assigned port by default (no fixed-port
// flakiness), so the harness injects a serve seam that binds [port] directly
// (0 ⇒ ephemeral) and leaves `AccessConfig.openAiPort` as a satisfy-validation
// placeholder. The real bound port is read back from [SmokeProcess.port].

import 'dart:io';
import 'dart:isolate';

import 'package:tom_brain_access/tom_brain_access.dart'
    show
        AccessConfig,
        AnchorPolicy,
        BrainAccessProcess,
        DailyQuotaPolicy,
        IdentityBinding,
        KindHintClassifier,
        KindHintEmbedder,
        ProvisionedBrain,
        QueueSnapshot,
        RateLimitPolicy,
        TelegramChatApiFactory,
        defaultTelegramChatApiFactory,
        serveWithShelfIo,
        startBrainAccessProcess;
import 'package:tom_brain_memory/tom_brain_memory.dart'
    show MemoryConfig, TomBrainMemory, TomBrainMemoryClient;
import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show
        BrainProcessBoot,
        BrainProcessConfig,
        ClassifyFallback,
        MemoryProvisioningConfig;

import 'smoke_memory.dart';
import 'smoke_substrate.dart';

/// A booted, running smoke process plus its in-process stub substrate (E.46).
///
/// Returned by [standUpSmokeProcess]. [process] is the live access process (the
/// bound socket + the graceful teardown); [substrate] is the in-process stub a
/// later E.10 step configures before driving a run. Call [stop] once when
/// finished — it tears the access process and the booted cognition (including
/// the memory isolate) down in order.
final class SmokeProcess {
  /// The live access process — the bound OpenAI + `/healthz` socket.
  final BrainAccessProcess process;

  /// The in-process stub substrate the boot bound the engine against. Exposed
  /// so a later smoke step can set [SmokeSubstrate.answerChunks] before a run.
  final SmokeSubstrate substrate;

  /// The host-side handle to the in-isolate memory client; `null` on the
  /// in-process transport. Read through the [memory] accessor, which guards the
  /// transport.
  final TomBrainMemoryClient? _memory;

  /// The in-process memory store the cognition was booted over; `null` on the
  /// isolate transport. Read through the [inProcessMemory] accessor, which
  /// guards the transport.
  final TomBrainMemory? _inProcessMemory;

  SmokeProcess._({
    required this.process,
    required this.substrate,
    required TomBrainMemoryClient? memory,
    required TomBrainMemory? inProcessMemory,
  })  : _memory = memory,
        _inProcessMemory = inProcessMemory;

  /// Whether the cognition was booted over the *in-process* memory transport
  /// (the E.55 path), as opposed to the default isolate transport. The two
  /// memory surfaces ([memory] / [inProcessMemory]) are mutually exclusive and
  /// switch on this flag.
  bool get isInProcess => _inProcessMemory != null;

  /// The cross-isolate marshalling memory client — the one read-back that
  /// crosses the isolate boundary (E.47), so a smoke step can read the store's
  /// post-run state through [TomBrainMemoryClient.stats].
  ///
  /// Valid only on the isolate transport. Throws a [StateError] on the
  /// in-process path ([isInProcess] is true) — read [inProcessMemory] there,
  /// since the cross-isolate client does not exist on that transport.
  TomBrainMemoryClient get memory {
    final TomBrainMemoryClient? client = _memory;
    if (client == null) {
      throw StateError(
        'SmokeProcess.memory is the isolate-transport client, but this process '
        'was booted in-process — read inProcessMemory instead.',
      );
    }
    return client;
  }

  /// The in-process memory store the cognition shares with the caller (the E.55
  /// path). The cognition and the caller hold one [TomBrainMemory] object in the
  /// host isolate, so the E.55 conformance test can stand the memory MCP server
  /// up over *this* reference and inspect the post-run graph through the MCP read
  /// tools — the cross-isolate marshalling client ([memory]) cannot back the MCP
  /// server, which forwards each tool call to a `TomBrainMemory` directly.
  ///
  /// Valid only on the in-process transport. Throws a [StateError] on the
  /// isolate path ([isInProcess] is false) — read [memory] there.
  TomBrainMemory get inProcessMemory {
    final TomBrainMemory? store = _inProcessMemory;
    if (store == null) {
      throw StateError(
        'SmokeProcess.inProcessMemory is only set on the in-process transport '
        '(standUpSmokeProcess(inProcessMemory: …)); this process was booted '
        'over the isolate transport — read memory instead.',
      );
    }
    return store;
  }

  /// The port the OpenAI + `/healthz` socket actually bound (OS-assigned when
  /// the harness requested the ephemeral port `0`).
  int get port => process.port;

  /// Tears the smoke process down: stop the access process, then the booted
  /// cognition (drain foreground, dispose the memory isolate, close the
  /// substrate). Idempotent.
  Future<void> stop() => process.stop();
}

/// Boots a whole cognition (stub substrate + in-isolate memory) and stands the
/// access process up on a local port (E.46).
///
/// [port] is the port to bind; the default `0` requests an OS-assigned
/// ephemeral port (read it back from [SmokeProcess.port]). [substrate] lets a
/// caller pass a pre-configured stub (default: a fresh [SmokeSubstrate]).
/// [systemScriptsDir] points the disk procedure store at a system-scripts
/// directory; the default (`null`) resolves the *procedure prototype's* shipped
/// `scripts/system` directory (where `answer_with_memory_v1` lives) so a run can
/// resolve the real procedure. The directory is found by resolving the
/// procedure-prototype package URI, so it works regardless of the caller's
/// working directory (the smoke runs from its own package root, not the
/// procedure prototype's).
///
/// When [telegramBotToken] is non-null the harness also stands up the Telegram
/// edge (E.49): the access process drives a long-polling `TelegramAdapter` whose
/// backend is built by [telegramChatApiFactory]. A smoke test injects a loopback
/// `ChatApi` through that factory (and holds its own reference to inject inbound
/// messages and read the sent answers back), so the Telegram channel is
/// exercised end-to-end with no Telegram network. [telegramWhitelist] is the set
/// of allowed sender ids; each becomes both a whitelist key (the adapter's edge
/// gate) and an identity binding (so a whitelisted sender resolves a principal),
/// keeping the whitelist a single source of truth. A sender outside the set is
/// declined at the edge before any `Access` is built.
///
/// When [kindHintEmbedder] and [kindHintClassifier] are both supplied the access
/// process wires the cheap kind-hint classifier (E.33) in front of the
/// dispatcher: each inbound prompt is embedded (through the E.34 in-process
/// cache that wraps [kindHintEmbedder]) and the embedding classified against the
/// procedure centroids; a confident classification attaches the result as the
/// `Access.envelope.kindHint`, which the dispatcher accepts verbatim instead of
/// running its `classify_inbound_v1` fallback. The E.50 smoke injects a counting
/// embedder + a confident classifier here to prove the repeated-prompt
/// short-circuit. Leaving either `null` disables the classifier (the dispatcher
/// classifies every request) — the default for E.46–E.49.
///
/// [classifyFallback] replaces the dispatcher's no-hint fallback
/// (`classify_inbound_v1`). The E.50 smoke injects a spy here so the test can
/// prove the fallback is never called when a confident kind-hint is attached.
/// `null` keeps the dispatcher's default fallback.
///
/// [inProcessMemory] switches the cognition off the default isolate transport
/// onto the *in-process* transport, booting it over the supplied
/// [TomBrainMemory] in the host isolate (the E.55 path). When non-null the
/// cognition and the caller share one memory object, so the caller can stand the
/// memory MCP server up over the same reference and inspect the post-run graph
/// through the MCP read tools — the cross-isolate marshalling client cannot back
/// the MCP server, which forwards each tool call to a `TomBrainMemory` directly.
/// `null` keeps the isolate transport (the default for E.46–E.54).
///
/// No real OS termination signals are watched (an empty `shutdownSignals`
/// list), so the harness owns the lifecycle entirely through [SmokeProcess.stop].
Future<SmokeProcess> standUpSmokeProcess({
  int port = 0,
  SmokeSubstrate? substrate,
  Directory? systemScriptsDir,
  String? telegramBotToken,
  Set<String> telegramWhitelist = const <String>{},
  TelegramChatApiFactory? telegramChatApiFactory,
  KindHintEmbedder? kindHintEmbedder,
  KindHintClassifier? kindHintClassifier,
  ClassifyFallback? classifyFallback,
  TomBrainMemory? inProcessMemory,
}) async {
  final SmokeSubstrate smokeSubstrate = substrate ?? SmokeSubstrate();
  final Directory scriptsDir =
      systemScriptsDir ?? await _resolveProcedurePrototypeScripts();

  // ── 1. Boot the cognition: stub substrate + memory. ──
  //
  // The default is the production isolate transport (E.46–E.54). When the
  // caller supplies an [inProcessMemory] (the E.55 path) the boot uses the
  // in-process transport instead, so the cognition and the caller share one
  // `TomBrainMemory` object the MCP server can be stood up over.
  final String memoryRoot = _uniqueSmokeMemoryRoot();
  final MemoryProvisioningConfig memoryProvisioning = inProcessMemory == null
      ? MemoryProvisioningConfig.isolate(
          factory: spawnSmokeMemory,
          memoryConfig: MemoryConfig.forTesting(root: memoryRoot),
        )
      : MemoryProvisioningConfig.inProcess(
          client: inProcessMemory,
          memoryConfig: MemoryConfig.forTesting(root: memoryRoot),
        );
  final booted = await BrainProcessBoot.boot(
    BrainProcessConfig(
      substrate: smokeSubstrate,
      memoryProvisioning: memoryProvisioning,
      systemScriptsDir: scriptsDir,
      // E.50: the dispatcher's no-hint fallback (the prototype's LLM-classifier
      // stand-in). A confident kind-hint must short-circuit it.
      classifyFallback: classifyFallback,
    ),
  );

  // ── 2. Project the booted cognition into a ProvisionedBrain. ──
  final ProvisionedBrain provisioned = ProvisionedBrain(
    dispatcher: booted.dispatcher,
    queueSnapshot: () => QueueSnapshot(
      foregroundRunning: booted.coordinator.hasForegroundRun,
      foregroundWaiting: booted.coordinator.foregroundQueueLength,
      foregroundQueueDepth: booted.coordinator.foregroundQueueDepth,
      backgroundRunning: booted.coordinator.hasBackgroundRun,
      draining: booted.coordinator.isDraining,
    ),
    shutdown: booted.shutdown,
  );

  // ── 3. Stand the access process up on the local port. ──
  final BrainAccessProcess process = await startBrainAccessProcess(
    config: _smokeAccessConfig(
      port,
      telegramBotToken: telegramBotToken,
      telegramWhitelist: telegramWhitelist,
    ),
    brain: provisioned,
    // The serve seam binds [port] directly (0 ⇒ ephemeral); `config.openAiPort`
    // is the satisfy-validation placeholder (see the file header). The Telegram
    // factory is the loopback double a smoke test injects; the CLI default
    // (the real long-polling backend) is never reached in the smoke.
    serve: (handler, _) => serveWithShelfIo(handler, port),
    telegramChatApiFactory:
        telegramChatApiFactory ?? defaultTelegramChatApiFactory,
    // E.33/E.34: the substrate + memory edges of the cheap kind-hint
    // classifier. Supplied together (or not at all) — the access boot builds
    // the classifier only when both are present, wrapping the embedder in the
    // E.34 cache.
    kindHintEmbedder: kindHintEmbedder,
    kindHintClassifier: kindHintClassifier,
    shutdownSignals: const <Stream<ProcessSignal>>[],
  );

  return SmokeProcess._(
    process: process,
    substrate: smokeSubstrate,
    // Exactly one memory surface is live per transport: the isolate path keeps
    // the marshalling client; the in-process path keeps the shared store (and
    // leaves the isolate client null, so reading the wrong surface throws).
    memory: inProcessMemory == null ? booted.memory.client : null,
    inProcessMemory: inProcessMemory,
  );
}

/// Monotonic stand-up counter, mixed into [_uniqueSmokeMemoryRoot] so two
/// stand-ups in one process never collide on a memory directory.
int _smokeRootCounter = 0;

/// A unique on-disk memory root for one [standUpSmokeProcess] call.
///
/// Two stand-ups in a single run — the E.58 bench drives several, and parallel
/// tests can overlap — must not share one on-disk directory or they interfere.
/// The root is keyed by the process id and a monotonic counter, and carries no
/// plan-step nomenclature (the phase number was harness-coupling, not state).
String _uniqueSmokeMemoryRoot() => 'ztmp/tom_brain_smoke_${pid}_'
    '${_smokeRootCounter++}';

/// Resolves the procedure prototype's shipped `scripts/system` directory.
///
/// The smoke depends on `tom_brain_procedure`, whose `scripts/system`
/// folder ships the `answer_with_memory_v1` procedure. Resolving the package
/// URI (rather than a working-directory-relative path) lets the harness find
/// those scripts no matter where the test process was launched from.
Future<Directory> _resolveProcedurePrototypeScripts() async {
  final Uri? libUri = await Isolate.resolvePackageUri(
    Uri.parse(
      'package:tom_brain_procedure/tom_brain_procedure.dart',
    ),
  );
  if (libUri == null) {
    throw StateError(
      'cannot resolve the tom_brain_procedure package URI — '
      'is it on the package config?',
    );
  }
  // libUri → <package-root>/lib/tom_brain_procedure.dart;
  // the scripts live a sibling of lib/, at <package-root>/scripts/system.
  return Directory.fromUri(libUri.resolve('../scripts/system'));
}

/// The bearer token the smoke client authenticates with. A request must carry
/// `Authorization: Bearer $smokeBearerToken` to resolve an identity — the
/// access edge resolves identity by looking the token up in the config's
/// bindings, and an unbound token is a `401` (see [IdentityResolver]).
const String smokeBearerToken = 'smoke-token';

/// An "effectively unlimited" quota figure for the smoke's rate-limit and
/// daily-quota policies — the smoke never wants to be throttled, so every cap is
/// set far above any number of requests a smoke run issues.
const int _unlimitedQuota = 1000000;

/// The satisfy-validation placeholder for `AccessConfig.openAiPort`. The harness
/// binds the real port through its injected serve seam (an OS-assigned ephemeral
/// port when [standUpSmokeProcess] is asked for `0`), but `AccessConfig`
/// validates `openAiPort > 0`, so this non-zero placeholder stands in. The real
/// bound port is read back from [SmokeProcess.port].
const int _placeholderPort = 1;

/// The permissive access config the smoke binds: one bearer binding (the
/// [smokeBearerToken] → a `smoke-user` principal, so a request resolves an
/// identity and reaches the dispatcher), no rate / quota caps, and an empty
/// anchor policy (every prompt admitted). `openAiPort` is a placeholder — the
/// harness's serve seam binds the real port.
///
/// When [telegramBotToken] is non-null the config also carries a Telegram
/// channel (E.49): `hasTelegram` becomes true so the boot stands the Telegram
/// edge up, and each [telegramWhitelist] sender id becomes a
/// `telegramUserIdBindings` entry — its key is the whitelist (the adapter's edge
/// gate) and its value the principal a whitelisted sender resolves to.
AccessConfig _smokeAccessConfig(
  int port, {
  String? telegramBotToken,
  Set<String> telegramWhitelist = const <String>{},
}) =>
    AccessConfig(
      openAiPort: port > 0 ? port : _placeholderPort,
      rateLimitPolicy: RateLimitPolicy(
        capacity: _unlimitedQuota,
        refillTokens: _unlimitedQuota.toDouble(),
        refillPeriod: const Duration(seconds: 1),
      ),
      dailyQuotaPolicy: DailyQuotaPolicy(dailyCap: _unlimitedQuota),
      anchorPolicy: AnchorPolicy(disallowedSignatures: const <String>[]),
      bearerTokenBindings: <String, IdentityBinding>{
        smokeBearerToken: IdentityBinding(principalId: 'smoke-user'),
      },
      telegramBotToken: telegramBotToken,
      telegramUserIdBindings: <String, IdentityBinding>{
        for (final String userId in telegramWhitelist)
          userId: IdentityBinding(principalId: 'tg-$userId'),
      },
    );
