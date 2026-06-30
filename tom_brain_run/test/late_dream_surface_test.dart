// LateDreamSurface (item c) — the late-bound bridge that lets the engine's
// per-run `ToolContext` carry a dream surface that does not exist yet when the
// context is wired during boot.
//
// The holder is created before `BrainProcessBoot.boot`, threaded in as the
// engine's `toolDreamSurface`, then `bind`-bound to the real `DreamController`
// once `provisionBrain` has built it. These tests lock the holder's contract in
// isolation:
//
//   * before binding, every delegated verb raises (a tool reaching the cadence
//     before it exists is a wiring bug, never a silent no-op);
//   * binding is single-shot (one controller per process);
//   * after binding, every verb routes to the bound target.

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show ToolDreamSurface;
import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show BrainTime, MutableTestClock;
import 'package:test/test.dart';

void main() {
  group('LateDreamSurface before binding', () {
    test('starts unbound', () {
      expect(LateDreamSurface().isBound, isFalse);
    });

    test('every verb raises StateError until bound', () {
      final holder = LateDreamSurface();
      expect(() => holder.forceFor(const Duration(minutes: 5)),
          throwsStateError);
      expect(holder.suspend, throwsStateError);
      expect(holder.resume, throwsStateError);
      expect(holder.dreamStatus, throwsStateError);
    });
  });

  group('LateDreamSurface binding', () {
    test('binding flips isBound and routes verbs to the target', () {
      final target = _RecordingDream();
      final holder = LateDreamSurface()..bind(target);

      expect(holder.isBound, isTrue);

      holder.forceFor(const Duration(minutes: 30));
      holder.suspend();
      holder.resume();
      final status = holder.dreamStatus();

      expect(target.calls, <String>['forceFor', 'suspend', 'resume']);
      expect(target.lastPeriod, const Duration(minutes: 30));
      expect(status, target.statusReturn);
    });

    test('a second bind is refused — one controller per process', () {
      final holder = LateDreamSurface()..bind(_RecordingDream());
      expect(() => holder.bind(_RecordingDream()), throwsStateError);
    });

    test('a live DreamController is a legal bind target', () {
      // The production target: the holder delegates to the controller's
      // ToolDreamSurface implementation. An always-active, never-started
      // controller reports `active: true`, `running: false`.
      final controller = DreamController(
        driver: _nullDriver(),
        schedule: DreamWindowSchedule(windows: const <DreamWindow>[]),
      );
      final holder = LateDreamSurface()..bind(controller);

      final status = holder.dreamStatus();
      expect(status['mode'], 'scheduled');
      expect(status['active'], isTrue);
      expect(status['running'], isFalse);
      expect(status['alwaysActive'], isTrue);
      expect(status['manualUntil'], isNull);
    });
  });
}

/// A [ToolDreamSurface] double that records which verbs the holder delegates.
class _RecordingDream implements ToolDreamSurface {
  final List<String> calls = <String>[];
  Duration? lastPeriod;
  final Map<String, Object?> statusReturn = const <String, Object?>{
    'mode': 'scheduled',
    'active': true,
    'running': true,
  };

  @override
  void forceFor(Duration period) {
    calls.add('forceFor');
    lastPeriod = period;
  }

  @override
  void suspend() => calls.add('suspend');

  @override
  void resume() => calls.add('resume');

  @override
  Map<String, Object?> dreamStatus() => statusReturn;
}

/// A cadence driver that never fires — the controller under test is only asked
/// for its status, never started, so the driver is inert.
DreamCadenceDriver _nullDriver() => DreamCadenceDriver(
      clock: MutableTestClock(BrainTime.fromMs(0)),
      schedule: CadenceSchedule.defaults(),
      fire: (_) async => FireOutcome.fired,
    );
