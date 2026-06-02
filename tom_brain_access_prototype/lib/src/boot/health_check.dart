// HealthCheck — the `GET /healthz` liveness endpoint for the running access
// process (E.43; proto spec § 11.3 / § 13.2).
//
// Plan step E.43 (verbatim): "Implement health check `GET /healthz` returning
// `{ status: "ok", uptime_s: N, queues: {…} }`."
//
// ── What E.43 owns ───────────────────────────────────────────────────
//
// The endpoint that lets a load balancer / supervisor read the running
// process's liveness at a glance: a `shelf` handler for `GET /healthz` that
// renders `{ status, uptime_s, queues }`. `status` is `ok` while the process
// serves and `draining` once a graceful shutdown (E.42) has begun; `uptime_s`
// is whole seconds since this `HealthCheck` was constructed (process start, at
// boot E.45); `queues` is the live dispatcher-coordinator snapshot — which
// run slots are busy and how deep the foreground FIFO queue currently is.
//
// ── Why the queue data arrives through an injected seam ──────────────
//
// Spec § 11.3 says "the queue summary reads the dispatcher's coordinator
// state", but the access layer only ever holds a `Dispatcher`, whose single
// surface is `accept(Access)` — it exposes no coordinator and no queue
// getters, and the access package must not reach past it into the engine /
// memory (the same anti-dependency discipline E.16 / E.33 / E.42 follow). So
// E.43 takes the snapshot through a [QueueSnapshotSource] function seam, in
// exactly the spirit of E.42's [ShutdownAction]: the running process (E.45,
// which owns the `RunCoordinator` via `BrainProcessBoot`) supplies a closure
// that reads `coordinator.hasForegroundRun` / `foregroundQueueLength` / … into
// a [QueueSnapshot]; a test supplies a probe. The handler never constructs a
// coordinator and depends on no boot type.
//
// ── What E.43 is NOT ─────────────────────────────────────────────────
//
// E.43 does not bind a socket or run a serve loop — like the OpenAI adapter
// (E.11), it exposes a mountable `shelf` handler; the boot root that mounts it
// alongside the `/v1/` routes on a live port is E.45. It loads no config
// (E.44) and does not itself drive shutdown (E.42 owns that; this endpoint
// merely *reports* that draining has begun, via the snapshot's `draining`
// flag).

import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

/// A point-in-time read of the dispatcher coordinator's run-slot + queue state
/// (E.43), the `queues` payload of the health body.
///
/// The access layer cannot read the `RunCoordinator` directly (it holds only a
/// `Dispatcher`), so the running process (E.45) projects the coordinator's live
/// getters onto this value through the [QueueSnapshotSource] seam:
/// [foregroundRunning] ← `hasForegroundRun`, [foregroundWaiting] ←
/// `foregroundQueueLength`, [foregroundQueueDepth] ← `foregroundQueueDepth`,
/// [backgroundRunning] ← `hasBackgroundRun`, [draining] ← `isDraining`.
final class QueueSnapshot {
  /// Builds a coordinator snapshot. All fields are required: a partial
  /// snapshot would render a misleading health body.
  const QueueSnapshot({
    required this.foregroundRunning,
    required this.foregroundWaiting,
    required this.foregroundQueueDepth,
    required this.backgroundRunning,
    required this.draining,
  });

  /// Whether a foreground run (an inbound user prompt) currently occupies the
  /// single foreground slot.
  final bool foregroundRunning;

  /// How many foreground runs are waiting in the FIFO queue behind the running
  /// one (excludes the run occupying the slot).
  final int foregroundWaiting;

  /// The configured maximum depth of the foreground FIFO queue — the most
  /// foreground runs that may wait behind the running one before a submission
  /// overflows.
  final int foregroundQueueDepth;

  /// Whether a background run (scheduler-driven free-time work) currently
  /// occupies the single background slot.
  final bool backgroundRunning;

  /// Whether the coordinator is draining for shutdown (E.42 in flight) and so
  /// admits no new work.
  final bool draining;

