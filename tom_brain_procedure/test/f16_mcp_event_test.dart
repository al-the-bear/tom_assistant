// Extension F step 16 — `McpEvent` + `McpEventBus`, and their emission on
// every `McpClient` connect / call / failure trigger
// (`prototype_tools_mcp_extension_plan.md` step 16;
// `tom_brain_procedure_specification.md` § 13, § 21.3, § 21.10).
//
// Covers:
//
//   - The three variants (`McpConnected`, `McpToolCalled`, `McpFailed`)
//     construct, carry their payloads (`serverId` on every one), inherit
//     `BrainEvent`, and carry the canonical kebab-case `mcp.<name>` kind.
//   - `McpEvent` is a closed sealed sum (exhaustive switch compiles).
//   - `McpEventBus` fans events out (broadcast, ordered, closes cleanly).
//   - Emission on the trigger: `McpClient` emits `McpConnected` on the lazy
//     first connect, `McpToolCalled` after a successful `callTool`, and
//     `McpFailed` on an unreachable connect, a failed call, and an
//     unconfigured-server lookup.
//
// Drives the public package barrel only.

import 'dart:async';

import 'package:test/test.dart';
import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show BrainEvent;

/// A fixed UTC timestamp the variant constructors share.
final DateTime _at = DateTime.utc(2026, 6, 7, 12, 0, 0);

/// Builds one of each variant (the canonical fixtures the suite reuses).
List<McpEvent> _oneOfEach() => <McpEvent>[
      McpConnected(occurredAt: _at, serverId: 'memory'),
      McpToolCalled(occurredAt: _at, serverId: 'memory', tool: 'recall'),
      McpFailed(
        occurredAt: _at,
        serverId: 'memory',
        code: mcpUnreachableCode,
        message: 'down',
      ),
    ];

/// Exhaustive switch over the closed sum — the compile-time drift guard.
String _describe(McpEvent event) => switch (event) {
      McpConnected() => 'connected',
      McpToolCalled() => 'tool-called',
      McpFailed() => 'failed',
    };

