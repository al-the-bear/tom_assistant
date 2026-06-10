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
import 'package:tom_core_agentic/tom_core_agentic.dart'
    show PathScope, ScopedPath;
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
import 'tool_process_surface.dart';
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
      _FileEditTool(),
      _FileDeleteTool(),
      _FileDiffTool(),
      _GrepSearchTool(),
      _FileSearchTool(),
      // Creation code-understanding + test families (creation_specification.md
      // § 5.2 / § 5.3): each names one fixed executable run through the
      // allow-listed `ToolProcessSurface` — no general shell (§ 5.4).
      _AnalyzeDartTool(),
      _AnalyzeFormatTool(),
      _AnalyzeSchemaTool(),
      _TestRunTool(),
      _TestBaselineTool(),
      _WebSearchTool(),
      _WebFetchTool(),
      _ScriptRunD4rtTool(),
      _ProcedureListTool(),
      _ProcedureRunTool(),
      _DreamControlTool(),
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

final class _FileEditTool extends BrainTool {
  @override
  String get name => 'file.edit';
  @override
  ToolGroup get group => ToolGroup.file;
  @override
  bool get readOnly => false;
  @override
  String get description =>
      'Applies a structured edit (replace / insert / delete by 1-based line '
      'range) to a file under the file-scope root.';
  @override
  Map<String, Object?> get inputSchema => const <String, Object?>{
        'type': 'object',
        'required': <Object?>['path', 'op', 'start'],
        'properties': <String, Object?>{
          'path': <String, Object?>{'type': 'string'},
          'op': <String, Object?>{
            'type': 'string',
            'enum': <Object?>['replace', 'insert', 'delete'],
          },
          'start': <String, Object?>{'type': 'integer'},
          'end': <String, Object?>{'type': 'integer'},
          'text': <String, Object?>{'type': 'string'},
        },
      };

  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async {
    final relative = args['path'] as String;
    final op = args['op'] as String;
    final start = (args['start'] as num).toInt();
    final end = (args['end'] as num?)?.toInt() ?? start;
    final text = args['text'] as String? ?? '';
    final hit = _resolveTarget(ctx, relative);
    final file = File(hit.path);
    final lines = file.existsSync() ? await file.readAsLines() : <String>[];
    final newLines = text.isEmpty ? <String>[] : text.split('\n');

    switch (op) {
      case 'replace':
        _requireRange(op, start, end, lines.length);
        lines.replaceRange(start - 1, end, newLines);
      case 'delete':
        _requireRange(op, start, end, lines.length);
        lines.removeRange(start - 1, end);
      case 'insert':
        // Insert *before* line `start`; `start == length + 1` appends.
        if (start < 1 || start > lines.length + 1) {
          throw ArgumentError.value(
              start, 'start', 'file.edit insert line out of range');
        }
        lines.insertAll(start - 1, newLines);
      default:
        throw ArgumentError.value(op, 'op', 'unknown file.edit op');
    }

    // Text files end with a trailing newline by POSIX convention.
    final content = lines.isEmpty ? '' : '${lines.join('\n')}\n';
    await File(hit.path).writeAsString(content);
    return <String, Object?>{
      'path': relative,
      'op': op,
      'bytesWritten': content.length,
    };
  }
}

final class _FileDeleteTool extends BrainTool {
  @override
  String get name => 'file.delete';
  @override
  ToolGroup get group => ToolGroup.file;
  @override
  bool get readOnly => false;
  @override
  String get description =>
      'Removes a file under the file-scope root — the reversible counterpart '
      'to file.write, so a rejected draft can be rolled back '
      '(creation_specification.md § 4.7). Idempotent: a missing target is not '
      'an error.';
  @override
  Map<String, Object?> get inputSchema => _pathRequiredSchema;

  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async {
    final relative = args['path'] as String;
    // Resolve within scope (an escaping path raises FileScopeViolation before
    // any filesystem touch), preferring the root where the target exists so the
    // rollback undoes the write that actually landed.
    final hit = _resolveTarget(ctx, relative);
    final file = File(hit.path);
    final existed = file.existsSync();
    if (existed) await file.delete();
    return <String, Object?>{'path': relative, 'deleted': existed};
  }
}

