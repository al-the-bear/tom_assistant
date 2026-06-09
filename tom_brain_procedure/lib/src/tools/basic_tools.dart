// The basic tool set — the shipped `BrainTool`s registered by default
// (`tom_brain_procedure_specification.md` § 21.4;
// `prototype_tools_mcp_extension_plan.md` step 7).
//
// Every tool here routes through a surface that already exists, opening **no
// new effect path** (Q-F.5):
//
//   - memory.read / write / delete → the `ToolContext.memory` consumer
//     contract (`recall` / `persist` / `demote`); the two mutating tools
//     `check` + `charge` their primitive against the run ledger (PE-8), so a
//     tool write counts the same `memoryWrites` a scripted `persist` does.
//   - todo.list / add / update / remove → the in-process `ToolContext.todos`
//     store (ephemeral, run-scoped; never persisted to memory).
//   - file.read / write, grep.search, file.search → a `dart:io` handle (and,
//     for `file.search`, dcli's `find` globber) re-derived from the
//     `ToolContext.fileScopeRoots` list and path-escape-checked on every call
//     (PE-1): a resolved path outside *every* root raises `FileScopeViolation`
//     before any byte moves. Reads search the roots in order, writes target the
//     primary (first) root, and discovery spans all roots.
//   - web.search / fetch → the optional `ToolContext.web` surface (the
//     substrate web client); the one `toolCalls` unit `tool.invoke`
//     pre-charges *is* the web call, so these do not re-charge.
//   - script.run_d4rt, procedure.list / run → the optional
//     `ToolContext.engine` surface; `runProcedure` and a nested `runD4rtScript`
//     run under the hard depth cap (PE-3), and `script.run_d4rt` refuses a
//     non-JSON result (`ScriptResultNotJson`).
//
// A tool that needs an optional surface its context did not supply raises
// `ToolSurfaceUnavailable` rather than silently degrading. None of these tools
// re-charges the `toolCalls` unit `tool.invoke` already pre-charges; only the
// memory mutations add their own (orthogonal) `memoryWrites` charge.

import 'dart:io';

import 'package:dcli/dcli.dart' show find;
import 'package:path/path.dart' as p;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        DemotionReason,
        Node,
        NodeDraft,
        NodeId,
        RecallMode,
        RecallQuery,
        Scope;

import 'brain_tool.dart';
import 'tool_context.dart';
import 'tool_failures.dart';
import 'tool_group.dart';
import 'tool_registry.dart';

/// The node types `memory.write` may persist (§ 5.1). An `Event` and any other
/// type is refused — `Event` writes go through the recorder's trail, not the
/// `persist` tool.
const Set<String> writableNodeShapes = <String>{
  'Conclusion',
  'Claim',
  'Question',
  'Procedure',
};

/// Registers the shipped basic tool set (§ 21.4) into [registry].
///
/// Idempotent only against a fresh registry: registering twice into the same
/// registry raises `ToolAlreadyRegistered` for the first collision, exactly as
/// any duplicate registration does (§ 21.2). The composition root calls this
/// once when it builds the run's registry.
void registerBasicTools(ToolRegistry registry) {
  for (final tool in _basicTools()) {
    registry.register(tool);
  }
}

/// The shipped basic tool set (§ 21.4), one fresh instance per call.
List<BrainTool> _basicTools() => <BrainTool>[
      _MemoryReadTool(),
      _MemoryWriteTool(),
      _MemoryDeleteTool(),
      _TodoListTool(),
      _TodoAddTool(),
      _TodoUpdateTool(),
      _TodoRemoveTool(),
      _FileReadTool(),
      _FileWriteTool(),
      _GrepSearchTool(),
      _FileSearchTool(),
      _WebSearchTool(),
      _WebFetchTool(),
      _ScriptRunD4rtTool(),
      _ProcedureListTool(),
      _ProcedureRunTool(),
      // The four prominent verbs exposed as their own tools (Todo 4 / § 11):
      // fixed-id aliases of procedure.run so a model can call `procedure.plan`
      // directly instead of recalling the `<verb>_v1` id.
      for (final verb in _verbToolNames) _ProcedureVerbTool(verb),
    ];

