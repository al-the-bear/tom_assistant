// Extension F step 16 — `ToolEvent` + `ToolEventBus`, and their emission on
// every `tool.list` / `tool.invoke` trigger
// (`prototype_tools_mcp_extension_plan.md` step 16;
// `tom_brain_procedure_specification.md` § 13, § 21.2, § 21.10).
//
// Covers:
//
//   - The four variants (`ToolListed`, `ToolInvoked`, `ToolFailed`,
//     `ToolDenied`) construct, carry their payloads, inherit `BrainEvent`,
//     and carry the canonical kebab-case `tool.<name>` kind.
//   - `payloadJson()` omits the optional `filter`; `toJson()` composes
//     kind + base fields + payload.
//   - `ToolEvent` is a closed sealed sum (exhaustive switch compiles).
//   - `ToolEventBus` fans events out (broadcast, ordered, closes cleanly).
//   - Emission on the trigger: `ToolBridge.list` emits `ToolListed`;
//     `invoke` emits `ToolInvoked` (success), `ToolDenied` (policy refusal),
//     and `ToolFailed` (unknown tool / invalid args / run throw).
//
// Drives the public package barrel only.

import 'package:test/test.dart';
import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show BrainEvent, TomBrainMemoryClient;

/// A fixed UTC timestamp the variant constructors share.
final DateTime _at = DateTime.utc(2026, 6, 7, 12, 0, 0);

/// Builds one of each variant (the canonical fixtures the suite reuses).
List<ToolEvent> _oneOfEach() => <ToolEvent>[
      ToolListed(occurredAt: _at, count: 3, filter: 'memory'),
      ToolInvoked(occurredAt: _at, name: 'echo', group: 'file'),
      ToolFailed(occurredAt: _at, name: 'nope', reason: 'unknown tool "nope"'),
      ToolDenied(occurredAt: _at, name: 'echo', reason: 'write tools denied'),
    ];

/// Exhaustive switch over the closed sum — the compile-time drift guard.
String _describe(ToolEvent event) => switch (event) {
      ToolListed() => 'listed',
      ToolInvoked() => 'invoked',
      ToolFailed() => 'failed',
      ToolDenied() => 'denied',
    };