final class _FileDiffTool extends BrainTool {
  @override
  String get name => 'file.diff';
  @override
  ToolGroup get group => ToolGroup.file;
  @override
  bool get readOnly => true;
  @override
  String get description =>
      'Produces a unified-style line diff between a file under the file-scope '
      'root and a proposed new content (read-only; writes nothing).';
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
    final proposed = args['content'] as String;
    final hit = _resolveTarget(ctx, relative);
    final file = File(hit.path);
    final current = file.existsSync() ? await file.readAsString() : '';
    final body = _unifiedDiffBody(_splitLines(current), _splitLines(proposed));
    final changed = body.any((line) => !line.startsWith(' '));
    final diff = <String>['--- a/$relative', '+++ b/$relative', ...body];
    return <String, Object?>{
      'path': relative,
      'changed': changed,
      'diff': diff.join('\n'),
    };
  }
}

// ── analyze.* ────────────────────────────────────────────────────────

final class _AnalyzeDartTool extends BrainTool {
  @override
  String get name => 'analyze.dart';
  @override
  ToolGroup get group => ToolGroup.analyze;
  @override
  bool get readOnly => true;
  @override
  String get description =>
      'Runs `dart analyze` over a path under the file-scope root '
      '(allow-listed process; read-only).';
  @override
  Map<String, Object?> get inputSchema => _pathOnlySchema;

  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async {
    final relative = args['path'] as String? ?? '.';
    final hit = _resolveTarget(ctx, relative);
    final result = await _runAllowed(
      ctx,
      name,
      'dart',
      <String>['analyze', hit.path],
      workingDirectory: hit.root,
    );
    return _processResultMap(relative, result);
  }
}

final class _AnalyzeFormatTool extends BrainTool {
  @override
  String get name => 'analyze.format';
  @override
  ToolGroup get group => ToolGroup.analyze;
  @override
  bool get readOnly => true;
  @override
  String get description =>
      'Runs `dart format --set-exit-if-changed` over a path under the '
      'file-scope root (allow-listed process; reports formatting drift).';
  @override
  Map<String, Object?> get inputSchema => _pathOnlySchema;

  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async {
    final relative = args['path'] as String? ?? '.';
    final hit = _resolveTarget(ctx, relative);
    final result = await _runAllowed(
      ctx,
      name,
      'dart',
      <String>['format', '--set-exit-if-changed', hit.path],
      workingDirectory: hit.root,
    );
    return _processResultMap(relative, result);
  }
}

final class _AnalyzeSchemaTool extends BrainTool {
  @override
  String get name => 'analyze.schema';
  @override
  ToolGroup get group => ToolGroup.analyze;
  @override
  bool get readOnly => true;
  @override
  String get description =>
      'Validates a YAML or JSON file under the file-scope root against its '
      'registered schema via the `tom` CLI (allow-listed process; read-only).';
  @override
  Map<String, Object?> get inputSchema => _pathRequiredSchema;

  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async {
    final relative = args['path'] as String;
    final hit = _resolveTarget(ctx, relative);
    final result = await _runAllowed(
      ctx,
      name,
      'tom',
      <String>['schema', 'validate', hit.path],
      workingDirectory: hit.root,
    );
    return _processResultMap(relative, result);
  }
}

// ── test.* ───────────────────────────────────────────────────────────

final class _TestRunTool extends BrainTool {
  @override
  String get name => 'test.run';
  @override
  ToolGroup get group => ToolGroup.test;
  @override
  bool get readOnly => false;
  @override
  String get description =>
      'Runs `testkit :test` in a directory under the file-scope root '
      '(allow-listed process).';
  @override
  Map<String, Object?> get inputSchema => _pathOnlySchema;

  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async {
    final relative = args['path'] as String? ?? '.';
    final hit = _resolveTarget(ctx, relative);
    final result = await _runAllowed(
      ctx,
      name,
      'testkit',
      const <String>[':test'],
      workingDirectory: hit.path,
    );
    return _processResultMap(relative, result);
  }
}

