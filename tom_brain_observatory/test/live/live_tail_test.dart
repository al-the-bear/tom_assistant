// PT-4.1 (unit) — the live-tail controller. `tailTurnSteps` re-reads a session
// live-trail on each change tick and emits only the newly-appended cognitive
// steps (§ 4.8), closing the stream after the turn's `✅ DONE`. The change
// signal is injected so the test is deterministic (production wraps an OS
// file-watch into the same `Stream<void>`). Asserts one event per appended
// step and OBS-5: the tail never writes the trail.

import 'dart:async';
import 'dart:io';

import 'package:tom_brain_observatory/src/live/live_tail.dart';
import 'package:tom_brain_observatory/src/live/live_trail_steps.dart';
import 'package:test/test.dart';

const _header = '''
<!-- tom-brain session live-trail -->

## 🚀 PROMPT 260101-120000.000001 [openai / default]

> User: what did we decide about backups?

### 🧠 thinking (recall_planner)

{"questions":["which option?"]}
''';

const _recallStep = '''
### 🔧 recallMulti [260101-120000.000001__02]

```json
{ "k": 8 }
```
''';

const _replyAndDone = '''
### 💬 assistant

We settled on the tiered backup topology.

### ✅ DONE (llmCalls=2, memCalls=1, toolCalls=1, 2100ms)
''';

void main() {
  late Directory tmp;
  late File file;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('live_tail_test_');
    file = File('${tmp.path}/sess.live-trail.md')..writeAsStringSync(_header);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('emits one event per appended step and closes after DONE', () async {
    final changes = StreamController<void>();
    final seen = <LiveTrailStep>[];
    final done = Completer<void>();

    tailTurnSteps(
      file: file,
      turnId: '260101-120000.000001',
      changes: changes.stream,
    ).listen(seen.add, onDone: done.complete);

    // The initial read emits the step already in the file.
    await pumpEventQueue();
    expect(seen.map((s) => s.heading), <String>['🧠 thinking (recall_planner)']);

    // Append a memory act; a change tick emits exactly that step.
    file.writeAsStringSync(_recallStep, mode: FileMode.append);
    changes.add(null);
    await pumpEventQueue();
    expect(seen.last.heading, startsWith('🔧 recallMulti'));
    expect(seen.length, 2);

    // Append the answer + DONE; both arrive, then the stream closes.
    file.writeAsStringSync(_replyAndDone, mode: FileMode.append);
    changes.add(null);
    await done.future;
    expect(seen.length, 4);
    expect(seen[2].heading, '💬 assistant');
    expect(seen[3].heading, startsWith('✅ DONE'));
    expect(seen.last.isDone, isTrue);

    await changes.close();
  });

  test('OBS-5: tailing never writes the trail file', () async {
    final before = file.readAsStringSync();
    final changes = StreamController<void>();
    final sub = tailTurnSteps(
      file: file,
      turnId: '260101-120000.000001',
      changes: changes.stream,
    ).listen((_) {});

    changes.add(null);
    await pumpEventQueue();
    await sub.cancel();
    await changes.close();

    expect(file.readAsStringSync(), before);
  });
}
