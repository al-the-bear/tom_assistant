// Extension F step 7 — the basic tool set
// (`tom_brain_procedure_specification.md` § 21.4;
// `prototype_tools_mcp_extension_plan.md` step 7).
//
// What this suite locks:
//
//   F.7-1 — `registerBasicTools` registers the twenty-eight shipped tools under
//           their § 21.4 / § 5.2-5.3 names, groups, and `readOnly` flags (the
//           sixteen base tools, the four explicit verb tools `procedure.plan` /
//           `create` / `critique` / `decide` (Todo 4 / § 11), the seven
//           creation families `file.edit` / `file.diff` / `analyze.dart` /
//           `analyze.format` / `analyze.schema` / `test.run` / `test.baseline`
//           (`creation_specification.md` § 5), and the `dream.control` cadence
//           tool (`memory_specification.md` § 9.7)).
//   F.7-2 — each tool's happy path against stubs routes through the existing
//           surface (memory client, web surface, engine surface, the
//           in-process `TodoStore`, the file-scope root) — no new effect path.
//   F.7-3 — `memory.write` charges one `memoryWrites` unit and honours the
//           § 5.1 node-shape rule (only Conclusion / Claim / Question /
//           Procedure; an `Event` write is refused before it reaches memory).
//   F.7-4 — `file.read` / `file.write` / `grep.search` / `file.search` cannot
//           escape the configured file-scope root; `file.search` matches by
//           filename glob (dcli `find`) and returns scope-relative paths.
//   F.7-5 — `script.run_d4rt` rejects a non-JSON-serialisable result and is
//           depth-capped (a `RecursionLimitExceeded` from the engine surface
//           propagates, it is not swallowed).
//   F.7-6 — `procedure.run` respects the depth cap (a real
//           `RunProcedurePrimitive` breach propagates through the tool).

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  group('F.7-1 registerBasicTools catalogue', () {
    test('registers the twenty-eight § 21.4 / § 5.2-5.3 tools with groups',
        () {
      final registry = ToolRegistry();
      registerBasicTools(registry);

      // Name → (group, readOnly) per the § 21.4 table, plus the four explicit
      // verb tools (Todo 4 / § 11) that alias procedure.run with a fixed id.
      final expected = <String, ({ToolGroup group, bool readOnly})>{
        'memory.read': (group: ToolGroup.memory, readOnly: true),
        'memory.write': (group: ToolGroup.memory, readOnly: false),
        'memory.delete': (group: ToolGroup.memory, readOnly: false),
        'todo.list': (group: ToolGroup.todo, readOnly: true),
        'todo.add': (group: ToolGroup.todo, readOnly: false),
        'todo.update': (group: ToolGroup.todo, readOnly: false),
        'todo.remove': (group: ToolGroup.todo, readOnly: false),
        'file.read': (group: ToolGroup.file, readOnly: true),
        'file.write': (group: ToolGroup.file, readOnly: false),
        'file.edit': (group: ToolGroup.file, readOnly: false),
        'file.delete': (group: ToolGroup.file, readOnly: false),
        'file.diff': (group: ToolGroup.file, readOnly: true),
        'grep.search': (group: ToolGroup.file, readOnly: true),
        'file.search': (group: ToolGroup.file, readOnly: true),
        // Creation code-understanding + test families (§ 5.2 / § 5.3).
        'analyze.dart': (group: ToolGroup.analyze, readOnly: true),
        'analyze.format': (group: ToolGroup.analyze, readOnly: true),
        'analyze.schema': (group: ToolGroup.analyze, readOnly: true),
        'test.run': (group: ToolGroup.test, readOnly: false),
        'test.baseline': (group: ToolGroup.test, readOnly: false),
        'web.search': (group: ToolGroup.web, readOnly: true),
        'web.fetch': (group: ToolGroup.web, readOnly: true),
        'script.run_d4rt': (group: ToolGroup.script, readOnly: false),
        'procedure.list': (group: ToolGroup.procedure, readOnly: true),
        'procedure.run': (group: ToolGroup.procedure, readOnly: false),
        'procedure.plan': (group: ToolGroup.procedure, readOnly: false),
        'procedure.create': (group: ToolGroup.procedure, readOnly: false),
        'procedure.critique': (group: ToolGroup.procedure, readOnly: false),
        'procedure.decide': (group: ToolGroup.procedure, readOnly: false),
        // The dreaming-cadence control tool (memory_specification.md § 9.7).
        'dream.control': (group: ToolGroup.dream, readOnly: false),
      };

      for (final entry in expected.entries) {
        final tool = registry.lookup(entry.key);
        expect(tool, isNotNull, reason: 'missing tool ${entry.key}');
        expect(tool!.group, entry.value.group, reason: '${entry.key} group');
        expect(tool.readOnly, entry.value.readOnly,
            reason: '${entry.key} readOnly');
      }
    });

    test('re-registering the basic set into a fresh registry is exclusive', () {
      final registry = ToolRegistry();
      registerBasicTools(registry);
      expect(() => registry.register(_redundantMemoryRead()),
          throwsA(isA<ToolAlreadyRegistered>()));
    });
  });

  group('F.7-1b defaultToolCatalogue wire descriptors', () {
    test('describes the twenty-nine basic tools with name/group/description',
        () {
      final catalogue = defaultToolCatalogue();
      expect(catalogue, hasLength(29));

      // Each descriptor carries the four wire fields the substrate's
      // tool-catalogue render reads (`{name, group, description, input_schema}`,
      // mirroring `ToolBridge._describe`).
      for (final descriptor in catalogue) {
        expect(descriptor['name'], isA<String>());
        expect((descriptor['name']! as String), isNotEmpty);
        expect(descriptor['group'], isA<String>());
        expect((descriptor['description']! as String), isNotEmpty);
        expect(descriptor['input_schema'], isA<Map<Object?, Object?>>());
      }

      final names = catalogue
          .map((d) => d['name']! as String)
          .toSet();
      expect(
        names,
        containsAll(<String>[
          'memory.read',
          'memory.write',
          'memory.delete',
          'todo.list',
          'todo.add',
          'todo.update',
          'todo.remove',
          'file.read',
          'file.write',
          'file.edit',
          'file.delete',
          'file.diff',
          'grep.search',
          'file.search',
          'analyze.dart',
          'analyze.format',
          'analyze.schema',
          'test.run',
          'test.baseline',
          'web.search',
          'web.fetch',
          'script.run_d4rt',
          'procedure.list',
          'procedure.run',
          'procedure.plan',
          'procedure.create',
          'procedure.critique',
          'procedure.decide',
        ]),
      );

      // The group token is the wire `ToolGroup.name` (e.g. `memory`), not the
      // enum's `toString()`.
      final memoryRead =
          catalogue.firstWhere((d) => d['name'] == 'memory.read');
      expect(memoryRead['group'], 'memory');
    });
  });

  group('F.7-2 happy paths route through the existing surface', () {
    test('memory.read routes through recall and returns the nodes', () async {
      const nodeId = 'n_00000000000000000000000001';
      final memory = _StubMemory()
        ..recallReturn = _recallOf(<Node>[_node('Conclusion', nodeId)]);
      final ctx = _ctx(memory: memory);
      final result = await _run('memory.read', {'text': 'hi'}, ctx);

      expect(memory.recallQueries, hasLength(1));
      expect(memory.recallQueries.single.text, 'hi');
      final nodes = (result! as Map)['nodes'] as List;
      expect(nodes, hasLength(1));
      expect((nodes.single as Map)['id'], nodeId);
    });

    test('memory.delete routes through demote (reversible, not forget)',
        () async {
      final memory = _StubMemory();
      final ledger = _uncappedLedger();
      final ctx = _ctx(memory: memory, budget: ledger);
      const nodeId = 'n_00000000000000000000000009';
      await _run('memory.delete', {'id': nodeId}, ctx);

      expect(memory.demoted, hasLength(1));
      expect(memory.demoted.single.id.value, nodeId);
      expect(ledger.consumed.memoryWrites, 1,
          reason: 'demote is a store mutation');
    });

    test('todo.add / todo.list / todo.update / todo.remove share one store',
        () async {
      final todos = TodoStore();
      final ctx = _ctx(todos: todos);

      final added = await _run('todo.add', {'text': 'write tests'}, ctx);
      final id = (added! as Map)['id'] as String;

      final listed = await _run('todo.list', const {}, ctx);
      expect(((listed! as Map)['todos'] as List), hasLength(1));

      await _run('todo.update', {'id': id, 'done': true}, ctx);
      expect(todos.list().single.done, isTrue);

      await _run('todo.remove', {'id': id}, ctx);
      expect(todos.list(), isEmpty);
    });

    test('web.search / web.fetch route through the web surface', () async {
      final web = _StubWeb();
      final ctx = _ctx(web: web);

      final searched = await _run('web.search', {'query': 'dart'}, ctx);
      expect((searched! as Map)['query'], 'dart');
      expect(web.searches.single, 'dart');

      final fetched = await _run('web.fetch', {'url': 'https://x.test'}, ctx);
      expect((fetched! as Map)['url'], 'https://x.test');
      expect(web.fetches.single, 'https://x.test');
    });

    test('procedure.list routes through the engine surface', () async {
      final engine = _StubEngine(
        proceduresList: const [
          <String, Object?>{'id': 'p1', 'origin': 'disk'},
        ],
      );
      final ctx = _ctx(engine: engine);
      final listed = await _run('procedure.list', const {}, ctx);
      expect(((listed! as Map)['procedures'] as List), hasLength(1));
    });

    test('procedure.run routes through the engine surface', () async {
      final engine = _StubEngine();
      final ctx = _ctx(engine: engine);
      final ran = await _run('procedure.run', {'id': 'p1'}, ctx);
      expect((ran! as Map)['status'], 'succeeded');
    });

    test('script.run_d4rt returns a JSON result from the engine surface',
        () async {
      final engine = _StubEngine(scriptResult: const {'answer': 42});
      final ctx = _ctx(engine: engine);
      final ran = await _run('script.run_d4rt', {'source': 'main() => 42;'}, ctx);
      expect((ran! as Map)['result'], const {'answer': 42});
    });
  });

  group('F.7-3 memory.write counts memoryWrites + node-shape rule', () {
    test('a Conclusion write charges one memoryWrites and persists', () async {
      final memory = _StubMemory();
      final ledger = _uncappedLedger();
      final ctx = _ctx(memory: memory, budget: ledger);

      final written = await _run(
        'memory.write',
        {
          'typeName': 'Conclusion',
          'values': const {'text': 'the sky is blue'},
        },
        ctx,
      );

      expect(memory.persisted, hasLength(1));
      expect(memory.persisted.single.typeName, 'Conclusion');
      expect((written! as Map)['id'], isNotNull);
      expect(ledger.consumed.memoryWrites, 1);
    });

    test('an Event write is refused by the node-shape rule before memory',
        () async {
      final memory = _StubMemory();
      final ledger = _uncappedLedger();
      final ctx = _ctx(memory: memory, budget: ledger);

      await expectLater(
        _run('memory.write',
            {'typeName': 'Event', 'values': const {}}, ctx),
        throwsA(isA<NodeShapeNotWritable>()),
      );
      expect(memory.persisted, isEmpty, reason: 'no write reached memory');
      expect(ledger.consumed.memoryWrites, 0, reason: 'refused before charge');
    });
  });

  group('F.7-4 file tools cannot escape the configured root', () {
    late Directory root;

    setUp(() => root = Directory.systemTemp.createTempSync('f7_filescope_'));
    tearDown(() => root.deleteSync(recursive: true));

    test('file.read reads a file inside the root', () async {
      File(p.join(root.path, 'note.txt')).writeAsStringSync('hello');
      final ctx = _ctx(fileScopeRoots: <String>[root.path]);
      final read = await _run('file.read', {'path': 'note.txt'}, ctx);
      expect((read! as Map)['content'], 'hello');
    });

    test('file.write writes a file inside the root', () async {
      final ctx = _ctx(fileScopeRoots: <String>[root.path]);
      await _run('file.write', {'path': 'out.txt', 'content': 'x'}, ctx);
      expect(File(p.join(root.path, 'out.txt')).readAsStringSync(), 'x');
    });

    test('grep.search matches inside the root only', () async {
      File(p.join(root.path, 'a.txt')).writeAsStringSync('needle here');
      File(p.join(root.path, 'b.txt')).writeAsStringSync('nothing');
      final ctx = _ctx(fileScopeRoots: <String>[root.path]);
      final found = await _run('grep.search', {'pattern': 'needle'}, ctx);
      final matches = (found! as Map)['matches'] as List;
      expect(matches, hasLength(1));
      expect((matches.single as Map)['file'], 'a.txt');
    });

    test('file.read rejects a path that escapes the root', () async {
      final ctx = _ctx(fileScopeRoots: <String>[root.path]);
      await expectLater(
        _run('file.read', {'path': '../escape.txt'}, ctx),
        throwsA(isA<FileScopeViolation>()),
      );
    });

    test('file.write rejects an absolute path outside the root', () async {
      final ctx = _ctx(fileScopeRoots: <String>[root.path]);
      await expectLater(
        _run('file.write', {'path': '/etc/passwd', 'content': 'x'}, ctx),
        throwsA(isA<FileScopeViolation>()),
      );
    });

    test('grep.search rejects a sub-path that escapes the root', () async {
      final ctx = _ctx(fileScopeRoots: <String>[root.path]);
      await expectLater(
        _run('grep.search', {'pattern': 'x', 'path': '../..'}, ctx),
        throwsA(isA<FileScopeViolation>()),
      );
    });
  });

  group('F.7-7 file.search matches by filename glob within the root', () {
    late Directory root;

    setUp(() => root = Directory.systemTemp.createTempSync('f7_filesearch_'));
    tearDown(() => root.deleteSync(recursive: true));

    test('a glob pattern matches recursively and returns scope-relative paths',
        () async {
      File(p.join(root.path, 'alpha.txt')).writeAsStringSync('a');
      File(p.join(root.path, 'beta.md')).writeAsStringSync('b');
      final sub = Directory(p.join(root.path, 'nested'))..createSync();
      File(p.join(sub.path, 'gamma.txt')).writeAsStringSync('g');

      final ctx = _ctx(fileScopeRoots: <String>[root.path]);
      final found = await _run('file.search', {'pattern': '*.txt'}, ctx);
      final matches = ((found! as Map)['matches'] as List).cast<String>();

      expect(matches, containsAll(<String>['alpha.txt', p.join('nested', 'gamma.txt')]));
      expect(matches, isNot(contains('beta.md')));
    });

    test('a non-recursive search stays in the top directory', () async {
      File(p.join(root.path, 'top.txt')).writeAsStringSync('t');
      final sub = Directory(p.join(root.path, 'nested'))..createSync();
      File(p.join(sub.path, 'deep.txt')).writeAsStringSync('d');

      final ctx = _ctx(fileScopeRoots: <String>[root.path]);
      final found = await _run(
        'file.search',
        {'pattern': '*.txt', 'recursive': false},
        ctx,
      );
      final matches = ((found! as Map)['matches'] as List).cast<String>();

      expect(matches, <String>['top.txt']);
    });

    test('a search inside a named sub-directory is scoped to it', () async {
      final sub = Directory(p.join(root.path, 'docs'))..createSync();
      File(p.join(sub.path, 'note.txt')).writeAsStringSync('n');
      File(p.join(root.path, 'outside.txt')).writeAsStringSync('o');

      final ctx = _ctx(fileScopeRoots: <String>[root.path]);
      final found = await _run(
        'file.search',
        {'pattern': '*.txt', 'path': 'docs'},
        ctx,
      );
      final matches = ((found! as Map)['matches'] as List).cast<String>();

      expect(matches, <String>[p.join('docs', 'note.txt')]);
    });

    test('a search in a missing sub-directory returns no matches', () async {
      final ctx = _ctx(fileScopeRoots: <String>[root.path]);
      final found = await _run(
        'file.search',
        {'pattern': '*.txt', 'path': 'absent'},
        ctx,
      );
      expect((found! as Map)['matches'], isEmpty);
    });

    test('a sub-path that escapes the root is rejected', () async {
      final ctx = _ctx(fileScopeRoots: <String>[root.path]);
      await expectLater(
        _run('file.search', {'pattern': '*', 'path': '../..'}, ctx),
        throwsA(isA<FileScopeViolation>()),
      );
    });
  });

  group('F.7-8 file tools span a union of configured roots', () {
    late Directory primary;
    late Directory secondary;

    setUp(() {
      primary = Directory.systemTemp.createTempSync('f7_root_a_');
      secondary = Directory.systemTemp.createTempSync('f7_root_b_');
    });
    tearDown(() {
      primary.deleteSync(recursive: true);
      secondary.deleteSync(recursive: true);
    });

    test('file.read finds a file that lives only in a secondary root', () async {
      File(p.join(secondary.path, 'only_here.txt')).writeAsStringSync('found');
      final ctx = _ctx(fileScopeRoots: <String>[primary.path, secondary.path]);

      final read = await _run('file.read', {'path': 'only_here.txt'}, ctx);

      expect((read! as Map)['content'], 'found');
    });

    test('file.read prefers the first root that holds the file', () async {
      File(p.join(primary.path, 'dup.txt')).writeAsStringSync('from primary');
      File(p.join(secondary.path, 'dup.txt')).writeAsStringSync('from secondary');
      final ctx = _ctx(fileScopeRoots: <String>[primary.path, secondary.path]);

      final read = await _run('file.read', {'path': 'dup.txt'}, ctx);

      expect((read! as Map)['content'], 'from primary');
    });

    test('file.write targets the primary (first) root', () async {
      final ctx = _ctx(fileScopeRoots: <String>[primary.path, secondary.path]);

      await _run('file.write', {'path': 'out.txt', 'content': 'x'}, ctx);

      expect(File(p.join(primary.path, 'out.txt')).existsSync(), isTrue);
      expect(File(p.join(secondary.path, 'out.txt')).existsSync(), isFalse);
    });

    test('grep.search spans every root', () async {
      File(p.join(primary.path, 'a.txt')).writeAsStringSync('needle one');
      File(p.join(secondary.path, 'b.txt')).writeAsStringSync('needle two');
      final ctx = _ctx(fileScopeRoots: <String>[primary.path, secondary.path]);

      final found = await _run('grep.search', {'pattern': 'needle'}, ctx);
      final files = ((found! as Map)['matches'] as List)
          .map((m) => (m as Map)['file'])
          .toList();

      expect(files, containsAll(<String>['a.txt', 'b.txt']));
    });

    test('file.search spans every root', () async {
      File(p.join(primary.path, 'alpha.txt')).writeAsStringSync('a');
      File(p.join(secondary.path, 'beta.txt')).writeAsStringSync('b');
      final ctx = _ctx(fileScopeRoots: <String>[primary.path, secondary.path]);

      final found = await _run('file.search', {'pattern': '*.txt'}, ctx);
      final matches = ((found! as Map)['matches'] as List).cast<String>();

      expect(matches, containsAll(<String>['alpha.txt', 'beta.txt']));
    });

    test('a path escaping every root is still rejected', () async {
      final ctx = _ctx(fileScopeRoots: <String>[primary.path, secondary.path]);

      await expectLater(
        _run('file.read', {'path': '../escape.txt'}, ctx),
        throwsA(isA<FileScopeViolation>()),
      );
    });
  });

  group('F.7-5 script.run_d4rt rejection + depth cap', () {
    test('a non-JSON-serialisable result is rejected', () async {
      final engine = _StubEngine(scriptResult: DateTime(2026));
      final ctx = _ctx(engine: engine);
      await expectLater(
        _run('script.run_d4rt', {'source': 'main() {}'}, ctx),
        throwsA(isA<ScriptResultNotJson>()),
      );
    });

    test('a depth-cap breach from the engine surface propagates', () async {
      final engine = _StubEngine(
        scriptThrows: const RecursionLimitExceeded(
          attemptedDepth: 11,
          hardDepthCap: 10,
          procedureId: 'script.run_d4rt',
        ),
      );
      final ctx = _ctx(engine: engine);
      await expectLater(
        _run('script.run_d4rt', {'source': 'main() {}'}, ctx),
        throwsA(isA<RecursionLimitExceeded>()),
      );
    });
  });

  group('F.7-6 procedure.run respects the depth cap', () {
    test('a RunProcedurePrimitive breach propagates through the tool',
        () async {
      // A real primitive whose chain is already at the cap: the next
      // runProcedure must breach.
      final primitive = RunProcedurePrimitive(
        executor: (call) async => ProcedureResult.succeeded(),
        hardDepthCap: 1,
        startDepth: 1,
      );
      final engine = _StubEngine(primitive: primitive);
      final ctx = _ctx(engine: engine);
      await expectLater(
        _run('procedure.run', {'id': 'deep'}, ctx),
        throwsA(isA<RecursionLimitExceeded>()),
      );
    });
  });

  group('F.7-9 explicit verb tools alias procedure.run with a fixed id', () {
    // The four prominent verbs (Todo 4 / § 11) are exposed as their own tools
    // so a model can call `procedure.plan` directly instead of remembering the
    // `<verb>_v1` id. Each fixes the id and forwards the caller's inputs.
    for (final verb in const ['plan', 'create', 'critique', 'decide']) {
      test('procedure.$verb routes to ${verb}_v1 with the caller inputs',
          () async {
        final engine = _StubEngine();
        final ctx = _ctx(engine: engine);
        final ran = await _run('procedure.$verb', {'goal': 'x'}, ctx);

        expect(engine.runIds, <String>['${verb}_v1'],
            reason: 'verb tool must fix the procedure id');
        // The stub engine echoes inputs as outputs — the caller's payload
        // reaches the target unchanged.
        final result = ran! as Map;
        expect(result['status'], 'succeeded');
        expect((result['outputs'] as Map)['goal'], 'x');
      });
    }
  });
}

