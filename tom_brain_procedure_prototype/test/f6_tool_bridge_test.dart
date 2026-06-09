// Extension F step 6 — the `tool.list` / `tool.invoke` bridged primitives
// (`tom_brain_procedure_prototype_specification.md` § 21.2, § 5.1;
// `prototype_tools_mcp_extension_plan.md` step 6).
//
// `ToolBridge` is a plain Dart class bridged exactly like `MemoryBridge` /
// `SubstrateBridge`. It exposes two d4rt-facing methods over the
// tool-calling core (step 4) and the four-profile policy (step 5):
//
//   tool.list({filter})   → List<Map> of {name, group, description,
//                           input_schema}, already policy-narrowed.
//   tool.invoke(name,args) → {ok: true, result} on success;
//                           {ok: false, error} when the tool is unknown,
//                           policy-denied, or its args fail validation.
//
// `tool.invoke` charges one `toolCalls` unit against the run's
// `BudgetLedger` *before* the side effect (PE-8): a call over the run's
// `toolCalls` cap is refused with `ProcedureBudgetExceeded` and the tool
// never runs. `tool.list` carries no effect cost.
//
// What this suite locks:
//
//   F.6-1  — the catalog knows `tool.list` / `tool.invoke`, with the
//            dotted→camel call tokens.
//   F.6-2  — the effort accountant scores `tool.invoke` as one toolCall
//            (so the budget gate can pre-charge it) and `tool.list` as
//            zero.
//   F.6-3  — invoke happy path: `{ok: true, result}`, tool ran with the
//            validated args + the run's `ToolContext`.
//   F.6-4  — invoke unknown name → `{ok: false}` (no budget charge).
//   F.6-5  — invoke policy-denied → `{ok: false}` (no budget charge).
//   F.6-6  — invoke invalid args → `{ok: false}` (no budget charge).
//   F.6-7  — budget pre-charge refuses the call over the `toolCalls` cap
//            with `ProcedureBudgetExceeded`, before the tool runs.
//   F.6-8  — list returns policy-narrowed descriptors carrying
//            `input_schema`; a `filter` narrows to one group.
//   F.6-9  — a d4rt script calls `tool.list` then `tool.invoke` through
//            the interpreter (the generator-output round-trip).
//   F.6-10 — `D4rtDcliHost` injects the bridge as the `tool` global.

import 'package:tom_d4rt/d4rt.dart';
import 'package:test/test.dart';

import 'package:tom_brain_shared/tom_brain_shared.dart' show EffortMetrics;
import 'package:tom_brain_memory/tom_brain_memory.dart'
    show TomBrainMemoryClient;
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show TomBrainSubstrateClient;

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';

