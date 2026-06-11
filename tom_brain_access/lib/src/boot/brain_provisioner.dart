// BrainProvisioner — the seam that boots the cognition the access process
// serves over (E.45; proto spec § 11 / § 12).
//
// ── Why a seam, not a direct `BrainProcessBoot.boot` call ────────────
//
// The proto spec § 12 bring-up sequence is *substrate → memory → engine +
// dispatcher → access layer*. The access process (E.45) is the thing that
// ties that whole sequence to live channels. But the access package must
// not depend on `tom_brain_memory` / `tom_brain_substrate` (pubspec
// § "Explicitly NOT here"; `dependency_surface_test.dart`), and
// `BrainProcessBoot.boot` takes a `BrainProcessConfig` whose `substrate`
// field is a required `TomBrainSubstrateClient` — a forbidden type. So the
// access package *cannot* call `BrainProcessBoot.boot` itself: doing so
// would force a substrate import.
//
// The resolution is the same anti-dependency discipline E.16
// (`EmbeddingSource`), E.33 (the classifier seams), E.42 (`ShutdownAction`),
// and E.43 (`QueueSnapshotSource`) already use: the access process takes the
// booted cognition through a [BrainProvisioner] *function* seam. A higher
// assembly (Tom Assistant integration, or a test) — the side that may
// legally import substrate + memory — boots `BrainProcessBoot`, projects its
// `RunCoordinator` onto the [QueueSnapshot], and hands back a
// [ProvisionedBrain] (the `Dispatcher`, the queue-snapshot closure, and a
// teardown). The access process never sees a substrate or memory type; it
// drives only the `Dispatcher` and the two closures.
//
// ── The default provisioner ──────────────────────────────────────────
//
// Because the access package cannot provision the brain on its own, the CLI
// default ([unsupportedBrainProvisioner]) throws [BrainProvisioningException]
// with a message that names the missing wiring. The standalone
// `tom_brain_access` binary is therefore the *running-process
// shape* — it parses config, owns the channels, and manages shutdown — but
// it cannot actually boot a brain until a higher assembly injects a real
// provisioner. This is the honest expression of the dependency boundary, and
// it is logged in the questions doc (Q-E.45.1).

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show Dispatcher;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show TomBrainMemoryClient;

import '../config/access_config.dart';
import 'health_check.dart';

/// Boots the cognition the access process serves over, from the access
/// [AccessConfig] (E.45).
///
/// The single seam through which the access process reaches a booted
/// `Dispatcher` without importing `tom_brain_substrate` / `tom_brain_memory`.
/// A higher assembly (or a test) implements it: it boots `BrainProcessBoot`
/// (which *does* import substrate + memory), projects the resulting
/// `RunCoordinator` onto a [QueueSnapshot], and returns a [ProvisionedBrain].
/// The default ([unsupportedBrainProvisioner]) refuses, because the access
/// package itself cannot legally boot the brain.
typedef BrainProvisioner = Future<ProvisionedBrain> Function(
  AccessConfig config,
);

/// A booted cognition handed to the access process by a [BrainProvisioner]
/// (E.45).
///
/// Carries exactly the three things the access process needs and nothing
/// from substrate / memory: the [dispatcher] every admitted `Access` lands
/// on, the [queueSnapshot] closure the health endpoint reads, and the
/// [shutdown] that tears the booted cognition down (the running process
/// invokes it last, after stopping the channels and the access layer).
final class ProvisionedBrain {
  /// The booted dispatcher — the single `accept(Access)` entry point the
  /// access assembler dispatches every admitted request to.
  final Dispatcher dispatcher;

  /// Reads the live coordinator state into a [QueueSnapshot] for the health
  /// endpoint (E.43). The provisioner owns the projection because only it
  /// holds the `RunCoordinator`; the access process holds only this closure.
  final QueueSnapshotSource queueSnapshot;

  /// Tears the booted cognition down (drain foreground, dispose memory, close
  /// substrate). The running process calls it once, after the channels and
  /// the access layer have stopped, so no new work arrives mid-teardown.
  final Future<void> Function() shutdown;

  /// The booted memory's read surface — a `tom_brain_shared` type (an allowed
  /// dependency), so surfacing it here does *not* pull `tom_brain_memory` into
  /// the access package. A higher assembly (`tom_brain_run`) sets it from the
  /// booted memory client so the running process can build the Telegram
  /// `/memory_status` inspector over it; `null` when the provisioner does not
  /// expose memory (the standalone serve path).
  final TomBrainMemoryClient? memoryClient;

  /// Builds a provisioned-brain handle.
  const ProvisionedBrain({
    required this.dispatcher,
    required this.queueSnapshot,
    required this.shutdown,
    this.memoryClient,
  });
}

/// Raised when no usable [BrainProvisioner] is wired (E.45).
///
/// The default CLI provisioner ([unsupportedBrainProvisioner]) throws this:
/// the access package cannot import substrate / memory, so it cannot boot a
/// brain on its own. A higher assembly must inject a real provisioner.
final class BrainProvisioningException implements Exception {
  /// What is missing, and who must supply it.
  final String message;

  /// Builds the exception over [message].
  const BrainProvisioningException(this.message);

  @override
  String toString() => 'BrainProvisioningException: $message';
}

/// The default [BrainProvisioner]: refuse, because the access package cannot
/// legally boot the brain itself (E.45; Q-E.45.1).
///
/// Throws [BrainProvisioningException]. The standalone binary uses this, so a
/// bare `serve` invocation reports — clearly and without crashing the tool
/// framework — that a real provisioner must be injected by a higher assembly.
/// Tests inject a stub provisioner over a stub `Dispatcher` to exercise the
/// full serve path.
Future<ProvisionedBrain> unsupportedBrainProvisioner(
  AccessConfig config,
) async {
  throw const BrainProvisioningException(
    'No BrainProvisioner is wired. The access package cannot import '
    'tom_brain_substrate / tom_brain_memory, so it cannot boot the brain '
    'on its own. A higher assembly (Tom Assistant integration, or a test) '
    'must supply a BrainProvisioner that boots BrainProcessBoot and projects '
    'its RunCoordinator onto the QueueSnapshot.',
  );
}
