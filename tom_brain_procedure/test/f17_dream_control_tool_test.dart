// Extension F — the `dream.control` tool (`memory_specification.md` § 9.7;
// quest item c).
//
// One tool exposes the four operator actions over the dreaming cadence the run
// assembly owns: `start` dreaming for a period, `stop` it, `resume` the
// configured schedule, and report `status`. It reaches the cadence only through
// the optional [ToolDreamSurface] its [ToolContext] hands it (PE-1) — a
// cognition booted without a dreaming cadence carries none, and the tool raises
// `ToolSurfaceUnavailable` rather than silently degrading.
//
// What this suite locks:
//
//   c-1 — `start` forces dreaming for the named `durationMinutes` (defaulting to
//         one hour) and refuses a non-positive duration.
//   c-2 — `stop` / `resume` / `continue` route to suspend / resume / resume.
//   c-3 — `status` reads the surface without mutating it; every action returns
//         the surface's status map.
//   c-4 — an unknown action is refused, and a context without a dream surface
//         raises `ToolSurfaceUnavailable`.

import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  group('c-1 dream.control start', () {
    test('start forces dreaming for the named duration and returns status',
        () async {
      final dream = _FakeDream();
      final result = await _run(
        <String, Object?>{'action': 'start', 'durationMinutes': 30},
        _ctx(dream),
      );

      expect(dream.calls, <String>['forceFor']);
      expect(dream.lastPeriod, const Duration(minutes: 30));
      expect(result, dream.statusReturn);
    });

    test('start without a duration defaults to one hour', () async {
      final dream = _FakeDream();
      await _run(<String, Object?>{'action': 'start'}, _ctx(dream));

      expect(dream.lastPeriod, const Duration(minutes: 60));
    });

    test('start refuses a non-positive duration', () {
      final dream = _FakeDream();
      expect(
        () => _run(
          <String, Object?>{'action': 'start', 'durationMinutes': 0},
          _ctx(dream),
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(dream.calls, isEmpty);
    });
  });

  group('c-2 dream.control stop / resume', () {
    test('stop suspends the cadence', () async {
      final dream = _FakeDream();
      await _run(<String, Object?>{'action': 'stop'}, _ctx(dream));
      expect(dream.calls, <String>['suspend']);
    });

    test('resume returns to the configured schedule', () async {
      final dream = _FakeDream();
      await _run(<String, Object?>{'action': 'resume'}, _ctx(dream));
      expect(dream.calls, <String>['resume']);
    });

    test('the continue alias also resumes the schedule', () async {
      final dream = _FakeDream();
      await _run(<String, Object?>{'action': 'continue'}, _ctx(dream));
      expect(dream.calls, <String>['resume']);
    });
  });

  group('c-3 dream.control status', () {
    test('status reads the surface without mutating it', () async {
      final dream = _FakeDream();
      final result =
          await _run(<String, Object?>{'action': 'status'}, _ctx(dream));

      // Only the read; no mode-changing call.
      expect(dream.calls, isEmpty);
      expect(result, dream.statusReturn);
    });
  });

  group('c-4 dream.control refusals', () {
    test('an unknown action is refused', () {
      final dream = _FakeDream();
      expect(
        () => _run(<String, Object?>{'action': 'sleepwalk'}, _ctx(dream)),
        throwsA(isA<ArgumentError>()),
      );
      expect(dream.calls, isEmpty);
    });

    test('a context without a dream surface raises ToolSurfaceUnavailable', () {
      expect(
        () => _run(<String, Object?>{'action': 'status'}, _ctx(null)),
        throwsA(isA<ToolSurfaceUnavailable>()
            .having((e) => e.surface, 'surface', 'dream')
            .having((e) => e.tool, 'tool', 'dream.control')),
      );
    });
  });
}

/// Looks the `dream.control` tool up in a fresh registry and runs it.
Future<Object?> _run(Map<String, Object?> args, ToolContext ctx) {
  final registry = ToolRegistry();
  registerBasicTools(registry);
  final tool = registry.lookup('dream.control');
  if (tool == null) throw StateError('no tool "dream.control"');
  return tool.run(args, ctx);
}

/// A [ToolContext] carrying the optional [dream] surface (or `null`) plus the
/// required-but-unused budget / memory / file-scope fields.
ToolContext _ctx(ToolDreamSurface? dream) => ToolContext(
      budget: BudgetLedger(ProcedureBudget(const <String, int>{})),
      memory: _NoopMemory(),
      fileScope: FileScope.fromPriorityList(const <String>['/tom-brain-engine']),
      dream: dream,
    );

/// A [ToolDreamSurface] test double recording which verbs the tool routes to.
class _FakeDream implements ToolDreamSurface {
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

/// A no-op memory client — the dream tool never touches memory.
class _NoopMemory implements TomBrainMemoryClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
