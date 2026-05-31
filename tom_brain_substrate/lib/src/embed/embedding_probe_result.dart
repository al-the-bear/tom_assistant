// B.27 — `EmbeddingProbeResult`.
//
// Return type for [EmbeddingService.probeIdentity]. Bundles the
// validated current identity, the probe vector the backend produced
// (callers may discard), and — when the caller supplied a previously
// stored identity that differs from the current one — the typed
// `EmbeddingIdentityChanged` event that records the drift.
//
// Why a separate value type rather than just returning the event:
//
//   - The probe is a boot-time *validator* as well as a drift
//     detector. Even when no drift event fires, the probe's
//     dimension-check is load-bearing: it surfaces
//     `EmbeddingDimensionMismatch` before the first real `embed`
//     call. The result records "validation passed" as the presence
//     of [probeResult]; an "all green" probe returns
//     `(currentIdentity, probeResult, driftEvent: null)`.
//   - Memory's consumer side asks two questions on boot: "did the
//     identity drift since the last open?" and "is the backend
//     functional?". Splitting the result lets memory branch on the
//     first independently from the second (drift ⇒ stamp new
//     identity on subsequent rows; backend defect ⇒ refuse to open
//     the vector store).
//   - The drift event carries `occurredAt`; bundling it into a value
//     type rather than emitting it on a stream keeps the substrate's
//     event-bus layering intact (the facade at B.40+ pushes the
//     event onto `TomBrainSubstrateClient.events()` when the probe
//     surfaces one). The embedding service itself does not own an
//     event stream — that would be a parallel observability seam.
//
// What this type deliberately does NOT carry:
//
//   - A "force-refresh" flag. The probe is read-only; a caller that
//     wants to force a new identity reconstructs the service.
//   - The backend's probe input. The probe text is a service-level
//     constant (or constructor-bound seed); echoing it back would
//     just expand log volume.
//   - A timestamp for the validation. Trail consumers timestamp the
//     event they emit; duplicating it on the value type would invite
//     drift between the validation time and the event time.

import '../api/embedding_result.dart' show EmbeddingModelIdentity, EmbeddingResult;
import '../api/substrate_event.dart' show EmbeddingIdentityChanged;

/// Result of an [EmbeddingService.probeIdentity] call.
///
/// One probe call returns one [EmbeddingProbeResult]. The result is
/// always populated with [currentIdentity] and [probeResult]; the
/// [driftEvent] is non-null iff the caller supplied a non-null
/// `previousIdentity` to `probeIdentity` AND that identity does not
/// equal [currentIdentity].
///
/// Equality is structural over all three fields; intended for tests
/// that pin the value contract.
final class EmbeddingProbeResult {
  /// The current substrate identity. Equal to
  /// [EmbeddingService.currentModelIdentity] at probe time; recorded
  /// on the result so callers do not have to re-query the service.
  final EmbeddingModelIdentity currentIdentity;

  /// The embedding the backend produced for the probe text. Carries
  /// the same identity as [currentIdentity]. Callers may discard the
  /// vector — its diagnostic value is mostly in the dimension and
  /// the fact that the call succeeded. A future drift-detection
  /// upgrade (Q-B.3.5) will use the probe vector itself: cosine
  /// against a previously-stored probe vector under the same identity
  /// would surface a silent weight swap that the `(providerId,
  /// modelId)` tuple cannot catch.
  final EmbeddingResult probeResult;

  /// Non-null iff the probe's caller supplied a `previousIdentity`
  /// that differs from [currentIdentity]. Trail consumers emit this
  /// on the substrate event bus when present; memory records the
  /// new identity in its per-vector marker for subsequent writes.
  ///
  /// Identity equality is structural ([EmbeddingModelIdentity] has
  /// value-based `==`): two identities compare equal iff all four
  /// fields (`providerId`, `modelId`, `dims`, `normalized`) match.
  final EmbeddingIdentityChanged? driftEvent;

  const EmbeddingProbeResult({
    required this.currentIdentity,
    required this.probeResult,
    this.driftEvent,
  });

  /// `true` when the probe detected an identity drift relative to the
  /// caller-supplied previous identity. Equivalent to
  /// `driftEvent != null` — exposed as a getter so consumer-side
  /// branches read as intent (`if (result.driftDetected) ...`)
  /// rather than as a null check.
  bool get driftDetected => driftEvent != null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is EmbeddingProbeResult &&
          other.currentIdentity == currentIdentity &&
          other.probeResult.vec == probeResult.vec &&
          other.probeResult.modelIdentity == probeResult.modelIdentity &&
          _driftEventEqual(other.driftEvent, driftEvent));

  @override
  int get hashCode => Object.hash(
        currentIdentity,
        probeResult.vec,
        probeResult.modelIdentity,
        driftEvent == null
            ? null
            : Object.hash(driftEvent!.fromIdentity, driftEvent!.toIdentity),
      );

  @override
  String toString() => 'EmbeddingProbeResult('
      'currentIdentity=$currentIdentity, '
      'driftDetected=$driftDetected'
      ')';

  /// Drift-event equality is structural over `(fromIdentity,
  /// toIdentity)` only. `occurredAt` and `runId` are observability
  /// metadata that move freely between probe calls; including them in
  /// equality would break any test that compares two results created
  /// at different instants.
  static bool _driftEventEqual(
    EmbeddingIdentityChanged? a,
    EmbeddingIdentityChanged? b,
  ) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    return a.fromIdentity == b.fromIdentity && a.toIdentity == b.toIdentity;
  }
}
