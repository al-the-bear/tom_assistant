// Extension F step 4 — the tool-calling core: `BrainTool`, `ToolGroup`,
// `ToolRegistry`, `ToolContext`, and `args`-against-`inputSchema`
// validation (`tom_brain_procedure_prototype_specification.md` § 21.2;
// `prototype_tools_mcp_extension_plan.md` step 4).
//
// What this suite locks:
//
//   F.4-1 — register + look up + list (incl. the `group` filter).
//   F.4-2 — a tool reaches *nothing* past its `ToolContext` (PE-1): the
//           context exposes only the three bridges (budget ledger, memory
//           client, file-scope root) and the root is a plain `String` path,
//           never a raw `dart:io` `File`/`Directory` handle.
//   F.4-3 — `inputSchema` validation rejects malformed `args` (missing a
//           required key, wrong scalar type, unknown key under
//           `additionalProperties: false`) and accepts well-formed `args`.
//   F.4-4 — duplicate registration is refused with a typed error.

import 'dart:io';

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  group('F.4-1 ToolRegistry register / lookup / list', () {
    test('a registered tool is found by name and absent names are null', () {
      final registry = ToolRegistry();
      final tool = _EchoTool();
      registry.register(tool);

      expect(registry.lookup('echo'), same(tool));
      expect(registry.lookup('nope'), isNull);
      expect(registry.contains('echo'), isTrue);
      expect(registry.contains('nope'), isFalse);
    });

    test('list returns every registered tool', () {
      final registry = ToolRegistry()
        ..register(_EchoTool())
        ..register(_MemoryReadTool());

      expect(
        registry.list().map((t) => t.name),
        unorderedEquals(<String>['echo', 'memory.read']),
      );
      expect(registry.names, unorderedEquals(<String>['echo', 'memory.read']));
    });

    test('list filters by group', () {
      final registry = ToolRegistry()
        ..register(_EchoTool()) // group: script
        ..register(_MemoryReadTool()); // group: memory

      expect(
        registry.list(group: ToolGroup.memory).map((t) => t.name),
        equals(<String>['memory.read']),
      );
      expect(
        registry.list(group: ToolGroup.web),
        isEmpty,
      );
    });

    test('ToolGroup members map to their wire `.name`', () {
      // The eight groups the policy step (§ 21.8) keys on.
      expect(
        ToolGroup.values.map((g) => g.name),
        containsAll(<String>[
          'memory',
          'file',
          'todo',
          'web',
          'procedure',
          'script',
          'mcp',
          'vscode',
        ]),
      );
      expect(ToolGroup.values, hasLength(8));
    });
  });

  group('F.4-4 duplicate registration', () {
    test('registering the same name twice is refused with a typed error', () {
      final registry = ToolRegistry()..register(_EchoTool());

      expect(
        () => registry.register(_EchoTool()),
        throwsA(isA<ToolAlreadyRegistered>()
            .having((e) => e.name, 'name', 'echo')
            .having((e) => e.code, 'code', toolAlreadyRegisteredCode)
            .having((e) => e.toString(), 'toString',
                contains(toolAlreadyRegisteredCode))),
      );
    });
  });

  group('F.4-2 ToolContext is the whole effect surface (PE-1)', () {
    test('exposes exactly the three bridges and nothing more', () {
      final ctx = _context(fileScopeRoot: '/tmp/scope');

      expect(ctx.budget, isA<BudgetLedger>());
      expect(ctx.memory, isA<TomBrainMemoryClient>());
      expect(ctx.fileScopeRoot, '/tmp/scope');
    });

    test('fileScopeRoot is a plain String path, never a dart:io handle', () {
      final ctx = _context(fileScopeRoot: '/tmp/scope');

      // The Verify clause: no raw dart:io / network handle leaks through the
      // context. A String path keeps the file sandbox a value, not an open
      // capability — full path-escape enforcement lands with the file tools
      // (step 7), but the *handle* must never be reachable from here.
      expect(ctx.fileScopeRoot, isA<String>());
      expect(ctx.fileScopeRoot, isNot(isA<Directory>()));
      expect(ctx.fileScopeRoot, isNot(isA<File>()));
    });

    test('a tool runs using only what its context hands it', () async {
      final ctx = _context(fileScopeRoot: '/tmp/scope');
      final result = await _EchoTool().run(<String, Object?>{'value': 'hi'}, ctx);

      expect(result, <String, Object?>{'echoed': 'hi', 'root': '/tmp/scope'});
    });
  });

  group('F.4-3 inputSchema validation', () {
    final schema = <String, Object?>{
      'type': 'object',
      'required': <Object?>['value'],
      'additionalProperties': false,
      'properties': <String, Object?>{
        'value': <String, Object?>{'type': 'string'},
        'count': <String, Object?>{'type': 'integer'},
      },
    };

    test('well-formed args validate (null = no error)', () {
      expect(
        validateToolArgs(schema, <String, Object?>{'value': 'x'}),
        isNull,
      );
      expect(
        validateToolArgs(schema, <String, Object?>{'value': 'x', 'count': 3}),
        isNull,
      );
    });

    test('a missing required key is rejected', () {
      final error = validateToolArgs(schema, <String, Object?>{'count': 3});
      expect(error, isNotNull);
      expect(error, contains('value'));
    });

    test('a wrong scalar type is rejected', () {
      final error =
          validateToolArgs(schema, <String, Object?>{'value': 'x', 'count': 'no'});
      expect(error, isNotNull);
      expect(error, contains('count'));
    });

    test('an unknown key under additionalProperties:false is rejected', () {
      final error = validateToolArgs(
          schema, <String, Object?>{'value': 'x', 'stray': true});
      expect(error, isNotNull);
      expect(error, contains('stray'));
    });

    test('tool.invoke-style validation gates the run', () {
      // The §21.2 contract: invoke validates `args` against `input_schema`
      // before running. We model that gate directly on the tool's schema.
      final tool = _EchoTool();
      expect(
        validateToolArgs(tool.inputSchema, <String, Object?>{}),
        isNotNull,
        reason: 'echo requires `value`',
      );
      expect(
        validateToolArgs(tool.inputSchema, <String, Object?>{'value': 'ok'}),
        isNull,
      );
    });
  });
}

