// PT-4.1 (unit) — the pure live-trail step parser. `parseTurnSteps` splits one
// turn's `## 🚀 PROMPT <turnId>` block of a per-session streaming live-trail
// (`streaming_live_trail.dart`, § 3.5) into its ordered `### `-headed cognitive
// steps — thinking, memory/tool acts, the assistant answer, and the terminal
// `✅ DONE` banner. It is the deterministic core the SSE live-tail diffs against
// (§ 4.8), so it is tested in isolation from any file watch.

import 'package:tom_brain_observatory/src/live/live_trail_steps.dart';
import 'package:test/test.dart';

/// A two-turn streaming live-trail: turn `a` is finished (ends with DONE);
/// turn `b` is in flight (no DONE yet).
const _trail = '''
<!-- tom-brain session live-trail -->

## 🚀 PROMPT 260101-120000.000001 [openai / default]

> User: what did we decide about backups?

### 🧠 thinking (recall_planner)

{"questions":["which option was chosen?"]}

### 🔧 recallMulti [260101-120000.000001__02]

```json
{ "k": 8 }
```

### 💬 assistant

We settled on the tiered backup topology.

### ✅ DONE (llmCalls=2, memCalls=1, toolCalls=1, 2100ms)

## 🚀 PROMPT 260101-120100.000002 [openai / default]

> User: summarize status

### 🧠 thinking (recall_planner)

{"questions":["what changed?"]}
''';

void main() {
  group('parseTurnSteps', () {
    test('returns the ordered steps of a finished turn', () {
      final steps = parseTurnSteps(_trail, '260101-120000.000001');
      expect(steps.map((s) => s.heading), <String>[
        '🧠 thinking (recall_planner)',
        '🔧 recallMulti [260101-120000.000001__02]',
        '💬 assistant',
        '✅ DONE (llmCalls=2, memCalls=1, toolCalls=1, 2100ms)',
      ]);
    });

    test('flags only the DONE banner as terminal', () {
      final steps = parseTurnSteps(_trail, '260101-120000.000001');
      expect(steps.where((s) => s.isDone).map((s) => s.heading),
          <String>['✅ DONE (llmCalls=2, memCalls=1, toolCalls=1, 2100ms)']);
    });

    test('captures the verbatim body under a step heading', () {
      final steps = parseTurnSteps(_trail, '260101-120000.000001');
      final assistant = steps.firstWhere((s) => s.heading == '💬 assistant');
      expect(assistant.body, 'We settled on the tiered backup topology.');
    });

    test('an in-flight turn has no DONE step', () {
      final steps = parseTurnSteps(_trail, '260101-120100.000002');
      expect(steps.map((s) => s.heading),
          <String>['🧠 thinking (recall_planner)']);
      expect(steps.any((s) => s.isDone), isFalse);
    });

    test('a turn that is not present yields no steps', () {
      expect(parseTurnSteps(_trail, '999999-000000.000000'), isEmpty);
    });

    test('a turnId is matched whole, not as a prefix', () {
      // `2601` must not match the `260101-…` turns.
      expect(parseTurnSteps(_trail, '2601'), isEmpty);
    });
  });
}