/// The four prominent verbs given their own explicit tool (Todo 4 / § 11).
/// `think` is intentionally absent: `think_v1` is a no-op machinery stub, not a
/// prominent loop a caller reaches for by name.
const List<String> _verbToolNames = <String>['plan', 'create', 'critique', 'decide'];

/// The wire descriptors for the shipped basic tool set (§ 21.4).
///
/// Each descriptor is the `{name, group, description, input_schema}` shape the
/// substrate tool-catalogue render reads (the same shape `ToolBridge._describe`
/// emits for the d4rt `tool.list()` global). Threading this list into the live
/// answer path lets a memoryless substrate name the tools it has available,
/// independent of whether the wire provider yet honours an OpenAI `tools`
/// request field (callable end-to-end invocation is the deferred `call_llm_v1`
/// path).
List<Map<String, Object?>> defaultToolCatalogue() => _basicTools()
    .map((tool) => <String, Object?>{
          'name': tool.name,
          'group': tool.group.name,
          'description': tool.description,
          'input_schema': tool.inputSchema,
        })
    .toList(growable: false);

// ── memory.* ─────────────────────────────────────────────────────────

/// The provenance identity tool-driven memory writes carry.
const String _toolProducer = 'tool';

final class _MemoryReadTool extends BrainTool {
  @override
  String get name => 'memory.read';
  @override
  ToolGroup get group => ToolGroup.memory;
  @override
  bool get readOnly => true;
  @override
  String get description =>
      'Recalls nodes from memory for a query (read-only).';
  @override
  Map<String, Object?> get inputSchema => const <String, Object?>{
        'type': 'object',
        'required': <Object?>['text'],
        'properties': <String, Object?>{
          'text': <String, Object?>{'type': 'string'},
          'k': <String, Object?>{'type': 'integer'},
        },
      };

  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async {
    final text = args['text'] as String;
    final k = (args['k'] as num?)?.toInt() ?? 8;
    final query = RecallQuery(
      text: text,
      modes: const <RecallMode>{RecallMode.bm25, RecallMode.vector},
      k: k,
    );
    ctx.budget.check('recall');
    final result = await ctx.memory.recall(query);
    ctx.budget.charge('recall');
    return <String, Object?>{
      'nodes': result.nodes.map(_nodeToMap).toList(growable: false),
      'count': result.nodes.length,
    };
  }
}

final class _MemoryWriteTool extends BrainTool {
  @override
  String get name => 'memory.write';
  @override
  ToolGroup get group => ToolGroup.memory;
  @override
  bool get readOnly => false;
  @override
  String get description =>
      'Persists a Conclusion / Claim / Question / Procedure node.';
  @override
  Map<String, Object?> get inputSchema => const <String, Object?>{
        'type': 'object',
        'required': <Object?>['typeName', 'values'],
        'properties': <String, Object?>{
          'typeName': <String, Object?>{'type': 'string'},
          'values': <String, Object?>{'type': 'object'},
        },
      };

  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async {
    final typeName = args['typeName'] as String;
    if (!writableNodeShapes.contains(typeName)) {
      throw NodeShapeNotWritable(
        typeName: typeName,
        allowed: writableNodeShapes,
      );
    }
    final values = (args['values'] as Map).cast<String, Object?>();
    ctx.budget.check('persist');
    final id = await ctx.memory.persist(
      NodeDraft(typeName: typeName, values: values),
      scope: const Scope(producer: _toolProducer),
    );
    ctx.budget.charge('persist');
    return <String, Object?>{'id': id.value};
  }
}

final class _MemoryDeleteTool extends BrainTool {
  @override
  String get name => 'memory.delete';
  @override
  ToolGroup get group => ToolGroup.memory;
  @override
  bool get readOnly => false;
  @override
  String get description =>
      'Demotes a node — reversible, never a hard delete.';
  @override
  Map<String, Object?> get inputSchema => const <String, Object?>{
        'type': 'object',
        'required': <Object?>['id'],
        'properties': <String, Object?>{
          'id': <String, Object?>{'type': 'string'},
          'reason': <String, Object?>{'type': 'string'},
        },
      };

  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async {
    final id = args['id'] as String;
    final reasonName = args['reason'] as String?;
    final reason = reasonName == null
        ? DemotionReason.operatorOverride
        : DemotionReason.values.byName(reasonName);
    ctx.budget.check('demote');
    await ctx.memory.demote(NodeId.fromString(id), reason);
    ctx.budget.charge('demote');
    return <String, Object?>{'demoted': id, 'reason': reason.name};
  }
}

