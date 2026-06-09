// PT-4.1 — the live-tail controller behind the SSE endpoint (§ 4.8). It re-reads
// a per-session streaming live-trail whenever [changes] fires and emits only the
// cognitive steps appended since the last read, closing after the turn's
// `✅ DONE`. The change signal is injected — production wraps an OS file-watch
// (`liveTrailChanges`) into the same `Stream<void>`, tests drive it with a
// controllable stream — so the diffing core is deterministic and testable.
//
// Read-only is the whole point (OBS-5, § 6.2): the tail only *reads* the file on
// each tick. It installs no callback, sink, or instrumentation inside the brain
// process, and never opens the trail for writing — a live "view" is a file
// watch, not a hook.

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'live_trail_steps.dart';

/// Emits each newly-appended cognitive step of [turnId] in [file] as [changes]
/// fires, in order, then closes once the turn's `✅ DONE` step is reached (or
/// when the listener cancels). The initial read on subscription replays the
/// steps already present, so a late subscriber still sees the whole turn.
///
/// [file] need not exist yet; a missing file simply yields nothing until it is
/// created and a change fires. The returned stream is single-subscription.
Stream<LiveTrailStep> tailTurnSteps({
  required File file,
  required String turnId,
  required Stream<void> changes,
}) {
  final controller = StreamController<LiveTrailStep>();
  StreamSubscription<void>? sub;
  var emitted = 0;
  var finished = false;

  void pump() {
    if (finished) return;
    final content = file.existsSync() ? file.readAsStringSync() : '';
    final steps = parseTurnSteps(content, turnId);
    for (var i = emitted; i < steps.length; i++) {
      final step = steps[i];
      controller.add(step);
      if (step.isDone) {
        finished = true;
        emitted = i + 1;
        controller.close();
        return;
      }
    }
    emitted = steps.length;
  }

  controller
    ..onListen = () {
      pump(); // Replay whatever is already written.
      if (!finished) sub = changes.listen((_) => pump());
    }
    ..onCancel = () async {
      await sub?.cancel();
      sub = null;
    };
  return controller.stream;
}

/// A read-only `Stream<void>` that fires when [file] may have changed — an OS
/// file-watch over the parent directory (the file may be created/rotated)
/// filtered to [file]'s path. The brain rewrites the trail per step, so each
/// append surfaces as a modify event. Pure observation: it opens nothing for
/// writing, and cancelling the subscription tears the OS watch down (OBS-5).
Stream<void> liveTrailChanges(File file) {
  final dir = file.parent;
  if (!dir.existsSync()) return const Stream<void>.empty();
  return dir
      .watch(events: FileSystemEvent.modify | FileSystemEvent.create)
      .where((event) => p.equals(event.path, file.path))
      .map((_) {});
}
