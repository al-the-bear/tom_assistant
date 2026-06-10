// ProcedureTreeWriter — the §5.7 per-procedure combined log
// (`tom_brain_logging.md` §10 step #9).
//
// One combined [ProcedureTreeRecord] (assembled by the engine — the parent's
// trail nodes with each subprocedure spliced in) renders to one
// `procedures/<procedureId>/<turnId>__<runId>.log` file: the run's *structure*
// as indented box-drawing lines that **link to the raw files but do not inline
// the prompts/answers** (§5.7). A turn-less dream run keys by `<runId>.log`.

import 'dart:io';

import 'package:tom_brain_memory/tom_brain_memory.dart' show TrailOutcomeStatus;
import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempRoot;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('proc_tree_writer_test_');
  });

  tearDown(() {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  // The §5.7 worked example: a turn-bound run that recalls, calls the
  // recaller, runs a critique subprocedure (evaluator llm), then answers.
  ProcedureTreeRecord workedExample() => ProcedureTreeRecord(
        procedureId: 'answer_with_memory_v1',
        version: 1,
        runId: 'disp-fg-run-7',
        parentRunId: null,
        turnId: 'turn_01JZ',
        depth: 1,
        status: TrailOutcomeStatus.accepted,
        elapsedMs: 1400,
        entryCount: 16,
        nodes: <ProcedureTreeNode>[
          ProcedurePrimitiveNode(
            primitive: 'recall',
            input: <String, Object?>{
              'modes': <String>['bm25', 'vector'],
              'k': 8,
            },
            result: <String, Object?>{
              'nodes': List<Object?>.filled(8, <String, Object?>{}),
            },
          ),
          ProcedurePrimitiveNode(
            primitive: 'llm',
            input: <String, Object?>{'prompt': 'x', 'role': 'recaller'},
            result: const <String, Object?>{},
            llm: const ProcedureTreeLlmRef(
              callType: 'recaller',
              turnId: 'turn_01JZ',
              callSeq: 1,
              callId: 'c1',
              runId: 'disp-fg-run-7',
              tokensIn: 612,
              tokensOut: 48,
            ),
          ),
          ProcedureSubtreeNode(
            tree: ProcedureTreeRecord(
              procedureId: 'critique_v1',
              version: 1,
              runId: 'disp-fg-run-8',
              parentRunId: 'disp-fg-run-7',
              turnId: 'turn_01JZ',
              depth: 2,
              status: TrailOutcomeStatus.accepted,
              elapsedMs: 50,
              entryCount: 4,
              nodes: <ProcedureTreeNode>[
                ProcedurePrimitiveNode(
                  primitive: 'llm',
                  input: <String, Object?>{'prompt': 'y', 'role': 'evaluator'},
                  result: const <String, Object?>{},
                  llm: const ProcedureTreeLlmRef(
                    callType: 'evaluator',
                    turnId: 'turn_01JZ',
                    callSeq: 2,
                    callId: 'c2',
                    runId: 'disp-fg-run-8',
                    tokensIn: 1200,
                    tokensOut: 30,
                  ),
                ),
              ],
            ),
          ),
          ProcedurePrimitiveNode(
            primitive: 'llm',
            input: <String, Object?>{'prompt': 'z', 'role': 'assistant_to_user'},
            result: const <String, Object?>{},
            llm: const ProcedureTreeLlmRef(
              callType: 'assistant_to_user',
              turnId: 'turn_01JZ',
              callSeq: 3,
              callId: 'c3',
              runId: 'disp-fg-run-7',
              tokensIn: 174,
              tokensOut: 24,
            ),
          ),
        ],
      );

  group('ProcedureTreeWriter (§5.7 / §10 step #9)', () {
    test('renders one combined tree to procedures/<proc>/<turn>__<run>.log',
        () async {
      ProcedureTreeWriter(root: tempRoot).write(workedExample());

      final file = File(
        '${tempRoot.path}/procedures/answer_with_memory_v1/'
        'turn_01JZ__disp-fg-run-7.log',
      );
      expect(file.existsSync(), isTrue, reason: 'keyed by turn + run');
      final text = file.readAsStringSync();

      // Header names the procedure, run, and turn.
      expect(text, contains(
          'procedure answer_with_memory_v1  run disp-fg-run-7  turn turn_01JZ'));

      // recall — structure only, no raw link (a memory primitive).
      expect(text, contains('├─ recall (bm25+vector k=8 → 8)'));

      // The recaller llm: token counts + a link to its raw dump (two dir hops
      // from procedures/<proc>/ back to the root, then llm/<role>/<stem>).
      expect(text, contains('├─ llm recaller → 612→48 tok'));
      expect(text,
          contains('→ ../../llm/recaller/turn_01JZ__01.raw.json'));

      // The spliced subprocedure header, then its evaluator llm as the last
      // child of the subtree (└─), with its own raw link.
      expect(text, contains('├─ subprocedure critique_v1  run disp-fg-run-8'));
      expect(text, contains('│  └─ llm evaluator → 1200→30 tok'));
      expect(text,
          contains('→ ../../llm/evaluator/turn_01JZ__02.raw.json'));

      // The assistant llm after the subtree, then the outcome line (entries +
      // elapsed in seconds, one decimal).
      expect(text, contains('├─ llm assistant_to_user → 174→24 tok'));
      expect(text, contains('└─ outcome accepted (entries=16, 1.4s)'));
    });

    test('appends recall returned node ids after the count (PT-7 / §3.9)',
        () async {
      final record = ProcedureTreeRecord(
        procedureId: 'retrieve_for_prompt_v1',
        version: 1,
        runId: 'recall-run-1',
        parentRunId: null,
        turnId: 'turn_RID',
        depth: 1,
        status: TrailOutcomeStatus.accepted,
        elapsedMs: 200,
        entryCount: 1,
        nodes: <ProcedureTreeNode>[
          ProcedurePrimitiveNode(
            primitive: 'recall',
            input: <String, Object?>{
              'modes': <String>['bm25', 'vector'],
              'k': 4,
            },
            result: <String, Object?>{
              'nodes': <Object?>[
                <String, Object?>{'id': 'n_alpha'},
                <String, Object?>{'id': 'n_beta'},
              ],
            },
          ),
        ],
      );

      ProcedureTreeWriter(root: tempRoot).write(record);
      final text = File(
        '${tempRoot.path}/procedures/retrieve_for_prompt_v1/'
        'turn_RID__recall-run-1.log',
      ).readAsStringSync();

      // Count then the resolvable returned ids — the §4.7 deep-link source.
      expect(text, contains('recall (bm25+vector k=4 → 2: n_alpha, n_beta)'));
    });

    test('renders an edge\'s endpoints + type after the id (§3.8 / §3.9)',
        () async {
      final record = ProcedureTreeRecord(
        procedureId: 'answer_with_memory_v1',
        version: 1,
        runId: 'edge-run-1',
        parentRunId: null,
        turnId: 'turn_EDG',
        depth: 1,
        status: TrailOutcomeStatus.accepted,
        elapsedMs: 120,
        entryCount: 1,
        nodes: <ProcedureTreeNode>[
          ProcedurePrimitiveNode(
            primitive: 'edge',
            input: <String, Object?>{
              'from': 'n_alpha',
              'type': 'supports',
              'to': 'n_beta',
            },
            result: <String, Object?>{'id': 'e_fixtureA1'},
          ),
        ],
      );

      ProcedureTreeWriter(root: tempRoot).write(record);
      final text = File(
        '${tempRoot.path}/procedures/answer_with_memory_v1/'
        'turn_EDG__edge-run-1.log',
      ).readAsStringSync();

      // Endpoints + relation, then the new edge's own id — the §4.7 source
      // (the endpoints deep-link; the edge id does not).
      expect(text, contains('edge n_alpha -supports-> n_beta → e_fixtureA1'));
    });

    test('an edge missing an endpoint falls back to the bare id form', () async {
      final record = ProcedureTreeRecord(
        procedureId: 'answer_with_memory_v1',
        version: 1,
        runId: 'edge-run-2',
        parentRunId: null,
        turnId: 'turn_EDG2',
        depth: 1,
        status: TrailOutcomeStatus.accepted,
        elapsedMs: 120,
        entryCount: 1,
        nodes: <ProcedureTreeNode>[
          ProcedurePrimitiveNode(
            primitive: 'edge',
            input: const <String, Object?>{'from': 'n_alpha'}, // no type/to
            result: <String, Object?>{'id': 'e_fixtureB2'},
          ),
        ],
      );

      ProcedureTreeWriter(root: tempRoot).write(record);
      final text = File(
        '${tempRoot.path}/procedures/answer_with_memory_v1/'
        'turn_EDG2__edge-run-2.log',
      ).readAsStringSync();

      expect(text, contains('├─ edge → e_fixtureB2'));
      expect(text, isNot(contains('-supports->')));
    });

    test('keys a turn-less dream run by <runId>.log with a runId__callId stem',
        () async {
      final dream = ProcedureTreeRecord(
        procedureId: 'dream_extractor_v1',
        version: 1,
        runId: 'dream-run-9',
        parentRunId: null,
        turnId: null,
        depth: 1,
        status: TrailOutcomeStatus.accepted,
        elapsedMs: 800,
        entryCount: 3,
        nodes: <ProcedureTreeNode>[
          ProcedurePrimitiveNode(
            primitive: 'llm',
            input: const <String, Object?>{'prompt': 'd', 'role': 'extractor'},
            result: const <String, Object?>{},
            llm: const ProcedureTreeLlmRef(
              callType: 'extractor',
              turnId: null,
              callSeq: null,
              callId: 'cz',
              runId: 'dream-run-9',
              tokensIn: 40,
              tokensOut: 12,
            ),
          ),
        ],
      );

      ProcedureTreeWriter(root: tempRoot).write(dream);

      final file = File(
        '${tempRoot.path}/procedures/dream_extractor_v1/dream-run-9.log',
      );
      expect(file.existsSync(), isTrue, reason: 'turn-less → keyed by run only');
      final text = file.readAsStringSync();
      expect(text,
          contains('procedure dream_extractor_v1  run dream-run-9'));
      expect(text, isNot(contains('turn ')), reason: 'no turn to name');
      // Turn-less ⇒ the raw-stem falls back to <runId>__<callId>.
      expect(text,
          contains('→ ../../llm/extractor/dream-run-9__cz.raw.json'));
      // Sub-second elapsed renders in milliseconds.
      expect(text, contains('outcome accepted (entries=3, 800ms)'));
    });

    test('is best-effort: a write under an unusable root never throws', () {
      // Point the root *inside* a regular file, so creating the
      // `procedures/<proc>/` parent must fail. The writer swallows it (§9).
      final blocker = File('${tempRoot.path}/blocker')..writeAsStringSync('x');
      final writer = ProcedureTreeWriter(root: Directory('${blocker.path}/sub'));

      expect(() => writer.write(workedExample()), returnsNormally);
    });
  });
}