void main() {
  group('F.16-tool-1: construction + base inheritance', () {
    test('every variant is a ToolEvent and a BrainEvent', () {
      for (final event in _oneOfEach()) {
        expect(event, isA<ToolEvent>());
        expect(event, isA<BrainEvent>());
      }
    });

    test('runId is nullable and defaults to null', () {
      for (final event in _oneOfEach()) {
        expect(event.runId, isNull);
      }
    });

    test('occurredAt + causedBy pass through the base', () {
      final event = ToolInvoked(
        occurredAt: _at,
        runId: 'run_1',
        causedBy: 'ev_0',
        name: 'echo',
        group: 'file',
      );
      expect(event.occurredAt, _at);
      expect(event.runId, 'run_1');
      expect(event.causedBy, 'ev_0');
    });
  });

  group('F.16-tool-2: kind discriminators (kebab-case)', () {
    test('each variant carries its canonical tool.<name> kind', () {
      final kinds = <Type, String>{
        ToolListed: 'tool.listed',
        ToolInvoked: 'tool.invoked',
        ToolFailed: 'tool.failed',
        ToolDenied: 'tool.denied',
      };
      for (final event in _oneOfEach()) {
        expect(event.kind, kinds[event.runtimeType]);
      }
    });

    test('every kind is unique', () {
      expect(_oneOfEach().map((e) => e.kind).toSet(), hasLength(4));
    });
  });

  group('F.16-tool-3: payloadJson + toJson', () {
    test('ToolListed carries count and omits null filter', () {
      expect(
        ToolListed(occurredAt: _at, count: 2).payloadJson(),
        <String, Object?>{'count': 2},
      );
      expect(
        ToolListed(occurredAt: _at, count: 2, filter: 'memory').payloadJson(),
        <String, Object?>{'count': 2, 'filter': 'memory'},
      );
    });

    test('ToolInvoked carries name + group', () {
      expect(
        ToolInvoked(occurredAt: _at, name: 'echo', group: 'file').payloadJson(),
        <String, Object?>{'name': 'echo', 'group': 'file'},
      );
    });

    test('ToolFailed / ToolDenied carry name + reason', () {
      expect(
        ToolFailed(occurredAt: _at, name: 'nope', reason: 'gone').payloadJson(),
        <String, Object?>{'name': 'nope', 'reason': 'gone'},
      );
      expect(
        ToolDenied(occurredAt: _at, name: 'echo', reason: 'denied').payloadJson(),
        <String, Object?>{'name': 'echo', 'reason': 'denied'},
      );
    });

    test('toJson composes kind + base + payload, omitting null causedBy', () {
      final json = ToolInvoked(
        occurredAt: _at,
        runId: 'run_1',
        name: 'echo',
        group: 'file',
      ).toJson();
      expect(json, <String, Object?>{
        'kind': 'tool.invoked',
        'occurredAt': _at.toIso8601String(),
        'runId': 'run_1',
        'payload': <String, Object?>{'name': 'echo', 'group': 'file'},
      });
    });
  });

  group('F.16-tool-4: closed sealed sum (drift guard)', () {
    test('exhaustive switch maps each variant', () {
      expect(_oneOfEach().map(_describe).toList(),
          <String>['listed', 'invoked', 'failed', 'denied']);
    });
  });

  group('F.16-tool-7: noticeLine (out-of-band notice text)', () {
    test('ToolInvoked names the tool', () {
      expect(
        ToolInvoked(occurredAt: _at, name: 'memory.read', group: 'memory')
            .noticeLine(),
        '🔧 tool memory.read',
      );
    });

    test('ToolFailed marks the failure and carries the reason', () {
      expect(
        ToolFailed(occurredAt: _at, name: 'does.not.exist', reason: 'unknown')
            .noticeLine(),
        '⚠️ tool does.not.exist failed: unknown',
      );
    });

    test('ToolDenied marks the policy refusal and carries the reason', () {
      expect(
        ToolDenied(occurredAt: _at, name: 'fs.write', reason: 'read-only')
            .noticeLine(),
        '🚫 tool fs.write denied: read-only',
      );
    });

    test('ToolListed reports the count, with and without a filter', () {
      expect(
        ToolListed(occurredAt: _at, count: 3).noticeLine(),
        '🔧 listed 3 tools',
      );
      expect(
        ToolListed(occurredAt: _at, count: 1, filter: 'memory').noticeLine(),
        '🔧 listed 1 memory tool(s)',
      );
    });
  });

  group('F.16-tool-5: ToolEventBus', () {
    test('events() delivers emissions in order to a subscriber', () async {
      final bus = ToolEventBus();
      final received = <String>[];
      final sub = bus.events().listen((e) => received.add(e.kind));
      for (final event in _oneOfEach()) {
        bus.emit(event);
      }
      await bus.close();
      await sub.cancel();
      expect(received, <String>[
        'tool.listed',
        'tool.invoked',
        'tool.failed',
        'tool.denied',
      ]);
    });

    test('emit after close throws StateError', () async {
      final bus = ToolEventBus();
      await bus.close();
      expect(
        () => bus.emit(ToolListed(occurredAt: _at, count: 0)),
        throwsStateError,
      );
    });
  });

  group('F.16-tool-6: emission on the ToolBridge trigger', () {
    test('list emits ToolListed with the resolved count + filter', () async {
      final collected = <ToolEvent>[];
      final bridge = _bridge(
        tools: <BrainTool>[_EchoTool(), _PeekTool()],
        onEvent: collected.add,
      );

      await bridge.list();
      await bridge.list(filter: 'memory');

      expect(collected, hasLength(2));
      final unfiltered = collected[0] as ToolListed;
      expect(unfiltered.count, 2);
      expect(unfiltered.filter, isNull);
      final filtered = collected[1] as ToolListed;
      expect(filtered.count, 1);
      expect(filtered.filter, 'memory');
    });

    test('invoke success emits ToolInvoked carrying name + group', () async {
      final collected = <ToolEvent>[];
      final bridge = _bridge(tools: <BrainTool>[_EchoTool()], onEvent: collected.add);

      final result = await bridge.invoke('echo', <String, Object?>{'value': 'x'});

      expect(result['ok'], isTrue);
      expect(collected.single, isA<ToolInvoked>());
      final invoked = collected.single as ToolInvoked;
      expect(invoked.name, 'echo');
      expect(invoked.group, 'file');
    });

    test('invoke of an unknown tool emits ToolFailed', () async {
      final collected = <ToolEvent>[];
      final bridge = _bridge(tools: const <BrainTool>[], onEvent: collected.add);

      await bridge.invoke('ghost', const <String, Object?>{});

      expect(collected.single, isA<ToolFailed>());
      expect((collected.single as ToolFailed).name, 'ghost');
    });

    test('invoke with invalid args emits ToolFailed before the budget gate',
        () async {
      final collected = <ToolEvent>[];
      final bridge = _bridge(tools: <BrainTool>[_EchoTool()], onEvent: collected.add);

      // `value` is required by the schema; omit it.
      await bridge.invoke('echo', const <String, Object?>{});

      expect(collected.single, isA<ToolFailed>());
    });

    test('invoke denied by policy emits ToolDenied', () async {
      final collected = <ToolEvent>[];
      final bridge = _bridge(
        tools: <BrainTool>[_EchoTool()],
        policy: const ToolPolicy(ToolPolicyProfile.readOnly),
        onEvent: collected.add,
      );

      await bridge.invoke('echo', <String, Object?>{'value': 'x'});

      expect(collected.single, isA<ToolDenied>());
      expect((collected.single as ToolDenied).name, 'echo');
    });

    test('a tool that throws while running emits ToolFailed then rethrows',
        () async {
      final collected = <ToolEvent>[];
      final bridge = _bridge(tools: <BrainTool>[_BoomTool()], onEvent: collected.add);

      await expectLater(
        bridge.invoke('boom', const <String, Object?>{}),
        throwsA(isA<StateError>()),
      );
      expect(collected.single, isA<ToolFailed>());
      expect((collected.single as ToolFailed).name, 'boom');
    });

    test('the same path works through a ToolEventBus sink', () async {
      final bus = ToolEventBus();
      final kinds = <String>[];
      final sub = bus.events().listen((e) => kinds.add(e.kind));
      final bridge = _bridge(tools: <BrainTool>[_EchoTool()], onEvent: bus.emit);

      await bridge.invoke('echo', <String, Object?>{'value': 'x'});
      await bus.close();
      await sub.cancel();

      expect(kinds, <String>['tool.invoked']);
    });
  });
}