final class _TestBaselineTool extends BrainTool {
  @override
  String get name => 'test.baseline';
  @override
  ToolGroup get group => ToolGroup.test;
  @override
  bool get readOnly => false;
  @override
  String get description =>
      'Runs `testkit :baseline` in a directory under the file-scope root to '
      'create a new baseline (allow-listed process).';
  @override
  Map<String, Object?> get inputSchema => _pathOnlySchema;

  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async {
    final relative = args['path'] as String? ?? '.';
    final hit = _resolveTarget(ctx, relative);
    final result = await _runAllowed(
      ctx,
      name,
      'testkit',
      const <String>[':baseline'],
      workingDirectory: hit.path,
    );
    return _processResultMap(relative, result);
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

// ── dream.control ────────────────────────────────────────────────────

/// The default forced-dreaming period a `dream.control` `start` uses when the
/// caller names no `durationMinutes` (one hour).
const int _defaultDreamMinutes = 60;

/// One tool for the four dreaming-control actions (`memory_specification.md`
/// § 9.7): `start` dreaming for a period, `stop` it, `resume` the configured
/// schedule, and report `status`. Routes through the optional
/// [ToolContext.dream] surface; a cognition booted without a dreaming cadence
/// carries none, and the tool raises `ToolSurfaceUnavailable` (the same shape
/// the `web.*` / `procedure.*` tools take when their surface is absent).
///
/// Every action returns the resulting status map, so `start` / `stop` /
/// `resume` confirm the new dreaming state in the same call. `resume` accepts
/// the alias `continue` (the user's "continue an interrupted schedule" wording).
final class _DreamControlTool extends BrainTool {
  @override
  String get name => 'dream.control';
  @override
  ToolGroup get group => ToolGroup.dream;
  @override
  bool get readOnly => false;
  @override
  String get description =>
      'Controls the background dreaming cadence: start dreaming for a period, '
      'stop it, resume the configured schedule, or report whether the brain is '
      'dreaming.';
  @override
  Map<String, Object?> get inputSchema => const <String, Object?>{
        'type': 'object',
        'required': <Object?>['action'],
        'properties': <String, Object?>{
          'action': <String, Object?>{
            'type': 'string',
            'enum': <Object?>['start', 'stop', 'resume', 'continue', 'status'],
          },
          'durationMinutes': <String, Object?>{'type': 'integer'},
        },
      };

  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async {
    final dream = ctx.dream;
    if (dream == null) {
      throw const ToolSurfaceUnavailable(
        surface: 'dream',
        tool: 'dream.control',
      );
    }
    final action = args['action'] as String;
    switch (action) {
      case 'start':
        final minutes =
            (args['durationMinutes'] as num?)?.toInt() ?? _defaultDreamMinutes;
        if (minutes <= 0) {
          throw ArgumentError.value(minutes, 'durationMinutes',
              'dream.control start requires a positive duration');
        }
        dream.forceFor(Duration(minutes: minutes));
      case 'stop':
        dream.suspend();
      case 'resume':
      case 'continue':
        dream.resume();
      case 'status':
        break;
      default:
        throw ArgumentError.value(
            action, 'action', 'unknown dream.control action');
    }
    return dream.dreamStatus();
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

/// The input schema for a process tool whose only argument is an optional
/// `path` (defaulting to the primary root).
const Map<String, Object?> _pathOnlySchema = <String, Object?>{
  'type': 'object',
  'properties': <String, Object?>{
    'path': <String, Object?>{'type': 'string'},
  },
};

/// The input schema for a process tool whose `path` argument is required.
const Map<String, Object?> _pathRequiredSchema = <String, Object?>{
  'type': 'object',
  'required': <Object?>['path'],
  'properties': <String, Object?>{
    'path': <String, Object?>{'type': 'string'},
  },
};

/// Resolves [relative] under the file-scope roots, preferring the first root
/// where the target already exists (a file *or* a directory) and falling back
/// to the primary root otherwise. The containment check still applies (an
/// escaping path raises `FileScopeViolation` inside `_resolveWithinRoots`).
_ScopeHit _resolveTarget(ToolContext ctx, String relative) {
  final hits = _resolveWithinRoots(ctx.fileScopeRoots, relative);
  return hits.firstWhere(
    (h) => File(h.path).existsSync() || Directory(h.path).existsSync(),
    orElse: () => hits.first,
  );
}

/// Runs [executable] with [arguments] through the context's allow-listed
/// [ToolProcessSurface], raising `ToolSurfaceUnavailable` when the run carries
/// none. The surface — not this helper — enforces the executable allow-list,
/// so "no general shell" (`creation_specification.md` § 5.4) holds even though
/// the call site names the executable.
Future<ProcessRunResult> _runAllowed(
  ToolContext ctx,
  String toolName,
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) {
  final process = ctx.process;
  if (process == null) {
    throw ToolSurfaceUnavailable(surface: 'process', tool: toolName);
  }
  return process.run(executable, arguments,
      workingDirectory: workingDirectory);
}

/// The JSON-serialisable shape an `analyze.*` / `test.*` tool returns.
Map<String, Object?> _processResultMap(String relative, ProcessRunResult r) =>
    <String, Object?>{
      'path': relative,
      'exitCode': r.exitCode,
      'ok': r.ok,
      'stdout': r.stdout,
      'stderr': r.stderr,
    };

/// Splits [text] into lines, dropping a single trailing newline so a file that
/// ends with `\n` does not yield a spurious trailing empty line in the diff.
List<String> _splitLines(String text) {
  if (text.isEmpty) return const <String>[];
  final lines = text.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  return lines;
}

/// Validates that the 1-based inclusive `[start, end]` line range is within an
/// [length]-line file for the `replace` / `delete` ops.
void _requireRange(String op, int start, int end, int length) {
  if (start < 1 || end < start || end > length) {
    throw ArgumentError(
        'file.edit $op range [$start, $end] is outside a $length-line file');
  }
}

/// Builds the body of a unified-style diff (lines prefixed ` `/`-`/`+`) between
/// [a] and [b] via a longest-common-subsequence walk.
///
/// Dependency-free on purpose: the package's dependency set is locked by
/// `dependency_surface_test.dart`, so a diff library is not pulled in. The LCS
/// table is `O(n·m)` — bounded for the small files creation handles.
List<String> _unifiedDiffBody(List<String> a, List<String> b) {
  final n = a.length;
  final m = b.length;
  final lcs = List<List<int>>.generate(
      n + 1, (_) => List<int>.filled(m + 1, 0),
      growable: false);
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      lcs[i][j] = a[i] == b[j]
          ? lcs[i + 1][j + 1] + 1
          : (lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
    }
  }
  final out = <String>[];
  var i = 0;
  var j = 0;
  while (i < n && j < m) {
    if (a[i] == b[j]) {
      out.add(' ${a[i]}');
      i++;
      j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      out.add('-${a[i]}');
      i++;
    } else {
      out.add('+${b[j]}');
      j++;
    }
  }
  while (i < n) {
    out.add('-${a[i]}');
    i++;
  }
  while (j < m) {
    out.add('+${b[j]}');
    j++;
  }
  return out;
}

/// A root that admits a resolved path, paired with that resolved path — the
/// [ScopedPath] shape from `tom_core_agentic`'s [PathScope], aliased locally so
/// the tool helpers keep their established name.
typedef _ScopeHit = ScopedPath;

/// Resolves [relative] against every configured root, returning one hit per
/// root whose bounds the resolved path stays within (PE-1).
///
/// The normalisation-and-containment rule is the domain-free [PathScope]: a
/// *union* of roots where a `..` segment, an absolute path, or any other escape
/// drops out of the roots it leaves. The brain's breach policy stays here —
/// [FileScopeViolation] is raised, before the caller touches the filesystem,
/// when the path escapes *every* root, or when no roots are configured (a scope
/// that admits nothing). Hits keep the roots' configured order, so the first hit
/// is the earliest-priority root that admits the path (the write target, the
/// first read candidate).
List<_ScopeHit> _resolveWithinRoots(List<String> roots, String relative) {
  if (roots.isEmpty) {
    throw FileScopeViolation(roots: roots, requested: relative);
  }
  final hits = PathScope(roots).resolve(relative);
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
