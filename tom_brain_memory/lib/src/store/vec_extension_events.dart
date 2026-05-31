// `MemoryEvent` leaves owned by the sqlite-vec extension loader
// (Plan step A.50).
//
// One leaf today: `VectorIndexUnavailable` — emitted when the boot-
// time vec0 load resolves to anything other than `loaded`. The wiring
// helper in `vec_extension_loader.dart` (`loadVecExtensionWithFailOpen`)
// emits this event onto the memory event sink before returning the
// degraded-mode result; the loader class itself is event-free.
//
// Per the file-header convention on `MemoryEvent`, success-only
// emission is the rule: the loader does *not* emit anything on the
// `loaded` branch. Vector mode being available is the expected
// happy path; surfacing it as an event would spam every healthy
// boot. Operators see `loaded` in the loader's return value (and,
// by extension, in `memory.stats()` once that field lands) — the
// event stream is reserved for transitions that warrant attention.
//
// The kebab-case discriminator is `memory.vector-index-unavailable`,
// following the `memory.<event-name>` pattern established by
// `NodePersisted`, `NodeDemoted`, `NodeForgotten`, `EdgeCreated`,
// `EdgeRejected`.

import '../api/memory_event.dart';
import 'vec_extension_loader.dart';

/// Emitted when the sqlite-vec (vec0) extension cannot be loaded at
/// boot time. The brain enters BM25-only mode; vector recall is
/// disabled until the underlying cause is fixed and the process is
/// restarted.
///
/// The event carries enough context to identify the configured path,
/// the categorical reason the load was abandoned, the one-line
/// human-readable summary the loader produced, and (on the `failed`
/// branch) the originating exception. Subscribers in Tom Forge
/// surface this to the operator UI; the dispatcher's cadence driver
/// uses it to suppress vector-mode queue submissions for the rest of
/// the process lifetime.
///
/// `runId` and `causedBy` are absent: the load happens during
/// `open()`, before any procedure run exists.
final class VectorIndexUnavailable extends MemoryEvent {
  /// The configured `MemoryConfig.sqliteVec.extensionPath` at the
  /// moment of the load attempt. May be the empty string when
  /// [reason] is [VecUnavailableReason.notConfigured].
  final String extensionPath;

  /// Categorical reason the load did not reach [VecLoadOutcome.loaded].
  final VecUnavailableReason reason;

  /// One-line human-readable summary produced by the loader. Mirrors
  /// the `summary` field of [VecExtensionLoadResult]; surfaced here so
  /// log subscribers do not have to plumb the result object alongside
  /// the event.
  final String summary;

  /// `true` when the load reached [VecLoadOutcome.failed] (a hard
  /// error during open / lookup / register), `false` when it reached
  /// [VecLoadOutcome.unavailable] (the extension was simply absent or
  /// not configured). The distinction matters for the operator UI:
  /// the failed branch needs a fix (broken binary, wrong arch);
  /// the unavailable branch is a configuration choice.
  final bool wasError;

  /// Originating exception when [wasError] is `true`; `null` for the
  /// `unavailable` branch.
  final Object? cause;

  const VectorIndexUnavailable({
    required this.extensionPath,
    required this.reason,
    required this.summary,
    required this.wasError,
    required super.occurredAt,
    this.cause,
  });

  @override
  String get kind => 'memory.vector-index-unavailable';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'extensionPath': extensionPath,
        'reason': reason.name,
        'summary': summary,
        'wasError': wasError,
        if (cause != null) 'cause': cause.toString(),
      };
}
