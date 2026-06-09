// MemoryAccessRecord — one bridged memory call enriched with the
// run-correlation the engine knows (`tom_brain_logging.md` §5.6 / §10 step #8).
//
// Every memory primitive a run issues (`recall`, `persist`, `edge`,
// `stackPush`, …) is dispatched through the per-run [MemoryBridge], which
// reports the completed call (name, argument map, result map, wall-clock
// cost). The §5.6 per-profile memory log additionally wants the *run* facts:
// the `runId`, the live `trailId` the recorder opened, the `turnId` the run
// serves, and the memory `profile` the request ran under. Those belong to the
// run, not the bridge, so the engine wraps each reported memory call into this
// record before handing it to the run's [MemoryAccessSink].
//
// `profile` / `turnId` are `null` for a turn-less invocation (an internal /
// free-time / dream run that carries no user turn and runs against the process
// default profile); the writer renders whatever is present (a `null` profile
// buckets as `memory/default.log`).

/// One completed bridged-memory call, ready for the §5.6 per-profile memory-log
/// writer: the bridge's primitive call plus the run-correlation the engine
/// supplies.
final class MemoryAccessRecord {
  /// The bridge method name (`recall`, `persist`, `edge`, `stackPush`, …).
  final String primitive;

  /// The call's JSON-encodable argument map (e.g. `{text, modes, k}` for
  /// `recall`, `{typeName, values}` for `persist`).
  final Map<String, Object?> input;

  /// The call's JSON-encodable result map (e.g. `{nodes, report}` for
  /// `recall`, `{id}` for an id-returning write, `{}` for a void call).
  final Map<String, Object?> result;

  /// The measured wall-clock cost of the delegated call, when the bridge
  /// timed it; `null` otherwise.
  final int? elapsedMs;

  /// The memory profile the request ran under, or `null` for a turn-less /
  /// process-default run (logged as `default`).
  final String? profile;

  /// The run that issued the call. `null` only if the engine could not
  /// resolve it (it always can for a real run).
  final String? runId;

  /// The run's trail id (`TrailId.value`), or `null` if the run's trail was
  /// not open when the call fired.
  final String? trailId;

  /// The turn this access served (`TurnId.value`), or `null` for a turn-less
  /// invocation.
  final String? turnId;

  /// When the call completed (engine clock, UTC). The §5.6 link's date shard
  /// is derived from this.
  final DateTime at;

  const MemoryAccessRecord({
    required this.primitive,
    required this.input,
    required this.result,
    required this.at,
    this.elapsedMs,
    this.profile,
    this.runId,
    this.trailId,
    this.turnId,
  });
}

/// The engine-level sink one [MemoryAccessRecord] is handed to per completed
/// memory call (`tom_brain_logging.md` §10 step #8). Bound by the host to a
/// `MemoryProfileLogWriter`; `null` leaves the engine emitting no per-profile
/// memory log. Best-effort and non-blocking (logging-spec §9).
typedef MemoryAccessSink = void Function(MemoryAccessRecord record);