// ── todo.* ───────────────────────────────────────────────────────────

final class _TodoListTool extends BrainTool {
  @override
  String get name => 'todo.list';
  @override
  ToolGroup get group => ToolGroup.todo;
  @override
  bool get readOnly => true;
  @override
  String get description => 'Lists the run-scoped todo entries.';
  @override
  Map<String, Object?> get inputSchema => const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{},
      };

  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async =>
      <String, Object?>{
        'todos': ctx.todos.list().map((e) => e.toMap()).toList(growable: false),
      };
}

final class _TodoAddTool extends BrainTool {
  @override
  String get name => 'todo.add';
  @override
  ToolGroup get group => ToolGroup.todo;
  @override
  bool get readOnly => false;
  @override
  String get description => 'Appends a run-scoped todo entry.';
  @override
  Map<String, Object?> get inputSchema => const <String, Object?>{
        'type': 'object',
        'required': <Object?>['text'],
        'properties': <String, Object?>{
          'text': <String, Object?>{'type': 'string'},
        },
      };

  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async =>
      <String, Object?>{'id': ctx.todos.add(args['text'] as String)};
}

final class _TodoUpdateTool extends BrainTool {
  @override
  String get name => 'todo.update';
  @override
  ToolGroup get group => ToolGroup.todo;
  @override
  bool get readOnly => false;
  @override
  String get description => 'Updates a todo entry by id.';
  @override
  Map<String, Object?> get inputSchema => const <String, Object?>{
        'type': 'object',
        'required': <Object?>['id'],
        'properties': <String, Object?>{
          'id': <String, Object?>{'type': 'string'},
          'text': <String, Object?>{'type': 'string'},
          'done': <String, Object?>{'type': 'boolean'},
        },
      };

  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async {
    final updated = ctx.todos.update(
      args['id'] as String,
      text: args['text'] as String?,
      done: args['done'] as bool?,
    );
    return <String, Object?>{'updated': updated};
  }
}

final class _TodoRemoveTool extends BrainTool {
  @override
  String get name => 'todo.remove';
  @override
  ToolGroup get group => ToolGroup.todo;
  @override
  bool get readOnly => false;
  @override
  String get description => 'Removes a todo entry by id.';
  @override
  Map<String, Object?> get inputSchema => const <String, Object?>{
        'type': 'object',
        'required': <Object?>['id'],
        'properties': <String, Object?>{
          'id': <String, Object?>{'type': 'string'},
        },
      };

  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async =>
      <String, Object?>{'removed': ctx.todos.remove(args['id'] as String)};
}

// ── file.* / grep.* ──────────────────────────────────────────────────

final class _FileReadTool extends BrainTool {
  @override
  String get name => 'file.read';
  @override
  ToolGroup get group => ToolGroup.file;
  @override
  bool get readOnly => true;
  @override
  String get description => 'Reads a UTF-8 file under the file-scope root.';
  @override
  Map<String, Object?> get inputSchema => const <String, Object?>{
        'type': 'object',
        'required': <Object?>['path'],
        'properties': <String, Object?>{
          'path': <String, Object?>{'type': 'string'},
        },
      };

  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async {
    final relative = args['path'] as String;
    final hits = _resolveWithinRoots(ctx.fileScopeRoots, relative);
    // Reads search the roots in order: the first root holding the file wins;
    // if none holds it yet, fall through to the primary so the caller sees a
    // normal "file not found" rather than a scope error.
    final hit = hits.firstWhere(
      (h) => File(h.path).existsSync(),
      orElse: () => hits.first,
    );
    final content = await File(hit.path).readAsString();
    return <String, Object?>{'path': relative, 'content': content};
  }
}

