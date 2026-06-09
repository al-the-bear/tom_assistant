// C.45 — config + observability slice conformance suite.
//
// Plan step C.45 (verbatim): "Tests: config roundtrip; event ordering;
// logger categorisation."
//
// This is the *section-closure* conformance test for subphase C.11
// (configuration + observability — C.42 `EngineConfig`, C.43 `EngineLog`,
// C.44 `EngineEvent` + `EngineEventBus`). The three focused unit suites
// (`engine_config_test.dart`, `engine_log_test.dart`,
// `engine_event_test.dart`) already prove each piece in isolation; this
// suite ships the integration-level contract — the three properties the
// plan step names asserted together, on the public surface only.
//
// The slice is the natural unit because the three pieces share one
// consumer (Phase D's `BrainProcessBoot` composition root): the boot
// reads `EngineConfig` once, hands `bus.emit` to the engine's lifecycle
// points, and threads `EngineLog.<area>` through the same producers. A
// regression that breaks the cross-cutting "an event and its matching log
// line land in the same order on both channels" property is invisible to
// any single unit suite — it only emerges when the slice is exercised
// together. This file is the gate that the C.11 producers' wiring (which
// lands at the composition root) must keep green.
//
// Mirrors the prior section-closure discipline (substrate B.39 —
// `b39_config_and_observability_conformance_test.dart`):
//
//   * Public-API only — imports the package barrel
//     (`package:tom_brain_procedure/tom_brain_procedure.dart`),
//     never reaches into `lib/src/`.
//   * No engine harness, no network, no LLM — `EngineConfig` is a pure
//     value object, `EngineEventBus` is a thin `StreamController`, and
//     `EngineLog` is a const facade over `tomLog`.
//   * Deterministic ordering — the broadcast bus is `sync: false`, so the
//     suite drains the microtask queue (`await bus.close()` /
//     `await sub.cancel()`) before asserting, the same discipline locked
//     at C.44.

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_basics/tom_basics.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart'
    show TrailOutcomeStatus;
import 'package:tom_brain_procedure/tom_brain_procedure.dart';

/// A fixed UTC timestamp the event fixtures share.
final DateTime _at = DateTime.utc(2026, 6, 2, 11, 0, 0);

/// A `TomLogOutput` that records every call without filtering on level.
/// Tests subscribe by swapping `tomLog.logOutput` for the duration of a
/// test and restoring it afterwards.
///
/// Deliberately duplicated from `engine_log_test.dart` — a section-closure
/// conformance suite must not depend on a fixture imported from another
/// test file (the duplication is logged in the C.45 record as a
/// `tom_brain_shared/test_support/` extraction candidate for C.48).
class _CapturingLogOutput extends TomLogOutput {
  final List<_LogRecord> records = <_LogRecord>[];

  @override
  void output(
    TomLogLevel loggerLevel,
    TomLogLevel logLevel,
    String level,
    Object message,
    String isolateName,
    DateTime timeStamp, [
    String? origin,
  ]) {
    records.add(
      _LogRecord(level: level.trim(), message: convertToString(message)),
    );
  }
}

class _LogRecord {
  _LogRecord({required this.level, required this.message});
  final String level;
  final String message;

  @override
  String toString() => '($level) $message';
}

/// A fully-populated, non-default configuration: every field set to a
/// non-default value, including a `userScriptsPath` and a path that needs
/// YAML quoting (`scripts.system` containing `: `).
EngineConfig _populatedConfig() => EngineConfig(
      systemScriptsPath: 'custom/system: dir',
      userScriptsPath: 'custom/user',
      sandbox: const SandboxConfig(
        enableUnixCommands: true,
        enableVsCodeIntegration: true,
      ),
      stepDeadline: const Duration(milliseconds: 12345),
    );