ToolContext _context({required String fileScopeRoot}) => ToolContext(
      budget: BudgetLedger(ProcedureBudget(const <String, int>{'toolCalls': 12})),
      memory: _StubMemory(),
      fileScopeRoot: fileScopeRoot,
    );

/// A trivial tool that reaches nothing past its [ToolContext]: it reads its
/// argument and the context's file-scope root, and returns a plain map.
final class _EchoTool extends BrainTool {
  @override
  String get name => 'echo';

  @override
  ToolGroup get group => ToolGroup.script;

  @override
  bool get readOnly => true;

  @override
  String get description => 'Echoes its `value` argument back.';

  @override
  Map<String, Object?> get inputSchema => <String, Object?>{
        'type': 'object',
        'required': <Object?>['value'],
        'properties': <String, Object?>{
          'value': <String, Object?>{'type': 'string'},
        },
      };

  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async =>
      <String, Object?>{'echoed': args['value'], 'root': ctx.fileScopeRoot};
}

final class _MemoryReadTool extends BrainTool {
  @override
  String get name => 'memory.read';

  @override
  ToolGroup get group => ToolGroup.memory;

  @override
  bool get readOnly => true;

  @override
  String get description => 'Reads from memory.';

  @override
  Map<String, Object?> get inputSchema => const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{},
      };

  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async => null;
}

/// Minimal `TomBrainMemoryClient` stub — the tool core never calls it; it only
/// needs to be the declared type the context carries. Unused members fall
/// through to `noSuchMethod`.
class _StubMemory implements TomBrainMemoryClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