final class _FileWriteTool extends BrainTool {
  @override
  String get name => 'file.write';
  @override
  ToolGroup get group => ToolGroup.file;
  @override
  bool get readOnly => false;
  @override
  String get description => 'Writes a UTF-8 file under the file-scope root.';
  @override
  Map<String, Object?> get inputSchema => const <String, Object?>{
        'type': 'object',
        'required': <Object?>['path', 'content'],
        'properties': <String, Object?>{
          'path': <String, Object?>{'type': 'string'},
          'content': <String, Object?>{'type': 'string'},
        },
      };

  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async {
    final relative = args['path'] as String;
    final content = args['content'] as String;
    // Writes target the primary (first admitting) root — the earliest hit.
    final resolved = _resolveWithinRoots(ctx.fileScopeRoots, relative).first.path;
    final file = await File(resolved).create(recursive: true);
    await file.writeAsString(content);
    return <String, Object?>{'path': relative, 'bytesWritten': content.length};
  }
}

final class _GrepSearchTool extends BrainTool {
  @override
  String get name => 'grep.search';
  @override
  ToolGroup get group => ToolGroup.file;
  @override
  bool get readOnly => true;
  @override
  String get description =>
      'Searches files under the file-scope root for a substring.';
  @override
  Map<String, Object?> get inputSchema => const <String, Object?>{
        'type': 'object',
        'required': <Object?>['pattern'],
        'properties': <String, Object?>{
          'pattern': <String, Object?>{'type': 'string'},
          'path': <String, Object?>{'type': 'string'},
        },
      };

  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async {
    final pattern = args['pattern'] as String;
    final sub = args['path'] as String? ?? '.';
    // Discovery spans every root: scan each that admits the sub-path and
    // exists, rebasing matches onto that root. A missing dir is skipped, not an
    // error (a not-yet-created sub-path is a legitimate query).
    final hits = _resolveWithinRoots(ctx.fileScopeRoots, sub);
    final matches = <Map<String, Object?>>[];
    for (final hit in hits) {
      final directory = Directory(hit.path);
      if (!directory.existsSync()) {
        continue;
      }
      final entries = directory.listSync(recursive: true).whereType<File>();
      for (final file in entries) {
        final lines = await file.readAsLines();
        final relative = p.relative(file.path, from: hit.root);
        for (var i = 0; i < lines.length; i++) {
          if (lines[i].contains(pattern)) {
            matches.add(<String, Object?>{
              'file': relative,
              'line': i + 1,
              'text': lines[i],
            });
          }
        }
      }
    }
    return <String, Object?>{'matches': matches};
  }
}

final class _FileSearchTool extends BrainTool {
  @override
  String get name => 'file.search';
  @override
  ToolGroup get group => ToolGroup.file;
  @override
  bool get readOnly => true;
  @override
  String get description =>
      'Finds files by name under the file-scope root using a glob pattern '
      '(*, ?, [abc], [a-z]); complements grep.search (which scans contents).';
  @override
  Map<String, Object?> get inputSchema => const <String, Object?>{
        'type': 'object',
        'required': <Object?>['pattern'],
        'properties': <String, Object?>{
          'pattern': <String, Object?>{'type': 'string'},
          'path': <String, Object?>{'type': 'string'},
          'recursive': <String, Object?>{'type': 'boolean'},
          'caseSensitive': <String, Object?>{'type': 'boolean'},
        },
      };

  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async {
    final pattern = args['pattern'] as String;
    final sub = args['path'] as String? ?? '.';
    final recursive = args['recursive'] as bool? ?? true;
    final caseSensitive = args['caseSensitive'] as bool? ?? false;
    // Discovery spans every root that admits the sub-path. A missing search
    // directory is skipped (empty result), mirroring grep.search — not an
    // error: a not-yet-created sub-path is a legitimate query.
    final hits = _resolveWithinRoots(ctx.fileScopeRoots, sub);
    final matches = <String>[];
    for (final hit in hits) {
      if (!Directory(hit.path).existsSync()) {
        continue;
      }
      // dcli `find` returns absolute paths; re-base each onto its root so the
      // caller only ever sees containment-checked relative paths.
      matches.addAll(find(
        pattern,
        workingDirectory: hit.path,
        recursive: recursive,
        caseSensitive: caseSensitive,
      ).toList().map((abs) => p.relative(abs, from: hit.root)));
    }
    matches.sort();
    return <String, Object?>{'matches': matches};
  }
}

