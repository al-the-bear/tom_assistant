// Multi-machine `MemoryEvent` leaf — `AuthorityUnreachable`.
//
// Spec § 14 (multi-machine deployment) + § 15 failure table: when a
// mirror or cognitive worker loses heartbeat connectivity to the
// canonical authority, it degrades to read-only, pauses subscribed
// agents, and emits `AuthorityUnreachable`. Spec § 16 lists the event
// on the single observability stream.
//
// This leaf is **declared but not yet wired** — the multi-machine
// authority/heartbeat subsystem is build-order step 9 (quest overview)
// and does not exist in the prototype yet. The type is landed here now
// so the typed `Stream<MemoryEvent>` surface promised by spec § 16 is
// complete: an inspector or test can already match on
// `AuthorityUnreachable` before the producer ships, exactly as
// `StackOverflowDemoted` was declared at A.40 ahead of its A.42
// emission path. The emission point lands with the heartbeat monitor.
//
// The discriminator (`memory.authority-unreachable`) follows the
// per-component convention documented on `MemoryEvent`.

import '../api/memory_event.dart';

/// Emitted when a mirror / cognitive worker loses heartbeat
/// connectivity to the canonical authority (spec §§ 14–16).
///
/// Carries the identity of the authority that went silent, the local
/// role that detected the loss, and how long the heartbeat has been
/// overdue. The emitting node degrades to read-only and pauses its
/// subscribed agents on the same transition; this event is the
/// observable signal of that degrade.
///
/// **Not yet emitted in the prototype** — see file header. The fields
/// are the contract the heartbeat monitor (build step 9) will fill.
final class AuthorityUnreachable extends MemoryEvent {
  /// Stable identifier of the canonical authority that stopped
  /// answering heartbeats (e.g. the Big-Beast node id / endpoint).
  final String authorityId;

  /// The local node's role at the moment connectivity was lost
  /// (e.g. `'mirror'`, `'cognitive-worker'`). Free-form for now; the
  /// heartbeat subsystem will pin the vocabulary when it lands.
  final String localRole;

  /// How long the authority's heartbeat has been overdue, in
  /// milliseconds, at the moment the loss was declared.
  final int overdueMs;

  const AuthorityUnreachable({
    required this.authorityId,
    required this.localRole,
    required this.overdueMs,
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'memory.authority-unreachable';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'authorityId': authorityId,
        'localRole': localRole,
        'overdueMs': overdueMs,
      };
}
