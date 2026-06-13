// Request (c) § 3.2 — the `McpLivenessMonitor` 30-second heartbeat that probes
// each configured MCP server and holds the live set
// (`agent_sdk_provider_and_mcp_liveness.md` § 3.2).
//
// The monitor is the "auto-enable/disable on live/dead" engine. Each tick it
// probes every configured server (via `McpClient.listTools(serverId)` in
// production); a successful probe marks the server live, any failure marks it
// dead AND evicts the pooled connection so the next tick reconnects. The live
// set it holds (`isLive(serverId)`) is the dynamic half of
// `offered = exposeToLlms && isLive` — flipping a server in/out of service with
// no restart.
//
// This suite drives the *pure* `probeOnce()` directly (no wall clock) plus the
// loop's start/stop idempotency, mirroring how the dream cadence suite separates
// the pure driver from its `Timer.periodic` loop.
//
// What this suite locks:
//
//   LM-1 — a server whose probe succeeds is marked live.
//   LM-2 — a server whose probe fails is marked dead and is evicted.
//   LM-3 — a dead server that later probes OK flips back to live (auto-enable),
//          with no eviction on the recovering tick.
//   LM-4 — an unconfigured id is never live; configured ids start optimistically
//          live (so the boot-time merge offers them before the first tick).
//   LM-5 — start()/stop() are idempotent and isRunning tracks the timer.

import 'dart:async';

import 'package:test/test.dart';
import 'package:tom_brain_run/tom_brain_run.dart' show McpLivenessMonitor;

void main() {
  group('r39 — McpLivenessMonitor.probeOnce', () {
    test('LM-1: a server whose probe succeeds is marked live', () async {
      final monitor = McpLivenessMonitor(
        serverIds: const <String>['up'],
        probe: (_) async {}, // completes → live
        evict: (_) async {},
      );

      await monitor.probeOnce();

      expect(monitor.isLive('up'), isTrue);
    });

    test('LM-2: a failing probe marks the server dead and evicts it', () async {
      final evicted = <String>[];
      final monitor = McpLivenessMonitor(
        serverIds: const <String>['down'],
        probe: (_) async => throw StateError('unreachable'),
        evict: (id) async => evicted.add(id),
      );

      await monitor.probeOnce();

      expect(monitor.isLive('down'), isFalse);
      expect(evicted, <String>['down'],
          reason: 'a dead server is evicted so the next tick reconnects');
    });

    test('LM-3: a recovered server flips back to live without re-evicting',
        () async {
      var fail = true;
      final evicted = <String>[];
      final monitor = McpLivenessMonitor(
        serverIds: const <String>['flap'],
        probe: (_) async {
          if (fail) throw StateError('down');
        },
        evict: (id) async => evicted.add(id),
      );

      await monitor.probeOnce(); // dead + evicted once
      expect(monitor.isLive('flap'), isFalse);
      expect(evicted, <String>['flap']);

      fail = false;
      await monitor.probeOnce(); // recovers
      expect(monitor.isLive('flap'), isTrue);
      expect(evicted, <String>['flap'],
          reason: 'a recovering tick probes live and does not evict again');
    });

    test('LM-4: unconfigured id is not live; configured ids start live',
        () async {
      final monitor = McpLivenessMonitor(
        serverIds: const <String>['cfg'],
        probe: (_) async {},
        evict: (_) async {},
      );

      // Before any probe: optimistic-live for configured, dead for unknown.
      expect(monitor.isLive('cfg'), isTrue,
          reason: 'optimistic so the boot merge offers it before tick 1');
      expect(monitor.isLive('ghost'), isFalse);
    });

    test('LM-5: start()/stop() are idempotent and isRunning tracks the timer',
        () async {
      final monitor = McpLivenessMonitor(
        serverIds: const <String>['up'],
        probe: (_) async {},
        evict: (_) async {},
        interval: const Duration(milliseconds: 20),
      );

      expect(monitor.isRunning, isFalse);
      monitor.start();
      monitor.start(); // idempotent
      expect(monitor.isRunning, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 50));

      await monitor.stop();
      await monitor.stop(); // idempotent
      expect(monitor.isRunning, isFalse);
      // The periodic probe ran at least once → the live set is populated.
      expect(monitor.isLive('up'), isTrue);
    });
  });
}
