// MSPP-57 (unit) — the dream live-tail controller (`prompt_tracing.md` § 5A.5).
// `tailNewestDreamRun` re-reads the active turn-less dream run-tree log on each
// injected change tick and emits only the run-tree operations appended since the
// last read — one frame per leaf op (`SubRunNode`s are skipped; `allNodes` yields
// their descendants individually) — closing the stream with a terminal `done`
// frame once the run reaches a non-`unknown` outcome. The change signal is
// injected so the test is deterministic (production wraps an OS file-watch,
// `dreamRunChanges`, into the same `Stream<void>`). Asserts: idle until a run
// appears, one frame per appended op, replay on late subscribe, clean close on
// the outcome, and OBS-5 (the tail never writes the trail).

import 'dart:async';
import 'dart:io';

import 'package:tom_brain_observatory/src/live/dream_tail.dart';
import 'package:tom_brain_observatory/src/parse/trail_host.dart';
import 'package:test/test.dart';

const _header =
    'procedure dream_extract_v1  run run_test_0\n';
const _recall = '├─ recall (semantic+lexical k=8 → 3: n_a, n_b, n_c)\n';
const _llm =
    '├─ llm extractor → 512→128 tok  → ../../llm/extractor/run_test_0__01.raw.json\n';
const _persist = '├─ persist → n_fixtureX1\n';
const _outcome = '└─ outcome accepted (entries=4, 3.2s)\n';

void main() {
  late Directory tmp;
  late Directory procDir;
  late File log;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dream_tail_test_');
    // The host is "configured" (has a procedures/ tree) but starts with no
    // dream run — the idle case the stream must tolerate.
    Directory('${tmp.path}/procedures').createSync();
    procDir = Directory('${tmp.path}/procedures/dream_extract_v1');
    log = File('${procDir.path}/run_test_0.log');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('idle until a run appears, one frame per appended op, closes on outcome',
      () async {
    final changes = StreamController<void>();
    final seen = <Map<String, Object?>>[];
    final done = Completer<void>();

    tailNewestDreamRun(host: TrailHost.at(tmp.path), changes: changes.stream)
        .listen((e) => seen.add(e.cast<String, Object?>()),
            onDone: done.complete);

    // No dream run yet → idle, no frames, stream stays open.
    await pumpEventQueue();
    expect(seen, isEmpty);
    expect(done.isCompleted, isFalse);

    // A run starts: header only (no ops) → still no frames.
    procDir.createSync();
    log.writeAsStringSync(_header);
    changes.add(null);
    await pumpEventQueue();
    expect(seen, isEmpty);

    // Append the recall op → exactly that frame surfaces.
    log.writeAsStringSync(_recall, mode: FileMode.append);
    changes.add(null);
    await pumpEventQueue();
    expect(seen, hasLength(1));
    expect(seen.single['kind'], 'primitive');
    expect(seen.single['primitive'], 'recall');

    // Append the llm call → one more frame, the prior one not re-emitted.
    log.writeAsStringSync(_llm, mode: FileMode.append);
    changes.add(null);
    await pumpEventQueue();
    expect(seen, hasLength(2));
    expect(seen[1]['kind'], 'llm');
    expect(seen[1]['callType'], 'extractor');

    // Append the persist + outcome → the persist op then the terminal done
    // frame, after which the stream closes cleanly.
    log.writeAsStringSync('$_persist$_outcome', mode: FileMode.append);
    changes.add(null);
    await done.future;
    expect(seen, hasLength(4));
    expect(seen[2]['primitive'], 'persist');
    expect(seen[3]['done'], isTrue);
    expect(seen[3]['runId'], 'run_test_0');
    expect(seen[3]['status'], 'accepted');

    await changes.close();
  });

  test('replays an already-complete run on a late subscribe, then closes',
      () async {
    procDir.createSync();
    log.writeAsStringSync('$_header$_recall$_llm$_persist$_outcome');

    final changes = StreamController<void>();
    final frames = <Map<String, Object?>>[];
    var closed = false;
    tailNewestDreamRun(host: TrailHost.at(tmp.path), changes: changes.stream)
        .listen((e) => frames.add(e.cast<String, Object?>()),
            onDone: () => closed = true);

    // The run is already complete: the initial replay emits every op then the
    // terminal frame, and the stream closes without any change tick. Drive the
    // event queue (as the streaming tests do) so the buffered replay + the close
    // are delivered — the real SSE consumer drives the loop the same way.
    await pumpEventQueue();
    // The tail finished on its first pump, so it never subscribed to `changes`;
    // closing a never-listened single-subscription controller never completes,
    // so fire-and-forget rather than await it (the controller is discarded with
    // the test).
    unawaited(changes.close());

    expect(closed, isTrue); // the stream closed cleanly on the outcome.
    expect(frames.map((f) => f['kind'] ?? (f['done'] == true ? 'done' : null)),
        <Object?>['primitive', 'llm', 'primitive', 'done']);
  });

  test('OBS-5: tailing never writes the dream log', () async {
    procDir.createSync();
    log.writeAsStringSync('$_header$_recall');
    final before = log.readAsStringSync();

    final changes = StreamController<void>();
    final sub =
        tailNewestDreamRun(host: TrailHost.at(tmp.path), changes: changes.stream)
            .listen((_) {});
    changes.add(null);
    await pumpEventQueue();
    await sub.cancel();
    await changes.close();

    expect(log.readAsStringSync(), before);
  });
}
