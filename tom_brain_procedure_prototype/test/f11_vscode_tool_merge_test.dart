// Extension F step 13 — merging the VS Code extension tools into the registry
// (`tom_brain_procedure_prototype_specification.md` § 21.8;
// `prototype_tools_mcp_extension_plan.md` step 13).
//
// When the prototype runs as the CLI server colocated with a VS Code
// extension, each of the extension's tools (`TomToolsApi`, socket JSON-RPC)
// is wrapped as a `BrainTool` and registered in the `ToolRegistry`. Because
// `TomToolsApi`'s `ToolDefinitionJson {name, description, input_schema}`
// already matches § 21.2's tool shape, the merge is uniform — a VS Code tool
// and a built-in tool are indistinguishable to `tool.list` / `tool.invoke`,
// and the same `ToolPolicy` (step 5) governs both.
//
// The prototype stays decoupled from `tom_vscode_scripting_api`: the merge
// reaches the extension only through the `VsCodeToolSource` port (the
// host-side seam the real socket adapter implements at the colocation wiring
// step, exactly as `ToolEngineSurface` fronts the engine). A merged tool
// routes its effect through the run's optional `ToolContext.vscode` surface
// (PE-1) — it captures no live capability of its own.
//
// What this suite locks:
//
//   F.11-1 — `mergeVsCodeTools(enabled: true)` registers each source tool as
//            a `vscode`-group `BrainTool`; both appear in `tool.list`.
//   F.11-2 — a merged tool is callable via `tool.invoke`, routing through the
//            run's `VsCodeToolSource` (the stub records the call).
//   F.11-3 — `enabled: false` (profile off) merges nothing.
//   F.11-4 — `deny: [vscode.todo.*]` under profile `all` removes the editor's
//            todo tool from `tool.list` while keeping the in-process `todo.*`
//            and the other VS Code tool (the § 21.8 motivating case).
//   F.11-5 — a denied VS Code tool invoked directly returns `{ok: false}`
//            (policy re-checked at invoke).
//   F.11-6 — a `vscode` tool invoked with no `ToolContext.vscode` surface
//            raises `ToolSurfaceUnavailable` (PE-1 wiring guard).

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart'
    show TomBrainMemoryClient;

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';

void main() {
  group('F.11-1 merge registers VS Code tools as vscode-group BrainTools', () {
    test('both source tools appear in tool.list with group "vscode"', () async {
      final source = _StubVsCodeToolSource(<VsCodeToolDefinition>[
        _def('vscode.echo'),
        _def('vscode.peek'),
      ]);
      final bridge = await _mergedBridge(source: source, enabled: true);

      final listed = await bridge.list();
      final byName = <String, Map<String, Object?>>{
        for (final t in listed) t['name'] as String: t,
      };

      expect(byName.keys, containsAll(<String>['vscode.echo', 'vscode.peek']));
      expect(byName['vscode.echo']!['group'], 'vscode');
      expect(byName['vscode.peek']!['group'], 'vscode');
      expect(byName['vscode.echo']!['input_schema'], isA<Map<String, Object?>>());
    });
  });

  group('F.11-2 a merged tool is callable through tool.invoke', () {
    test('invoke routes through the run VsCodeToolSource', () async {
      final source = _StubVsCodeToolSource(<VsCodeToolDefinition>[
        _def('vscode.echo'),
      ]);
      final bridge = await _mergedBridge(source: source, enabled: true);

      final result = await bridge.invoke(
        'vscode.echo',
        <String, Object?>{'value': 'hi'},
      );

      expect(result['ok'], isTrue);
      expect(result['result'], 'invoked:vscode.echo');
      expect(source.invocations['vscode.echo'], <String, Object?>{'value': 'hi'},
          reason: 'the tool routed its effect through the vscode surface');
    });
  });

  group('F.11-3 profile-off merges nothing', () {
    test('enabled: false leaves the registry empty', () async {
      final source = _StubVsCodeToolSource(<VsCodeToolDefinition>[
        _def('vscode.echo'),
        _def('vscode.peek'),
      ]);
      final bridge = await _mergedBridge(source: source, enabled: false);

      expect(await bridge.list(), isEmpty);
    });
  });

  group('F.11-4 deny [vscode.todo.*] prefers the in-process todo tool', () {
    test('the editor todo tool is hidden; the in-process one and the other '
        'VS Code tool remain', () async {
      final source = _StubVsCodeToolSource(<VsCodeToolDefinition>[
        _def('vscode.todo.add'),
        _def('vscode.echo'),
      ]);
      final bridge = await _mergedBridge(
        source: source,
        enabled: true,
        extra: <BrainTool>[_InProcessTodoTool()],
        policy: const ToolPolicy(
          ToolPolicyProfile.all,
          deny: <String>['vscode.todo.*'],
        ),
      );

      final names = (await bridge.list()).map((t) => t['name']).toSet();

      expect(names, contains('todo.add'),
          reason: 'the in-process todo.* wins (§ 21.8)');
      expect(names, contains('vscode.echo'),
          reason: 'a non-denied VS Code tool stays merged');
      expect(names, isNot(contains('vscode.todo.add')),
          reason: 'the editor todo tool is denied');
    });
  });

  group('F.11-5 a denied VS Code tool invoked directly is refused', () {
    test('invoke of a denied name returns {ok: false}', () async {
      final source = _StubVsCodeToolSource(<VsCodeToolDefinition>[
        _def('vscode.todo.add'),
      ]);
      final bridge = await _mergedBridge(
        source: source,
        enabled: true,
        policy: const ToolPolicy(
          ToolPolicyProfile.all,
          deny: <String>['vscode.todo.*'],
        ),
      );

      final result = await bridge.invoke(
        'vscode.todo.add',
        <String, Object?>{'value': 'x'},
      );

      expect(result['ok'], isFalse);
      expect(result['error'], isA<String>());
      expect(source.invocations, isEmpty,
          reason: 'a policy-denied call never reaches the tool body');
    });
  });

  group('F.11-6 a vscode tool needs the vscode surface', () {
    test('invoke with no ToolContext.vscode raises ToolSurfaceUnavailable',
        () async {
      final source = _StubVsCodeToolSource(<VsCodeToolDefinition>[
        _def('vscode.echo'),
      ]);
      // Merge against the source, but build the bridge's context WITHOUT a
      // vscode surface — the wiring guard must fire on invoke.
      final registry = ToolRegistry();
      await mergeVsCodeTools(registry, source, enabled: true);
      final bridge = ToolBridge(
        registry,
        const ToolPolicy(ToolPolicyProfile.all),
        ToolContext(
          budget: BudgetLedger(ProcedureBudget(const <String, int>{})),
          memory: _StubMemoryClient(),
          fileScopeRoot: '/tom-brain-engine',
        ),
      );

      await expectLater(
        bridge.invoke('vscode.echo', <String, Object?>{'value': 'x'}),
        throwsA(isA<ToolSurfaceUnavailable>()),
      );
    });
  });
}