// ── helpers ──────────────────────────────────────────────────────────

/// Builds a [ToolBridge] over a registry seeded with [tools], an optional
/// [policy] (default `all`), a stub context, and an optional event [onEvent]
/// sink.
ToolBridge _bridge({
  required List<BrainTool> tools,
  ToolPolicy policy = const ToolPolicy(ToolPolicyProfile.all),
  ToolEventSink? onEvent,
}) {
  final registry = ToolRegistry();
  for (final tool in tools) {
    registry.register(tool);
  }
  final context = ToolContext(
    budget: BudgetLedger(ProcedureBudget(const <String, int>{})),
    memory: _StubMemoryClient(),
    fileScopeRoots: const <String>['/tom-brain-engine'],
  );
  return ToolBridge(registry, policy, context, onEvent: onEvent);
}

/// A write tool in the `file` group that echoes its `value` argument back.
final class _EchoTool extends BrainTool {
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
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async =>
      args['value'];
}

/// A read-only tool in the `memory` group — used to exercise the group filter.
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

/// A read-only `memory` tool whose `run` throws — exercises the run-failure
/// `ToolFailed` path.
final class _BoomTool extends BrainTool {
  @override
  String get name => 'boom';
  @override
  ToolGroup get group => ToolGroup.memory;
  @override
  bool get readOnly => true;
  @override
  String get description => 'throws on run';
  @override
  Map<String, Object?> get inputSchema => const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{},
      };
  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async =>
      throw StateError('boom');
}

/// Minimal `TomBrainMemoryClient` — the tools under test never touch it.
class _StubMemoryClient implements TomBrainMemoryClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