  /// Renders the snapshot as the `queues` JSON object of the health body.
  Map<String, Object?> toJson() => <String, Object?>{
        'foreground': <String, Object?>{
          'running': foregroundRunning,
          'waiting': foregroundWaiting,
          'depth': foregroundQueueDepth,
        },
        'background': <String, Object?>{
          'running': backgroundRunning,
        },
        'draining': draining,
      };
}

/// Reads the current dispatcher-coordinator state into a [QueueSnapshot]
/// (E.43).
///
/// The seam between the health endpoint (which owns the wire shape) and the
/// running process (E.45), which holds the `RunCoordinator` and projects its
/// live getters onto a snapshot. Keeping it a function — not a coordinator
/// reference — is what keeps the access package free of any reach past the
/// `Dispatcher`. A test supplies a probe.
typedef QueueSnapshotSource = QueueSnapshot Function();

/// The `GET /healthz` liveness endpoint (E.43; proto spec § 11.3).
///
/// Construct one per running process at boot (E.45); [handler] is the
/// mountable `shelf` handler the boot root mounts alongside the `/v1/` routes.
/// The body is `{ status, uptime_s, queues }`: `status` is [statusOk] while
/// the process serves and [statusDraining] once a graceful shutdown has begun;
/// `uptime_s` is whole seconds since construction; `queues` is the live
/// coordinator snapshot read through [QueueSnapshotSource].
class HealthCheck {
  /// The health endpoint path. Lives at the process root, *not* under the
  /// OpenAI `/v1/` base path — it reports on the whole process, not the model
  /// API.
  static const String path = '/healthz';

  /// The `status` value while the process is serving normally.
  static const String statusOk = 'ok';

  /// The `status` value once a graceful shutdown (E.42) has begun and the
  /// coordinator is draining. A supervisor reads this to stop routing new
  /// traffic to a process that is winding down.
  static const String statusDraining = 'draining';

  /// JSON media type for the health response.
  static const String _jsonContentType = 'application/json; charset=utf-8';

  final QueueSnapshotSource _queueSnapshot;
  final DateTime Function() _clock;
  final DateTime _startedAt;

  /// Builds the health endpoint.
  ///
  /// [queueSnapshot] reads the live coordinator state (the running process
  /// wires it to its `RunCoordinator`; a test passes a probe). [clock] stamps
  /// uptime; it defaults to [DateTime.now] and is captured *now* as the process
  /// start instant, so `uptime_s` measures from construction.
  factory HealthCheck({
    required QueueSnapshotSource queueSnapshot,
    DateTime Function()? clock,
  }) =>
      HealthCheck._(queueSnapshot, clock ?? DateTime.now);

  HealthCheck._(this._queueSnapshot, DateTime Function() clock)
      : _clock = clock,
        _startedAt = clock().toUtc();

  late final Router _router = _buildRouter();

  /// The mountable `shelf` handler. The boot root (E.45) mounts this on the
  /// live port; a test calls it directly with a synthesised [Request] — no
  /// socket. `Router` is itself a [Handler].
  Handler get handler => _router.call;

  /// Whole seconds since the process started (construction time). Clamped at
  /// zero so a non-monotonic injected clock can never report a negative uptime.
  int get uptimeSeconds {
    final int seconds = _clock().toUtc().difference(_startedAt).inSeconds;
    return seconds < 0 ? 0 : seconds;
  }

  /// The current health body: `{ status, uptime_s, queues }`. Reads the live
  /// coordinator snapshot, so `status` reflects draining and `queues` reflects
  /// the slots / queue at the moment of the call.
  Map<String, Object?> currentBody() {
    final QueueSnapshot snapshot = _queueSnapshot();
    return <String, Object?>{
      'status': snapshot.draining ? statusDraining : statusOk,
      'uptime_s': uptimeSeconds,
      'queues': snapshot.toJson(),
    };
  }

  Router _buildRouter() {
    final Router router = Router();
    router.get(path, _handleHealthz);
    return router;
  }

  /// `GET /healthz` → `200` with the JSON health body.
  Response _handleHealthz(Request request) {
    return Response.ok(
      jsonEncode(currentBody()),
      headers: <String, String>{'content-type': _jsonContentType},
    );
  }
}