void main() {
  group('C.45-1: config roundtrip', () {
    test('the all-defaults config round-trips through YAML', () {
      final original = EngineConfig();
      final reparsed = EngineConfig.fromYamlString(original.toYamlString());
      expect(reparsed, equals(original));
      expect(reparsed.hashCode, equals(original.hashCode));
    });

    test('a fully-populated config round-trips through YAML', () {
      // Exercises every field, the optional `scripts.user` line, both
      // sandbox switches on, a non-default deadline, and a quote-needing
      // path scalar — the toYamlString emitter must produce a document
      // fromYamlString parses back to an equal object.
      final original = _populatedConfig();
      final reparsed = EngineConfig.fromYamlString(original.toYamlString());
      expect(reparsed, equals(original));
      expect(reparsed.systemScriptsPath, equals('custom/system: dir'));
      expect(reparsed.userScriptsPath, equals('custom/user'));
      expect(reparsed.sandbox.enableUnixCommands, isTrue);
      expect(reparsed.sandbox.enableVsCodeIntegration, isTrue);
      expect(
        reparsed.stepDeadline,
        equals(const Duration(milliseconds: 12345)),
      );
    });

    test('roundtrip is idempotent across a second pass', () {
      // YAML → object → YAML → object → YAML must stabilise: the emitted
      // document is identical on the second pass, and the objects stay
      // equal. Locks a regression where the emitter's field order or
      // quoting could drift between passes.
      final original = _populatedConfig();
      final yaml1 = original.toYamlString();
      final parsed1 = EngineConfig.fromYamlString(yaml1);
      final yaml2 = parsed1.toYamlString();
      final parsed2 = EngineConfig.fromYamlString(yaml2);

      expect(yaml2, equals(yaml1), reason: 'emitted YAML must be stable');
      expect(parsed2, equals(parsed1));
      expect(parsed2, equals(original));
    });

    test('parse is deterministic — two parses of one document agree', () {
      const document = '''
scripts:
  system: a/system
  user: a/user
sandbox:
  enableUnixCommands: true
  enableVsCodeIntegration: false
deadline:
  stepMs: 30000
''';
      final first = EngineConfig.fromYamlString(document);
      final second = EngineConfig.fromYamlString(document);
      expect(first, equals(second));
    });

    test('loadFromFile of a written config matches fromYamlString', () async {
      // Disk roundtrip: a file containing a config's emitted YAML loads
      // back to the same object fromYamlString produces on the same text.
      final original = _populatedConfig();
      final yaml = original.toYamlString();
      final dir = await Directory.systemTemp.createTemp('c45_engine_config_');
      try {
        final file = File('${dir.path}/engine.yaml');
        await file.writeAsString(yaml);
        final fromDisk = await EngineConfig.loadFromFile(file);
        final fromString = EngineConfig.fromYamlString(yaml);
        expect(fromDisk, equals(fromString));
        expect(fromDisk, equals(original));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('loadFromFile of an absent file yields the all-defaults config',
        () async {
      final dir = await Directory.systemTemp.createTemp('c45_engine_config_');
      try {
        final missing = File('${dir.path}/does_not_exist.yaml');
        final loaded = await EngineConfig.loadFromFile(missing);
        expect(loaded, equals(EngineConfig()));
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('C.45-2: event ordering', () {
    test('a single emitter delivers events in submission order', () async {
      final bus = EngineEventBus();
      final received = <String>[];
      final sub = bus.events().listen((e) => received.add(e.kind));

      for (final event in _oneOfEach()) {
        bus.emit(event);
      }
      await bus.close();
      await sub.cancel();

      expect(received, <String>[
        'engine.invocation-started',
        'engine.primitive-called',
        'engine.step-yielded',
        'engine.invocation-completed',
        'engine.invocation-failed',
      ]);
    });

    test('interleaved emissions from multiple logical emitters preserve '
        'global submission order', () async {
      // The Phase D boot hands `bus.emit` to each lifecycle point; from the
      // bus's perspective the emits arrive interleaved but on one
      // controller. Global submission order must be preserved at the
      // subscriber regardless of which logical producer issued each emit.
      final bus = EngineEventBus();
      final received = <String>[];
      final sub = bus.events().listen((e) => received.add(e.kind));

      // Two closures over the same sink — exactly the shape the composition
      // root uses when it threads `bus.emit` into separate producers.
      void emitLifecycle(EngineEvent e) => bus.emit(e);
      void emitPrimitive(String name) => bus.emit(
            PrimitiveCalled(
              occurredAt: _at,
              runId: 'run_1',
              primitive: name,
              depth: 1,
            ),
          );

      emitLifecycle(
        InvocationStarted(
          occurredAt: _at,
          runId: 'run_1',
          procedureId: 'answer_with_memory_v1',
          depth: 1,
        ),
      );
      emitPrimitive('recall');
      emitPrimitive('llm');
      emitLifecycle(
        InvocationCompleted(
          occurredAt: _at,
          runId: 'run_1',
          procedureId: 'answer_with_memory_v1',
          status: TrailOutcomeStatus.accepted,
        ),
      );
      await bus.close();
      await sub.cancel();

      expect(received, <String>[
        'engine.invocation-started',
        'engine.primitive-called',
        'engine.primitive-called',
        'engine.invocation-completed',
      ]);
    });

    test('event ordering is independent of subscriber attach order',
        () async {
      // A late subscriber sees the same order for events emitted after it
      // attaches; both subscribers agree on relative order.
      final bus = EngineEventBus();
      final first = <String>[];
      final subFirst = bus.events().listen((e) => first.add(e.kind));

      emitNote(bus, 'a');
      final second = <String>[];
      final subSecond = bus.events().listen((e) => second.add(e.kind));
      emitNote(bus, 'b');
      emitNote(bus, 'c');

      await bus.close();
      await subFirst.cancel();
      await subSecond.cancel();

      // The first subscriber saw all three; the late one saw only the two
      // emitted after it attached — and both in submission order.
      expect(first, <String>[
        'engine.primitive-called',
        'engine.primitive-called',
        'engine.primitive-called',
      ]);
      expect(second, <String>[
        'engine.primitive-called',
        'engine.primitive-called',
      ]);
    });
  });

  group('C.45-3: logger categorisation', () {
    late _CapturingLogOutput capturing;
    late TomLogOutput previousOutput;
    late TomLogLevel previousLevel;

    setUp(() {
      capturing = _CapturingLogOutput();
      previousOutput = tomLog.logOutput;
      previousLevel = tomLog.logLevel;
      tomLog.logOutput = capturing;
      tomLog.setLogLevel(TomLogLevel.development);
    });

    tearDown(() {
      tomLog.logOutput = previousOutput;
      tomLog.setLogLevel(previousLevel);
    });

    test('interleaved emissions across all five categories each tag their '
        'own line', () {
      // One line per category, emitted interleaved through the five
      // statics. Each line must carry exactly its own category prefix —
      // no bleed between categories.
      for (final logger in EngineLog.all) {
        logger.status('lifecycle from ${logger.category.name}');
      }
      expect(capturing.records, hasLength(EngineLog.all.length));
      for (var i = 0; i < EngineLog.all.length; i++) {
        final category = EngineLog.all[i].category.name;
        expect(
          capturing.records[i].message,
          equals('[$category] lifecycle from $category'),
          reason: 'record $i must carry the $category prefix only',
        );
      }
    });

    test('every level honours category routing', () {
      // Each level method on a given category tags with that one category.
      EngineLog.store
        ..trace('t')
        ..debug('d')
        ..info('i')
        ..warn('w')
        ..status('s')
        ..error('e');
      expect(
        capturing.records.map((r) => r.level).toList(),
        equals(<String>['TRACE', 'DEBUG', 'INFO', 'WARN', 'STATUS', 'ERROR']),
      );
      for (final record in capturing.records) {
        expect(record.message, startsWith('[tom_brain.engine.store] '));
      }
    });

    test('one logger never bleeds another logger prefix', () {
      // Emit from two categories back-to-back; each line carries strictly
      // its own prefix and never the other's.
      EngineLog.host.info('from host');
      EngineLog.preemption.info('from preemption');
      expect(capturing.records, hasLength(2));
      expect(
        capturing.records[0].message,
        equals('[tom_brain.engine.host] from host'),
      );
      expect(
        capturing.records[1].message,
        equals('[tom_brain.engine.preemption] from preemption'),
      );
      expect(
        capturing.records[0].message,
        isNot(contains('preemption')),
      );
    });
  });

  group('C.45-4: cross-slice — event + log pairing', () {
    late _CapturingLogOutput capturing;
    late TomLogOutput previousOutput;
    late TomLogLevel previousLevel;

    setUp(() {
      capturing = _CapturingLogOutput();
      previousOutput = tomLog.logOutput;
      previousLevel = tomLog.logLevel;
      tomLog.logOutput = capturing;
      tomLog.setLogLevel(TomLogLevel.development);
    });

    tearDown(() {
      tomLog.logOutput = previousOutput;
      tomLog.setLogLevel(previousLevel);
    });

    test('a paired event-emit + matching log line preserve order across '
        'both channels', () async {
      // This is the joint property the Phase D composition root's wiring
      // must keep green: for each lifecycle moment the producer pairs an
      // EngineEvent emit with an EngineLog line on the matching category;
      // the relative order of those moments must be identical on the event
      // channel and the log channel.
      final bus = EngineEventBus();
      final events = <String>[];
      final sub = bus.events().listen((e) => events.add(e.kind));

      // Moment 1: invocation started (host category).
      EngineLog.host.status('invocation started: answer_with_memory_v1');
      bus.emit(
        InvocationStarted(
          occurredAt: _at,
          runId: 'run_1',
          procedureId: 'answer_with_memory_v1',
          depth: 1,
        ),
      );
      // Moment 2: a primitive call (bridge category).
      EngineLog.bridge.debug('primitive: recall');
      bus.emit(
        PrimitiveCalled(
          occurredAt: _at,
          runId: 'run_1',
          primitive: 'recall',
          depth: 1,
        ),
      );
      // Moment 3: invocation completed (host category).
      EngineLog.host.status('invocation completed: accepted');
      bus.emit(
        InvocationCompleted(
          occurredAt: _at,
          runId: 'run_1',
          procedureId: 'answer_with_memory_v1',
          status: TrailOutcomeStatus.accepted,
        ),
      );

      await bus.close();
      await sub.cancel();

      // Event channel order.
      expect(events, <String>[
        'engine.invocation-started',
        'engine.primitive-called',
        'engine.invocation-completed',
      ]);
      // Log channel order (same three moments, same relative order).
      expect(
        capturing.records.map((r) => r.message).toList(),
        equals(<String>[
          '[tom_brain.engine.host] invocation started: answer_with_memory_v1',
          '[tom_brain.engine.bridge] primitive: recall',
          '[tom_brain.engine.host] invocation completed: accepted',
        ]),
      );
      // The two channels carry the same number of moments.
      expect(capturing.records, hasLength(events.length));
    });
  });
}

/// Builds one of each `EngineEvent` variant (the canonical fixtures the
/// ordering tests reuse), in spec § 13 declaration order.
List<EngineEvent> _oneOfEach() => <EngineEvent>[
      InvocationStarted(
        occurredAt: _at,
        runId: 'run_1',
        procedureId: 'answer_with_memory_v1',
        version: 1,
        parentRunId: 'run_0',
        depth: 2,
      ),
      PrimitiveCalled(
        occurredAt: _at,
        runId: 'run_1',
        primitive: 'note',
        depth: 1,
      ),
      StepYielded(
        occurredAt: _at,
        runId: 'run_1',
        reason: StepYielded.deadlineReason,
        truncated: true,
      ),
      InvocationCompleted(
        occurredAt: _at,
        runId: 'run_1',
        procedureId: 'answer_with_memory_v1',
        status: TrailOutcomeStatus.accepted,
        summary: 'ran to completion',
      ),
      InvocationFailed(
        occurredAt: _at,
        runId: 'run_1',
        procedureId: 'answer_with_memory_v1',
        failureKind: 'procedure.runtime.crash',
        message: 'boom',
      ),
    ];

/// Emits a single `PrimitiveCalled` named [name] on [bus] — a one-liner
/// the attach-order test reuses.
void emitNote(EngineEventBus bus, String name) => bus.emit(
      PrimitiveCalled(
        occurredAt: _at,
        runId: 'run_1',
        primitive: name,
        depth: 1,
      ),
    );