// ── web.* ────────────────────────────────────────────────────────────

final class _WebSearchTool extends BrainTool {
  @override
  String get name => 'web.search';
  @override
  ToolGroup get group => ToolGroup.web;
  @override
  bool get readOnly => true;
  @override
  String get description => 'Issues a substrate web search.';
  @override
  Map<String, Object?> get inputSchema => const <String, Object?>{
        'type': 'object',
        'required': <Object?>['query'],
        'properties': <String, Object?>{
          'query': <String, Object?>{'type': 'string'},
          'k': <String, Object?>{'type': 'integer'},
        },
      };

  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async {
    final web = ctx.web;
    if (web == null) {
      throw const ToolSurfaceUnavailable(surface: 'web', tool: 'web.search');
    }
    final k = (args['k'] as num?)?.toInt() ?? 10;
    return web.search(args['query'] as String, k: k);
  }
}

final class _WebFetchTool extends BrainTool {
  @override
  String get name => 'web.fetch';
  @override
  ToolGroup get group => ToolGroup.web;
  @override
  bool get readOnly => true;
  @override
  String get description => 'Fetches a URL via the substrate web client.';
  @override
  Map<String, Object?> get inputSchema => const <String, Object?>{
        'type': 'object',
        'required': <Object?>['url'],
        'properties': <String, Object?>{
          'url': <String, Object?>{'type': 'string'},
          'budgetBytes': <String, Object?>{'type': 'integer'},
        },
      };

  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async {
    final web = ctx.web;
    if (web == null) {
      throw const ToolSurfaceUnavailable(surface: 'web', tool: 'web.fetch');
    }
    final budgetBytes = (args['budgetBytes'] as num?)?.toInt();
    return web.fetch(args['url'] as String, budgetBytes: budgetBytes);
  }
}

// ── script.run_d4rt ──────────────────────────────────────────────────

final class _ScriptRunD4rtTool extends BrainTool {
  @override
  String get name => 'script.run_d4rt';
  @override
  ToolGroup get group => ToolGroup.script;
  @override
  bool get readOnly => false;
  @override
  String get description =>
      'Evaluates a nested sandboxed d4rt script returning JSON.';
  @override
  Map<String, Object?> get inputSchema => const <String, Object?>{
        'type': 'object',
        'required': <Object?>['source'],
        'properties': <String, Object?>{
          'source': <String, Object?>{'type': 'string'},
        },
      };

  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async {
    final engine = ctx.engine;
    if (engine == null) {
      throw const ToolSurfaceUnavailable(
        surface: 'engine',
        tool: 'script.run_d4rt',
      );
    }
    final result = await engine.runD4rtScript(args['source'] as String);
    if (!_isJsonSerialisable(result)) {
      throw ScriptResultNotJson(result.runtimeType.toString());
    }
    return <String, Object?>{'result': result};
  }
}

// ── procedure.* ──────────────────────────────────────────────────────

final class _ProcedureListTool extends BrainTool {
  @override
  String get name => 'procedure.list';
  @override
  ToolGroup get group => ToolGroup.procedure;
  @override
  bool get readOnly => true;
  @override
  String get description => 'Lists the procedures the store can serve.';
  @override
  Map<String, Object?> get inputSchema => const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{},
      };

  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async {
    final engine = ctx.engine;
    if (engine == null) {
      throw const ToolSurfaceUnavailable(
        surface: 'engine',
        tool: 'procedure.list',
      );
    }
    return <String, Object?>{'procedures': await engine.listProcedures()};
  }
}

final class _ProcedureRunTool extends BrainTool {
  @override
  String get name => 'procedure.run';
  @override
  ToolGroup get group => ToolGroup.procedure;
  @override
  bool get readOnly => false;
  @override
  String get description => 'Runs a procedure (depth-capped like any nested run).';
  @override
  Map<String, Object?> get inputSchema => const <String, Object?>{
        'type': 'object',
        'required': <Object?>['id'],
        'properties': <String, Object?>{
          'id': <String, Object?>{'type': 'string'},
          'inputs': <String, Object?>{'type': 'object'},
          'version': <String, Object?>{'type': 'integer'},
        },
      };

  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async {
    final engine = ctx.engine;
    if (engine == null) {
      throw const ToolSurfaceUnavailable(
        surface: 'engine',
        tool: 'procedure.run',
      );
    }
    final inputs = (args['inputs'] as Map?)?.cast<String, Object?>() ??
        const <String, Object?>{};
    final version = (args['version'] as num?)?.toInt();
    return engine.runProcedure(args['id'] as String, inputs, version: version);
  }
}