// ── helpers ──────────────────────────────────────────────────────────

Future<Object?> _run(
  String name,
  Map<String, Object?> args,
  ToolContext ctx,
) {
  final registry = ToolRegistry();
  registerBasicTools(registry);
  final tool = registry.lookup(name);
  if (tool == null) throw StateError('no tool "$name"');
  return tool.run(args, ctx);
}

ToolContext _ctx({
  _StubMemory? memory,
  BudgetLedger? budget,
  List<String>? fileScopeRoots,
  TodoStore? todos,
  ToolWebSurface? web,
  ToolEngineSurface? engine,
}) =>
    ToolContext(
      budget: budget ?? _uncappedLedger(),
      memory: memory ?? _StubMemory(),
      fileScopeRoots: fileScopeRoots ?? const <String>['/tom-brain-engine'],
      todos: todos,
      web: web,
      engine: engine,
    );

BudgetLedger _uncappedLedger() =>
    BudgetLedger(ProcedureBudget(const <String, int>{}));

BrainTool _redundantMemoryRead() => ToolRegistry().let((r) {
      registerBasicTools(r);
      return r.lookup('memory.read')!;
    });

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

RecallResult _recallOf(List<Node> nodes) => RecallResult(
      nodes: nodes,
      report: const RecallReport(
        candidatesPerMode: <RecallMode, int>{},
        fusionStrategy: FusionStrategy.rrf,
        diversityStrategy: DiversityStrategy.mmr,
        elapsedMs: 0,
      ),
    );

