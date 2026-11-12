// MSPP-57 — the dreaming-side live-tail behind `GET /api/dream/stream`
// (`prompt_tracing.md` § 5A.5). The dreaming analogue of `tailTurnSteps`
// (`live_tail.dart`): where the foreground live-tail tails a per-session
// streaming live-trail, this tails the active *turn-less* dream run-tree log
// under `procedures/<proc>/<runId>.log` — a pure read, no brain change (source
// option (a), MSPP-57). It re-reads the log on each [changes] tick and emits the
// run-tree operations appended since the last read, closing the stream with a
// terminal `done` frame once the run reaches a non-`unknown` outcome.
//
// One connection follows **one** run to completion. Under Hard principle 10 (at
// most one background task at a time) the newest dream run is the active one, so
// the controller locks onto `newestDreamRunLog` (within an optional lane) the
// first time one exists, replays its ops (a late subscriber still sees the run
// so far), tails subsequent appends, then closes. With no dream run yet it stays
// open and idle — never an error — adopting the next run the watch surfaces.
//
// Read-only is the whole point (OBS-5, § 6.2): the tail only *reads* on each
// tick and the watch opens nothing for writing; cancelling the subscription
// tears the OS watch down.

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tom_brain_config/tom_brain_config.dart' show CadenceSchedule;

import '../model/run_tree.dart';
import '../parse/dream_list_builder.dart';
import '../parse/run_tree_parser.dart';
import '../parse/run_tree_walk.dart';
import '../parse/trail_host.dart';

/// Emits each newly-appended run-tree operation of the active dream run for
/// [host] (optionally confined to [lane]) as [changes] fires, one frame per leaf
/// op in DFS = file-append order, then closes once the run's outcome line is
/// parsed (status leaves `unknown`). `SubRunNode`s are skipped — [allNodes]
/// yields each sub-run's descendants individually, so emitting the wrapper would
/// duplicate them. The returned stream is single-subscription.
///
/// Idle when no dream run exists yet: it emits nothing and stays open, adopting
/// the next run a tick surfaces. [schedule] selects the lane→agent map (defaults
/// to the canonical `CadenceSchedule.defaults()`), matching the rest of Module 3.
Stream<Map<String, Object?>> tailNewestDreamRun({
  required TrailHost host,
  String? lane,
  CadenceSchedule? schedule,
  required Stream<void> changes,
}) {
  final controller = StreamController<Map<String, Object?>>();
  StreamSubscription<void>? sub;
  File? current;
  var emitted = 0;
  var finished = false;

  void pump() {
    if (finished) return;
    // Lock onto the active run the first time one exists, then never switch —
    // that is what keeps "closes cleanly on run completion" unambiguous.
    current ??= newestDreamRunLog(host, lane: lane, schedule: schedule);
    final log = current;
    if (log == null || !log.existsSync()) return; // idle.

    final run = parseRunTree(log.readAsStringSync());
    if (run == null) return; // header not written yet — nothing to emit.

    final ops = <RunNode>[
      for (final node in allNodes(run))
        if (node is! SubRunNode) node,
    ];
    for (var i = emitted; i < ops.length; i++) {
      controller.add(ops[i].toJson());
    }
    emitted = ops.length;

    if (run.status != 'unknown') {
      controller.add(<String, Object?>{
        'done': true,
        'runId': run.runId,
        'procedureId': run.procedureId,
        'status': run.status,
        'elapsedMs': run.elapsedMs,
      });
      finished = true;
      controller.close();
    }
  }

  controller
    ..onListen = () {
      // Defer the initial replay off the `onListen` stack: an already-complete
      // run closes the stream on its first pump, and delivering `done`
      // synchronously inside `onListen` is dropped by a direct subscriber. A
      // tick arriving in this gap is harmless — `pump` re-reads the whole file.
      scheduleMicrotask(() {
        pump(); // Replay whatever is already written.
        if (!finished) sub = changes.listen((_) => pump());
      });
    }
    ..onCancel = () async {
      await sub?.cancel();
      sub = null;
    };
  return controller.stream;
}

/// A read-only `Stream<void>` that fires when any turn-less dream run-tree log
/// under [host]'s `procedures/` may have changed — a recursive OS watch over
/// that tree (a run's log is created then appended per step), filtered to dream
/// logs (a `.log` whose basename carries no `__`, the turn/run separator). Pure
/// observation: it opens nothing for writing, and cancelling the subscription
/// tears the OS watch down (OBS-5). Empty stream when `procedures/` is absent.
Stream<void> dreamRunChanges(TrailHost host) {
  final dir = Directory(p.join(host.root.path, 'procedures'));
  if (!dir.existsSync()) return const Stream<void>.empty();
  return dir
      .watch(
        events: FileSystemEvent.modify | FileSystemEvent.create,
        recursive: true,
      )
      .where((event) =>
          event.path.endsWith('.log') &&
          !p.basename(event.path).contains('__'))
      .map((_) {});
}