void main() {
  group('F.6-1 catalog membership', () {
    test('tool.list / tool.invoke are recognised primitives', () {
      expect(BridgedPrimitiveCatalog.isKnown('tool.list'), isTrue);
      expect(BridgedPrimitiveCatalog.isKnown('tool.invoke'), isTrue);
      expect(
        BridgedPrimitiveCatalog.all,
        containsAll(<String>['tool.list', 'tool.invoke']),
      );
    });

    test('the dotted call tokens carry their camelCase spelling', () {
      expect(BridgedPrimitiveCatalog.callTokensFor('tool.list'),
          <String>{'tool.list', 'toolList'});
      expect(BridgedPrimitiveCatalog.callTokensFor('tool.invoke'),
          <String>{'tool.invoke', 'toolInvoke'});
    });
  });

  group('F.6-2 effort accounting', () {
    const accountant = EffortAccountant();

    test('tool.invoke scores one toolCall (dotted and camel spelling)', () {
      expect(accountant.classify('tool.invoke').toolCalls, 1);
      expect(accountant.classify('toolInvoke').toolCalls, 1);
    });

    test('tool.list scores no effort — it only enumerates', () {
      expect(accountant.classify('tool.list'), EffortMetrics.zero);
    });
  });

  group('F.6-3 invoke — happy path', () {
    test('a registered tool runs and returns {ok: true, result}', () async {
      final tool = _EchoTool();
      final bridge = _bridge(tools: <BrainTool>[tool]);

      final result = await bridge.invoke('echo', <String, Object?>{'value': 'hi'});

      expect(result['ok'], isTrue);
      expect(result['result'], 'hi');
      expect(tool.lastArgs, <String, Object?>{'value': 'hi'});
      expect(tool.lastContext, isNotNull,
          reason: 'the tool ran with the run ToolContext (PE-1)');
    });
  });

  group('F.6-4 invoke — unknown name', () {
    test('an unregistered name returns {ok: false} and does not charge budget',
        () async {
      final ledger = _ledger(toolCalls: 1);
      final bridge = _bridge(tools: const <BrainTool>[], budget: ledger);

      final result = await bridge.invoke('missing', const <String, Object?>{});

      expect(result['ok'], isFalse);
      expect(result['error'], isA<String>());
      expect(ledger.consumed.toolCalls, 0,
          reason: 'an unknown tool never reaches the budget pre-charge');
    });
  });

  group('F.6-5 invoke — policy denied', () {
    test('a tool the policy hides returns {ok: false}, no budget charge',
        () async {
      final ledger = _ledger(toolCalls: 1);
      // `read_only` profile hides the write-tool `echo`.
      final bridge = _bridge(
        tools: <BrainTool>[_EchoTool()],
        policy: const ToolPolicy(ToolPolicyProfile.readOnly),
        budget: ledger,
      );

      final result = await bridge.invoke('echo', <String, Object?>{'value': 'x'});

      expect(result['ok'], isFalse);
      expect(result['error'], isA<String>());
      expect(ledger.consumed.toolCalls, 0);
    });
  });

  group('F.6-6 invoke — invalid args', () {
    test('args that fail the input schema return {ok: false}, no charge',
        () async {
      final ledger = _ledger(toolCalls: 1);
      final bridge = _bridge(tools: <BrainTool>[_EchoTool()], budget: ledger);

      // `value` is required by _EchoTool's schema.
      final result = await bridge.invoke('echo', const <String, Object?>{});

      expect(result['ok'], isFalse);
      expect(result['error'], isA<String>());
      expect(ledger.consumed.toolCalls, 0);
    });
  });

  group('F.6-7 invoke — budget pre-charge (PE-8)', () {
    test('a call over the toolCalls cap is refused before the tool runs',
        () async {
      final tool = _EchoTool();
      final ledger = _ledger(toolCalls: 1);
      final bridge = _bridge(tools: <BrainTool>[tool], budget: ledger);

      final first = await bridge.invoke('echo', <String, Object?>{'value': 'a'});
      expect(first['ok'], isTrue);
      expect(ledger.consumed.toolCalls, 1);

      tool.runCount = 0;
      await expectLater(
        bridge.invoke('echo', <String, Object?>{'value': 'b'}),
        throwsA(isA<ProcedureBudgetExceeded>()),
      );
      expect(tool.runCount, 0,
          reason: 'the refused call never reaches the tool (pre-charge gate)');
    });
  });

  group('F.6-8 list — policy-narrowed descriptors', () {
    test('list returns {name, group, description, input_schema} per tool',
        () async {
      final bridge = _bridge(tools: <BrainTool>[_EchoTool(), _PeekTool()]);

      final listed = await bridge.list();

      expect(listed, hasLength(2));
      final echo = listed.firstWhere((t) => t['name'] == 'echo');
      expect(echo['group'], 'file');
      expect(echo['description'], isA<String>());
      expect(echo['input_schema'], isA<Map<String, Object?>>());
    });

    test('the read_only policy narrows out write tools', () async {
      final bridge = _bridge(
        tools: <BrainTool>[_EchoTool(), _PeekTool()],
        policy: const ToolPolicy(ToolPolicyProfile.readOnly),
      );

      final names = (await bridge.list()).map((t) => t['name']).toSet();
      expect(names, <String>{'memory.peek'});
    });

    test('a filter narrows the list to a single group', () async {
      final bridge = _bridge(tools: <BrainTool>[_EchoTool(), _PeekTool()]);

      final names = (await bridge.list(filter: 'memory'))
          .map((t) => t['name'])
          .toSet();
      expect(names, <String>{'memory.peek'});
    });
  });

  group('F.6-9 d4rt round-trip through the interpreter', () {
    test('a script calls tool.list then tool.invoke against a stub tool',
        () async {
      final bridge = _bridge(tools: <BrainTool>[_EchoTool()]);
      final interpreter = D4rt();
      BrainBridges.register(interpreter);

      final result = await interpreter.execute(
        source: '''
import '${BrainBridges.toolLibrary}';

Future<Map<String, Object?>> main(ToolBridge tool) async {
  final tools = await tool.list();
  final invoked = await tool.invoke('echo', {'value': 'streamed'});
  return {
    'count': tools.length,
    'firstName': tools[0]['name'],
    'ok': invoked['ok'],
    'result': invoked['result'],
  };
}
''',
        positionalArgs: <Object?>[bridge],
      );

      final out = (result as Map).cast<String, Object?>();
      expect(out['count'], 1);
      expect(out['firstName'], 'echo');
      expect(out['ok'], isTrue);
      expect(out['result'], 'streamed');
    });

    test('an unknown name surfaces {ok: false} inside the script', () async {
      final bridge = _bridge(tools: const <BrainTool>[]);
      final interpreter = D4rt();
      BrainBridges.register(interpreter);

      final result = await interpreter.execute(
        source: '''
import '${BrainBridges.toolLibrary}';

Future<Object?> main(ToolBridge tool) async {
  final invoked = await tool.invoke('missing', {});
  return invoked['ok'];
}
''',
        positionalArgs: <Object?>[bridge],
      );

      expect(result, isFalse);
    });
  });

  group('F.6-10 host injects the `tool` global', () {
    test('D4rtDcliHost binds the bridge as `tool` and a script reaches it',
        () async {
      final host = D4rtDcliHost(
        memoryBridge: MemoryBridge(_StubMemoryClient()),
        substrateBridge: SubstrateBridge(_StubSubstrateClient()),
        toolBridge: _bridge(tools: <BrainTool>[_EchoTool()]),
      );

      final result = await host.run(
        '''
import '${BrainBridges.toolLibrary}';

Future<Object?> run(Object? inputs) async {
  final invoked = await tool.invoke('echo', {'value': 'wired'});
  return invoked['result'];
}
''',
        inputs: const <Object?>[null],
      );

      expect(result, 'wired');
    });
  });
}