void main() {
  group('F.16-mcp-1: construction + base inheritance', () {
    test('every variant is an McpEvent and a BrainEvent carrying serverId', () {
      for (final event in _oneOfEach()) {
        expect(event, isA<McpEvent>());
        expect(event, isA<BrainEvent>());
        expect(event.serverId, 'memory');
      }
    });

    test('runId is nullable and defaults to null', () {
      for (final event in _oneOfEach()) {
        expect(event.runId, isNull);
      }
    });
  });

  group('F.16-mcp-2: kind discriminators (kebab-case)', () {
    test('each variant carries its canonical mcp.<name> kind', () {
      final kinds = <Type, String>{
        McpConnected: 'mcp.connected',
        McpToolCalled: 'mcp.tool-called',
        McpFailed: 'mcp.failed',
      };
      for (final event in _oneOfEach()) {
        expect(event.kind, kinds[event.runtimeType]);
      }
    });

    test('every kind is unique', () {
      expect(_oneOfEach().map((e) => e.kind).toSet(), hasLength(3));
    });
  });

  group('F.16-mcp-3: payloadJson + toJson', () {
    test('McpConnected carries serverId only', () {
      expect(
        McpConnected(occurredAt: _at, serverId: 'memory').payloadJson(),
        <String, Object?>{'serverId': 'memory'},
      );
    });

    test('McpToolCalled carries serverId + tool', () {
      expect(
        McpToolCalled(occurredAt: _at, serverId: 'm', tool: 'recall')
            .payloadJson(),
        <String, Object?>{'serverId': 'm', 'tool': 'recall'},
      );
    });

    test('McpFailed carries serverId + code + message', () {
      expect(
        McpFailed(
          occurredAt: _at,
          serverId: 'm',
          code: mcpCallFailedCode,
          message: 'boom',
        ).payloadJson(),
        <String, Object?>{
          'serverId': 'm',
          'code': mcpCallFailedCode,
          'message': 'boom',
        },
      );
    });

    test('toJson composes kind + base + payload', () {
      final json =
          McpConnected(occurredAt: _at, runId: 'run_1', serverId: 'memory')
              .toJson();
      expect(json, <String, Object?>{
        'kind': 'mcp.connected',
        'occurredAt': _at.toIso8601String(),
        'runId': 'run_1',
        'payload': <String, Object?>{'serverId': 'memory'},
      });
    });
  });

  group('F.16-mcp-4: closed sealed sum (drift guard)', () {
    test('exhaustive switch maps each variant', () {
      expect(_oneOfEach().map(_describe).toList(),
          <String>['connected', 'tool-called', 'failed']);
    });
  });

  group('F.16-mcp-5: McpEventBus', () {
    test('events() delivers emissions in order to a subscriber', () async {
      final bus = McpEventBus();
      final received = <String>[];
      final sub = bus.events().listen((e) => received.add(e.kind));
      for (final event in _oneOfEach()) {
        bus.emit(event);
      }
      await bus.close();
      await sub.cancel();
      expect(received, <String>['mcp.connected', 'mcp.tool-called', 'mcp.failed']);
    });

    test('emit after close throws StateError', () async {
      final bus = McpEventBus();
      await bus.close();
      expect(
        () => bus.emit(McpConnected(occurredAt: _at, serverId: 'm')),
        throwsStateError,
      );
    });
  });

  group('F.16-mcp-6: emission on the McpClient trigger', () {
    test('the lazy first connect emits McpConnected once', () async {
      final collected = <McpEvent>[];
      final client = _client(
        connector: _StubConnector(_StubConnection()),
        onEvent: collected.add,
      );

      await client.listTools('stub');
      await client.listTools('stub'); // pooled — no second connect.

      final connects = collected.whereType<McpConnected>().toList();
      expect(connects, hasLength(1));
      expect(connects.single.serverId, 'stub');
      await client.close();
    });

    test('a successful callTool emits McpToolCalled with the tool name',
        () async {
      final collected = <McpEvent>[];
      final client = _client(
        connector: _StubConnector(
          _StubConnection(callResult: const <String, Object?>{'answer': 42}),
        ),
        onEvent: collected.add,
      );

      await client.callTool('stub', 'compute', const <String, Object?>{});
      await client.close();

      final called = collected.whereType<McpToolCalled>().single;
      expect(called.serverId, 'stub');
      expect(called.tool, 'compute');
    });

    test('an unreachable connect emits McpFailed (mcp.unreachable)', () async {
      final collected = <McpEvent>[];
      final client = _client(
        connector: _StubConnector(null, throwOnConnect: true),
        onEvent: collected.add,
      );

      await expectLater(
        client.listTools('stub'),
        throwsA(isA<McpFailure>()),
      );

      final failed = collected.whereType<McpFailed>().single;
      expect(failed.serverId, 'stub');
      expect(failed.code, mcpUnreachableCode);
      await client.close();
    });

    test('a failed callTool emits McpFailed (mcp.call.failed)', () async {
      final collected = <McpEvent>[];
      final client = _client(
        connector: _StubConnector(_StubConnection(throwOnCall: true)),
        onEvent: collected.add,
      );

      await expectLater(
        client.callTool('stub', 'boom', const <String, Object?>{}),
        throwsA(isA<McpFailure>()),
      );

      final failed = collected.whereType<McpFailed>().single;
      expect(failed.code, mcpCallFailedCode);
      await client.close();
    });

    test('an unconfigured server emits McpFailed before any connect', () async {
      final collected = <McpEvent>[];
      final connector = _StubConnector(_StubConnection());
      final client = McpClient(
        const <McpServerConfig>[],
        connector,
        onEvent: collected.add,
      );

      await expectLater(
        client.listTools('ghost'),
        throwsA(isA<McpFailure>()),
      );

      expect(collected.single, isA<McpFailed>());
      expect((collected.single as McpFailed).serverId, 'ghost');
      expect(connector.connectCount, 0,
          reason: 'an unknown server never reaches the connector');
      await client.close();
    });

    test('the same path works through an McpEventBus sink', () async {
      final bus = McpEventBus();
      final kinds = <String>[];
      final sub = bus.events().listen((e) => kinds.add(e.kind));
      final client = _client(
        connector: _StubConnector(_StubConnection()),
        onEvent: bus.emit,
      );

      await client.listTools('stub');
      await client.close();
      await bus.close();
      await sub.cancel();

      expect(kinds, contains('mcp.connected'));
    });
  });
}

// ── helpers ──────────────────────────────────────────────────────────

/// Builds an [McpClient] over a single configured `stub` server, the given
/// [connector], and an optional event [onEvent] sink.
McpClient _client({
  required McpConnector connector,
  McpEventSink? onEvent,
}) =>
    McpClient(
      const <McpServerConfig>[
        McpServerConfig(id: 'stub', transport: McpTransport.stdio),
      ],
      connector,
      onEvent: onEvent,
    );

/// A stub MCP connection: returns canned tool/result data, or throws to
/// simulate a failed call.
final class _StubConnection implements McpServerConnection {
  _StubConnection({
    this.callResult = const <String, Object?>{},
    this.throwOnCall = false,
  });

  final Map<String, Object?> callResult;
  final bool throwOnCall;

  @override
  Future<List<Map<String, Object?>>> listTools() async =>
      const <Map<String, Object?>>[];

  @override
  Future<Map<String, Object?>> callTool(
    String name,
    Map<String, Object?> args,
  ) async {
    if (throwOnCall) {
      throw const McpFailure(
        mcpCallFailedCode,
        serverId: 'stub',
        message: 'call failed',
      );
    }
    return callResult;
  }

  @override
  Future<void> close() async {}
}

/// A stub connector that hands back a single [_StubConnection], or throws to
/// simulate an unreachable server.
final class _StubConnector implements McpConnector {
  _StubConnector(this._connection, {this.throwOnConnect = false});

  final McpServerConnection? _connection;
  final bool throwOnConnect;
  int connectCount = 0;

  @override
  Future<McpServerConnection> connect(McpServerConfig config) async {
    connectCount++;
    if (throwOnConnect || _connection == null) {
      throw McpFailure(
        mcpUnreachableCode,
        serverId: config.id,
        message: 'unreachable',
      );
    }
    return _connection;
  }
}
