// `HistoryEvent` sealed sum — the history subsystem's typed observability
// stream (Extension G step 25;
// `tom_brain_procedure_specification.md` § 22.10; access § 14).
//
// One variant per documented history failure row, so a consumer (the trail
// writer, a Forge inspector, a metrics scraper) can branch on the failure with
// an exhaustive switch rather than parse note strings:
//
//   - `HistoryCompactionFailed`     — a `compact_history_v1` run threw; the
//                                     prior summary is kept and `pending` is
//                                     NOT cleared (retried next turn). Never
//                                     silent data loss (§ 22.10).
//   - `HistoryCompactionTruncated`  — an over-long summary was hard-truncated
//                                     to the char bound after one re-run.
//   - `HistorySessionUnknown`       — an echoed session id resolved to no
//                                     session; fell through to the default
//                                     session + a fresh id (not an error).
//   - `HistoryWireMalformed`        — a `messages[]` / `tools[]` / tool-result
//                                     entry of the wrong shape was dropped; the
//                                     live prompt still parsed.
//   - `HistoryRemoteToolNoSession`  — a remote-tool proposal with no session
//                                     still returned the call + minted an id.
//
// The `kind` discriminators are the canonical failure codes from the § 22.10 /
// access § 14 tables verbatim — the two compaction codes already exist as
// `TrailNote` categories (`history_compactor.dart`), so the event kind and the
// note category line up. The access-edge codes carry the `access.` prefix
// because they are detected at the wire / session boundary (access § 14).
//
// ── Emission lands where each runtime triggers it ──────────────────
//
// Step 25 owns the *taxonomy*. The compaction variants are emitted by the
// engine-side `HistoryCompactor` (G.21); the three access-edge variants are
// emitted by the access layer's wire parse + session resolve + remote-tool
// loop (the loop is built in the paused steps 11–12 / the access-prototype
// remote-tool steps). Exactly like step 16 deferred `LlmLoopEvent` emission to
// the `call_llm_v1` loop, the surface is defined here and the emission rides
// with each runtime as it lands. The `HistoryEventBus` (`history_event_bus.dart`)
// is the broadcast fan-in the composition root wires in.
//
// Unlike `LlmLoopEvent`, `runId` is NOT narrowed: two of the five failures are
// detected before any run id exists (the access-edge wire parse and session
// resolve), so the base's optional `runId` is correct here.

import 'package:tom_brain_shared/tom_brain_shared.dart' show BrainEvent;

/// Sink a history runtime calls with each [HistoryEvent] it emits.
///
/// Wired by the composition root to a `HistoryEventBus` (`bus.emit`). `null`
/// disables emission.
typedef HistoryEventSink = void Function(HistoryEvent event);

/// Marker / base for every typed history-subsystem observability event.
///
/// A consumer subscribed to `HistoryEventBus.events()` sees only subtypes of
/// this class. Exhaustive `switch` over the closed five-variant taxonomy
/// (§ 22.10) is the recommended branch surface. `runId` stays optional (the
/// base default) — the access-edge variants are emitted outside any run.
sealed class HistoryEvent extends BrainEvent {
  /// Builds the base of a history event.
  const HistoryEvent({
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });
}

/// A `compact_history_v1` run threw (§ 22.10): the prior `compactedSummary` is
/// kept and `pending` is not cleared (retried next turn) — never silent loss.
final class HistoryCompactionFailed extends HistoryEvent {
  /// The number of `pending` turns kept for retry.
  final int pendingKept;

  const HistoryCompactionFailed({
    required super.occurredAt,
    super.runId,
    super.causedBy,
    required this.pendingKept,
  });

  @override
  String get kind => 'history.compaction.failed';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'pendingKept': pendingKept,
      };
}

/// An over-long compacted summary was hard-truncated to the char bound after
/// the single tightened re-run (§ 22.4 / § 22.10).
final class HistoryCompactionTruncated extends HistoryEvent {
  /// The char bound the summary was truncated to.
  final int bound;

  /// The length of the over-long summary before truncation.
  final int producedChars;

  const HistoryCompactionTruncated({
    required super.occurredAt,
    super.runId,
    super.causedBy,
    required this.bound,
    required this.producedChars,
  });

  @override
  String get kind => 'history.compaction.truncated';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'bound': bound,
        'producedChars': producedChars,
      };
}

/// An echoed session id resolved to no session (§ 22.10 / access § 14): not an
/// error — the resolve falls through to the default session and mints a fresh
/// id (the global history still applies).
final class HistorySessionUnknown extends HistoryEvent {
  /// The unrecognised session id the client echoed, or `null` when absent.
  final String? requestedSessionId;

  /// The fresh session id minted for the continuation.
  final String mintedSessionId;

  const HistorySessionUnknown({
    required super.occurredAt,
    super.runId,
    super.causedBy,
    this.requestedSessionId,
    required this.mintedSessionId,
  });

  @override
  String get kind => 'access.session.unknown';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        if (requestedSessionId != null) 'requestedSessionId': requestedSessionId,
        'mintedSessionId': mintedSessionId,
      };
}

/// A `messages[]` / `tools[]` / tool-result entry of the wrong shape was
/// dropped at the wire boundary (access § 14): the live prompt still parsed, so
/// the request is not rejected — the bad entry is logged + skipped.
final class HistoryWireMalformed extends HistoryEvent {
  /// The channel whose adapter parsed the request (e.g. `openai`).
  final String channel;

  /// A short human-readable description of the malformed entry.
  final String detail;

  const HistoryWireMalformed({
    required super.occurredAt,
    super.runId,
    super.causedBy,
    required this.channel,
    required this.detail,
  });

  @override
  String get kind => 'access.wire.history.malformed';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'channel': channel,
        'detail': detail,
      };
}

/// A remote-tool proposal with no session in play (§ 22.8 / access § 14): the
/// loop still returns the proposed call and mints a session id so the client
/// can continue — informational, never a crash.
final class HistoryRemoteToolNoSession extends HistoryEvent {
  /// The fresh session id minted so the client can continue the tool round.
  final String mintedSessionId;

  const HistoryRemoteToolNoSession({
    required super.occurredAt,
    super.runId,
    super.causedBy,
    required this.mintedSessionId,
  });

  @override
  String get kind => 'access.remote_tool.no_session';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'mintedSessionId': mintedSessionId,
      };
}
