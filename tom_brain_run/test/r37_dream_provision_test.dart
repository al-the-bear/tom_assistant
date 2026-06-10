// Item b — the scheduled dream cadence wired into startup through
// `provisionBrain`.
//
// `provisionBrain` now accepts an optional `DreamConfig`. When the block is
// present AND enabled, the boot builds a `DreamController` over a
// `FreeTimeScheduler` bound to the booted coordinator / engine / memory client,
// gates it by the configured windows, starts its heartbeat, and composes the
// controller's `stop()` into the cognition teardown. When the block is absent or
// disabled, no background cadence spins (so the prototype's deterministic live
// tests stay deterministic).
//
// These tests prove the *wiring composes and tears down cleanly* — they boot the
// real on-disk memory with a stub LLM (the r30 harness) and confirm a
// dream-enabled provision boots to an idle queue and shuts down exactly once.
// The cadence's *firing* behaviour (windows, modes, lane dueness) is unit-proven
// by the dream_controller / dream_cadence_loop / dream_window_schedule suites; a
// default one-minute heartbeat against a 5-minute fast lane never fires inside a
// sub-second test, so this suite deliberately asserts only the boot/teardown
// seam, not a dream pass.
//
// Off-box skip: like r30, the only precondition is the packaged `vec0` binary.
// Absent it, the whole suite is skipped, not failed.

import 'dart:io';

import 'package:tom_brain_access/tom_brain_access.dart' show ProvisionedBrain, QueueSnapshot;
import 'package:tom_brain_memory/tom_brain_memory.dart'
    show MemoryConfig, SqliteVecBinaryResolver;
import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:tom_brain_smoke_prototype/tom_brain_smoke_prototype.dart'
    show SmokeSubstrate;
import 'package:test/test.dart';

/// Locates `<workspace>/tom_binaries/sqlite_vec` (mirrors r30).
String? _findSqliteVecRoot() {
  var dir = Directory.current.absolute;
  for (var i = 0; i < 8; i++) {
    final candidate =
        Directory('${dir.path}${Platform.pathSeparator}tom_binaries'
            '${Platform.pathSeparator}sqlite_vec');
    if (candidate.existsSync()) return candidate.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

void main() {
  final String? vecRoot = _findSqliteVecRoot();
  final SqliteVecBinaryResolver resolver = SqliteVecBinaryResolver();

  String? resolvedPath;
  if (vecRoot != null && resolver.isSupported) {
    final String path = resolver.resolve(vecRoot);
    if (File(path).existsSync()) resolvedPath = path;
  }

  final String? skipNoBinary = resolvedPath == null
      ? 'No packaged vec0 binary for this platform under '
          'tom_binaries/sqlite_vec.'
      : null;

  MemoryConfig freshMemoryConfig() {
    final Directory root =
        Directory.systemTemp.createTempSync('tom_brain_run_37_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    return MemoryConfig.forTesting(root: root.path, binariesRoot: vecRoot!);
  }

  /// An always-active schedule (no windows) so the gate never suppresses the
  /// cadence — the strictest test of the wiring.
  DreamConfig enabledAlwaysActive() => DreamConfig(
        enabled: true,
        schedule: DreamWindowSchedule(windows: const <DreamWindow>[]),
      );

  group('item b — provisionBrain wires the dream cadence at startup', () {
    test('a dream-enabled provision boots to an idle queue and tears down once',
        () async {
      final SmokeSubstrate substrate = SmokeSubstrate();

      final ProvisionedBrain provisioned = await provisionBrain(
        substrate: substrate,
        memoryConfig: freshMemoryConfig(),
        dream: enabledAlwaysActive(),
      );

      // The dream loop runs in the background; the foreground queue is still
      // idle at stand-up (a dream pass uses only the background slot, and the
      // default heartbeat never fires a 5-minute lane in this window anyway).
      final QueueSnapshot snapshot = provisioned.queueSnapshot();
      expect(snapshot.foregroundRunning, isFalse);
      expect(snapshot.foregroundWaiting, 0);
      expect(snapshot.draining, isFalse);

      // Teardown stops the dream loop, then drains + disposes the cognition —
      // the substrate closes exactly once.
      await provisioned.shutdown();
      expect(substrate.closeCount, 1,
          reason: 'shutdown stops the dream loop then closes the substrate '
              'once');
    });

    test('a disabled dream block spins no cadence and tears down cleanly',
        () async {
      final SmokeSubstrate substrate = SmokeSubstrate();

      final ProvisionedBrain provisioned = await provisionBrain(
        substrate: substrate,
        memoryConfig: freshMemoryConfig(),
        dream: DreamConfig(
          enabled: false,
          schedule: DreamWindowSchedule(windows: const <DreamWindow>[]),
        ),
      );

      await provisioned.shutdown();
      expect(substrate.closeCount, 1);
    });
  }, skip: skipNoBinary);
}