// ── helpers ──────────────────────────────────────────────────────────

/// A `VsCodeToolDefinition` with a one-string-arg schema named after [name].
VsCodeToolDefinition _def(String name) => VsCodeToolDefinition(
      name: name,
      description: 'VS Code tool $name',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'value': <String, Object?>{'type': 'string'},
        },
      },
    );

/// Builds a [ToolBridge] over a registry seeded by merging [source] (gated by
/// [enabled]) plus any [extra] built-in tools, under [policy] (default `all`),
/// with a [ToolContext] carrying [source] as its `vscode` surface.
Future<ToolBridge> _mergedBridge({
  required VsCodeToolSource source,
  required bool enabled,
  List<BrainTool> extra = const <BrainTool>[],
  ToolPolicy policy = const ToolPolicy(ToolPolicyProfile.all),
}) async {
  final registry = ToolRegistry();
  for (final tool in extra) {
    registry.register(tool);
  }
  await mergeVsCodeTools(registry, source, enabled: enabled);
  final context = ToolContext(
    budget: BudgetLedger(ProcedureBudget(const <String, int>{})),
    memory: _StubMemoryClient(),
    fileScopeRoot: '/tom-brain-engine',
    vscode: source,
  );
  return ToolBridge(registry, policy, context);
}

/// A stub VS Code tool source: lists [tools] and records each invocation,
/// returning a deterministic `invoked:<name>` marker.
final class _StubVsCodeToolSource implements VsCodeToolSource {
  final List<VsCodeToolDefinition> tools;
  final Map<String, Map<String, Object?>> invocations =
      <String, Map<String, Object?>>{};

  _StubVsCodeToolSource(this.tools);

  @override
  Future<List<VsCodeToolDefinition>> listTools() async => tools;

  @override
  Future<String> invokeTool(String name, Map<String, Object?> arguments) async {
    invocations[name] = arguments;
    return 'invoked:$name';
  }
}

/// The brain's own in-process `todo.add` (group `todo`) — the tool the
/// § 21.8 deny rule is meant to prefer over the editor's `vscode.todo.add`.
final class _InProcessTodoTool extends BrainTool {
  @override
  String get name => 'todo.add';

  @override
  ToolGroup get group => ToolGroup.todo;

  @override
  bool get readOnly => false;

  @override
  String get description => 'adds an in-process todo';

  @override
  Map<String, Object?> get inputSchema => const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{},
      };

  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async => null;
}

/// Minimal `TomBrainMemoryClient` — never exercised here; present only because
/// [ToolContext.memory] is non-nullable.
class _StubMemoryClient implements TomBrainMemoryClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