Node _node(String typeName, String id) => Node(
      id: NodeId.fromString(id),
      typeName: typeName,
      values: const <String, Object?>{},
      createdAt: DateTime.utc(2026),
    );

/// A `TomBrainMemoryClient` test double recording the three calls the memory
/// tools route through.
class _StubMemory implements TomBrainMemoryClient {
  final List<NodeDraft> persisted = <NodeDraft>[];
  final List<({NodeId id, DemotionReason reason})> demoted =
      <({NodeId id, DemotionReason reason})>[];
  final List<RecallQuery> recallQueries = <RecallQuery>[];
  RecallResult recallReturn = RecallResult(
    nodes: const <Node>[],
    report: const RecallReport(
      candidatesPerMode: <RecallMode, int>{},
      fusionStrategy: FusionStrategy.rrf,
      diversityStrategy: DiversityStrategy.mmr,
      elapsedMs: 0,
    ),
  );

  @override
  Future<NodeId> persist(NodeDraft draft, {required Scope scope}) async {
    persisted.add(draft);
    return NodeId.generate();
  }

  @override
  Future<void> demote(NodeId id, DemotionReason reason) async {
    demoted.add((id: id, reason: reason));
  }

  @override
  Future<RecallResult> recall(RecallQuery query) async {
    recallQueries.add(query);
    return recallReturn;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// A `ToolWebSurface` test double recording its calls.
class _StubWeb implements ToolWebSurface {
  final List<String> searches = <String>[];
  final List<String> fetches = <String>[];

  @override
  Future<Map<String, Object?>> search(String query, {int k = 10}) async {
    searches.add(query);
    return <String, Object?>{'query': query, 'hits': const <Object?>[]};
  }

  @override
  Future<Map<String, Object?>> fetch(String url, {int? budgetBytes}) async {
    fetches.add(url);
    return <String, Object?>{'url': url, 'status': 200};
  }
}

/// A `ToolEngineSurface` test double. [primitive], when set, routes
/// `runProcedure` through a real depth-capped primitive; otherwise it returns
/// a succeeded result. `runD4rtScript` returns [scriptResult] or throws
/// [scriptThrows].
class _StubEngine implements ToolEngineSurface {
  _StubEngine({
    this.proceduresList = const <Map<String, Object?>>[],
    this.scriptResult,
    this.scriptThrows,
    this.primitive,
  });

  final List<Map<String, Object?>> proceduresList;
  final Object? scriptResult;
  final Object? scriptThrows;
  final RunProcedurePrimitive? primitive;

  /// The procedure ids handed to [runProcedure], in call order — lets a test
  /// assert an explicit verb tool fixed the id to `<verb>_v1`.
  final List<String> runIds = <String>[];

  @override
  Future<List<Map<String, Object?>>> listProcedures() async => proceduresList;

  @override
  Future<Map<String, Object?>> runProcedure(
    String id,
    Map<String, Object?> inputs, {
    int? version,
  }) async {
    runIds.add(id);
    final prim = primitive;
    if (prim != null) {
      final result =
          await prim.runProcedure(id, ProcedureInputs(inputs), version: version);
      return <String, Object?>{
        'status': result.status.name,
        'outputs': result.outputs,
      };
    }
    return <String, Object?>{'status': 'succeeded', 'outputs': inputs};
  }

  @override
  Future<Object?> runD4rtScript(String source) async {
    final thrown = scriptThrows;
    if (thrown != null) throw thrown;
    return scriptResult;
  }
}