/// An explicit tool for one prominent verb (`plan` / `create` / `critique` /
/// `decide`) — a thin, fixed-id alias of `procedure.run` (Todo 4 / § 11).
///
/// Where `procedure.run` takes an arbitrary `id` and an `inputs` sub-map, a
/// verb tool fixes the id to `<verb>_v1` and forwards the caller's whole
/// argument map straight through as the procedure inputs. Until the real loop
/// ships (Todo 8/9) the target is the clear-error stub, so invoking the tool
/// surfaces a failed result (the stub's `ProcedureNotImplemented` is swallowed
/// into a failed result on the tool path; the typed signal lives on the nested
/// run's trail).
final class _ProcedureVerbTool extends BrainTool {
  _ProcedureVerbTool(this.verb);

  /// The bare verb this tool runs (`plan` / `create` / `critique` / `decide`).
  final String verb;

  /// The fixed procedure id the verb resolves to.
  String get _procedureId => '${verb}_v1';

  @override
  String get name => 'procedure.$verb';
  @override
  ToolGroup get group => ToolGroup.procedure;
  @override
  bool get readOnly => false;
  @override
  String get description =>
      'Runs the $verb loop ($_procedureId) — a fixed-id alias of '
      'procedure.run; the caller inputs are forwarded straight through.';
  @override
  Map<String, Object?> get inputSchema => const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{},
      };

  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async {
    final engine = ctx.engine;
    if (engine == null) {
      throw ToolSurfaceUnavailable(surface: 'engine', tool: name);
    }
    return engine.runProcedure(_procedureId, args);
  }
}

// ── shared helpers ───────────────────────────────────────────────────

/// The flattened map a `memory.read` node carries.
Map<String, Object?> _nodeToMap(Node node) => <String, Object?>{
      'id': node.id.value,
      'typeName': node.typeName,
      'values': node.values,
      'status': node.status.name,
    };

/// The absolute, normalised form of [root].
String _normalizedRoot(String root) => p.normalize(p.absolute(root));

/// A root that admits a resolved path, paired with that resolved path.
///
/// [root] is the normalised root (so callers can rebase matches back onto it);
/// [path] is the resolved, containment-checked absolute path under that root.
typedef _ScopeHit = ({String root, String path});

/// Resolves [relative] against every configured root, returning one hit per
/// root whose bounds the resolved path stays within (PE-1).
///
/// The file-scope sandbox is a *union* of roots: a `..` segment, an absolute
/// path, or any other escape produces a path outside a given root, which is
/// dropped for that root. [FileScopeViolation] is raised only when the path
/// escapes *every* root — before the caller touches the filesystem. Hits keep
/// the roots' configured order, so the first hit is the earliest-priority root
/// that admits the path (the write target, the first read candidate).
List<_ScopeHit> _resolveWithinRoots(List<String> roots, String relative) {
  final hits = <_ScopeHit>[];
  for (final root in roots) {
    final normalizedRoot = _normalizedRoot(root);
    final candidate = p.normalize(p.join(normalizedRoot, relative));
    final within =
        candidate == normalizedRoot || p.isWithin(normalizedRoot, candidate);
    if (within) {
      hits.add((root: normalizedRoot, path: candidate));
    }
  }
  if (hits.isEmpty) {
    throw FileScopeViolation(roots: roots, requested: relative);
  }
  return hits;
}

/// Whether [value] is JSON-serialisable (the `script.run_d4rt` result rule).
bool _isJsonSerialisable(Object? value) {
  if (value == null || value is num || value is String || value is bool) {
    return true;
  }
  if (value is List) return value.every(_isJsonSerialisable);
  if (value is Map) {
    return value.keys.every((k) => k is String) &&
        value.values.every(_isJsonSerialisable);
  }
  return false;
}