// ── helpers ──────────────────────────────────────────────────────────

/// Builds a [ToolBridge] over a registry seeded with [tools], an optional
/// [policy] (default `all`), and a [ToolContext] over [budget] (default an
/// uncapped ledger) and a stub memory client.
ToolBridge _bridge({
  required List<BrainTool> tools,
  ToolPolicy policy = const ToolPolicy(ToolPolicyProfile.all),
  BudgetLedger? budget,
}) {
  final registry = ToolRegistry();
  for (final tool in tools) {
    registry.register(tool);
  }
  final context = ToolContext(
    budget: budget ?? _ledger(),
    memory: _StubMemoryClient(),
    fileScopeRoots: const <String>['/tom-brain-engine'],
  );
  return ToolBridge(registry, policy, context);
}

/// A ledger over a budget that caps [toolCalls] (or no cap when omitted).
BudgetLedger _ledger({int? toolCalls}) => BudgetLedger(
      ProcedureBudget(<String, int>{'toolCalls': ?toolCalls}),
    );

/// A write tool in the `file` group that echoes its `value` argument back.
final class _EchoTool extends BrainTool {
  Map<String, Object?>? lastArgs;
  ToolContext? lastContext;
  int runCount = 0;

  @override
  String get name => 'echo';

  @override
  ToolGroup get group => ToolGroup.file;

  @override
  bool get readOnly => false;

  @override
  String get description => 'echoes its value argument';

  @override
  Map<String, Object?> get inputSchema => const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'value': <String, Object?>{'type': 'string'},
        },
        'required': <String>['value'],
      };

  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async {
    runCount++;
    lastArgs = args;
    lastContext = ctx;
    return args['value'];
  }
}

/// A read-only tool in the `memory` group — used to exercise policy
/// narrowing and group filtering.
final class _PeekTool extends BrainTool {
  @override
  String get name => 'memory.peek';

  @override
  ToolGroup get group => ToolGroup.memory;

  @override
  bool get readOnly => true;

  @override
  String get description => 'peeks at memory';

  @override
  Map<String, Object?> get inputSchema => const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{},
      };

  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async => null;
}

/// Minimal `TomBrainMemoryClient` — no method is exercised; the tools used
/// here never touch memory. Present only because [ToolContext.memory] is
/// non-nullable.
class _StubMemoryClient implements TomBrainMemoryClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// Minimal `TomBrainSubstrateClient` for the host-wiring test — the script
/// only calls `tool.invoke`, never `sub.*`.
class _StubSubstrateClient implements TomBrainSubstrateClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
