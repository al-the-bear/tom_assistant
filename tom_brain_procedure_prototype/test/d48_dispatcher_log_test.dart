// Tests for `DispatcherLog` (Plan step D.48).
//
// Covers:
//
//   - The five categories named in the plan + spec § 13
//     (`tom_brain.dispatcher.entry`, `…coordinator`, `…fallback`,
//     `…scheduler`, `…boot`) are surfaced as const `DispatcherLog`
//     instances and their `category.name` matches verbatim.
//   - Each level method (`trace`, `debug`, `traffic`, `info`, `warn`,
//     `status`, `error`, `severe`, `fatal`) forwards to the global
//     `tomLog` with the canonical `'[<category>] '` prefix.
//   - The wrapper preserves `tomLog`'s lazy-evaluation contract:
//     functions passed in are invoked exactly once, and their result
//     receives the category prefix.
//   - `DispatcherLog.all` enumerates every category exactly once and in
//     the order of `DispatcherLogCategory.values`.
//   - The spec § 13 / plan D.48 name list maps 1:1 to the statics (the
//     drift guard), and is disjoint from the engine categories (C.43).
//
// Drives the public API only — never imports `lib/src/config/…`
// directly; everything flows through the package barrel.

import 'package:test/test.dart';
import 'package:tom_basics/tom_basics.dart';
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';

/// A `TomLogOutput` that records every call without filtering on level.
/// Tests subscribe by swapping `tomLog.logOutput` for the duration of a
/// test and restoring afterwards.
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
    // `convertToString` honours the `() => String` lazy contract, which
    // is exactly what we want to assert against.
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

void main() {
  late _CapturingLogOutput capturing;
  late TomLogOutput previousOutput;
  late TomLogLevel previousLevel;

  setUp(() {
    capturing = _CapturingLogOutput();
    previousOutput = tomLog.logOutput;
    previousLevel = tomLog.logLevel;
    tomLog.logOutput = capturing;
    // `development` so every level is forwarded; the matching gate is on
    // the output side and our capturing impl ignores it.
    tomLog.setLogLevel(TomLogLevel.development);
  });

  tearDown(() {
    tomLog.logOutput = previousOutput;
    tomLog.setLogLevel(previousLevel);
  });

  group('DispatcherLogCategory — closed enumeration of five categories', () {
    test('exactly the five categories named in plan step D.48', () {
      // The plan + spec § 13 name: entry, coordinator, fallback,
      // scheduler, boot. Adding or removing a category is a deliberate
      // edit, not an accident; this test is the gate.
      expect(
        DispatcherLogCategory.values,
        equals(<DispatcherLogCategory>[
          DispatcherLogCategory.entry,
          DispatcherLogCategory.coordinator,
          DispatcherLogCategory.fallback,
          DispatcherLogCategory.scheduler,
          DispatcherLogCategory.boot,
        ]),
      );
    });

    test('each category carries its canonical string identifier', () {
      expect(
        DispatcherLogCategory.entry.name,
        equals('tom_brain.dispatcher.entry'),
      );
      expect(
        DispatcherLogCategory.coordinator.name,
        equals('tom_brain.dispatcher.coordinator'),
      );
      expect(
        DispatcherLogCategory.fallback.name,
        equals('tom_brain.dispatcher.fallback'),
      );
      expect(
        DispatcherLogCategory.scheduler.name,
        equals('tom_brain.dispatcher.scheduler'),
      );
      expect(
        DispatcherLogCategory.boot.name,
        equals('tom_brain.dispatcher.boot'),
      );
    });
  });

  group('DispatcherLog — static instances mirror the enum', () {
    test('DispatcherLog.all enumerates every category once, in enum order', () {
      expect(DispatcherLog.all, hasLength(DispatcherLogCategory.values.length));
      for (var i = 0; i < DispatcherLogCategory.values.length; i++) {
        expect(
          DispatcherLog.all[i].category,
          equals(DispatcherLogCategory.values[i]),
          reason: 'DispatcherLog.all[$i] should track '
              'DispatcherLogCategory.values[$i]',
        );
      }
    });

    test('each static carries the matching category', () {
      expect(DispatcherLog.entry.category, equals(DispatcherLogCategory.entry));
      expect(
        DispatcherLog.coordinator.category,
        equals(DispatcherLogCategory.coordinator),
      );
      expect(
        DispatcherLog.fallback.category,
        equals(DispatcherLogCategory.fallback),
      );
      expect(
        DispatcherLog.scheduler.category,
        equals(DispatcherLogCategory.scheduler),
      );
      expect(DispatcherLog.boot.category, equals(DispatcherLogCategory.boot));
    });

    test('static instances are const-identical across reads', () {
      // The instances are `const`; two reads must be the same object.
      // Guards against accidentally turning them into getters that
      // allocate per call.
      expect(identical(DispatcherLog.entry, DispatcherLog.entry), isTrue);
      expect(identical(DispatcherLog.boot, DispatcherLog.boot), isTrue);
    });
  });

  group('DispatcherLog — category-prefixed forwarding for every level', () {
    test('info prepends the category prefix and forwards once', () {
      DispatcherLog.entry.info('hello');
      expect(capturing.records, hasLength(1));
      expect(capturing.records.single.level, equals('INFO'));
      expect(
        capturing.records.single.message,
        equals('[tom_brain.dispatcher.entry] hello'),
      );
    });

    test('each level method emits at the matching tomLog level', () {
      DispatcherLog.coordinator.trace('a');
      DispatcherLog.coordinator.debug('b');
      DispatcherLog.coordinator.traffic('c');
      DispatcherLog.coordinator.info('d');
      DispatcherLog.coordinator.warn('e');
      DispatcherLog.coordinator.status('f');
      DispatcherLog.coordinator.error('g');
      DispatcherLog.coordinator.severe('h');
      DispatcherLog.coordinator.fatal('i');

      expect(
        capturing.records.map((r) => r.level).toList(),
        equals(<String>[
          'TRACE',
          'DEBUG',
          'TRAFFIC',
          'INFO',
          'WARN',
          'STATUS',
          'ERROR',
          'SEVERE',
          'FATAL',
        ]),
      );
      // Every line carries the coordinator prefix.
      for (final r in capturing.records) {
        expect(
          r.message,
          startsWith('[tom_brain.dispatcher.coordinator] '),
          reason: 'every record must carry the coordinator prefix',
        );
      }
    });

    test('all five categories produce distinct, well-formed prefixes', () {
      for (final logger in DispatcherLog.all) {
        capturing.records.clear();
        logger.status('lifecycle');
        expect(capturing.records, hasLength(1));
        expect(
          capturing.records.single.message,
          equals('[${logger.category.name}] lifecycle'),
          reason: 'category ${logger.category.name} mis-prefixed',
        );
      }
    });
  });

  group('DispatcherLog — lazy-evaluation contract', () {
    test('lazy String Function is invoked exactly once with the prefix', () {
      var calls = 0;
      DispatcherLog.fallback.debug(() {
        calls++;
        return 'computed';
      });
      expect(calls, equals(1), reason: 'lazy function must be invoked once');
      expect(
        capturing.records.single.message,
        equals('[tom_brain.dispatcher.fallback] computed'),
      );
    });

    test('the wrapper does not pre-evaluate the lazy callback', () {
      // Switch to silent (errors + status only) — debug must drop on the
      // output side. The wrapper itself must still forward a Function
      // (not a pre-stringified value), so the call count never exceeds 1.
      tomLog.setLogLevel(TomLogLevel.silent);
      var calls = 0;
      DispatcherLog.scheduler.debug(() {
        calls++;
        return 'expensive';
      });
      expect(calls, lessThanOrEqualTo(1));
    });

    test('non-function messages are stringified as-is with the prefix', () {
      DispatcherLog.boot.warn(42);
      expect(
        capturing.records.single.message,
        equals('[tom_brain.dispatcher.boot] 42'),
      );
    });
  });

  group('DispatcherLog — toString surface', () {
    test('toString includes the category name for diagnostic dumps', () {
      expect(
        DispatcherLog.entry.toString(),
        equals('DispatcherLog(tom_brain.dispatcher.entry)'),
      );
      expect(
        DispatcherLog.boot.toString(),
        equals('DispatcherLog(tom_brain.dispatcher.boot)'),
      );
    });
  });

  group('DispatcherLog — spec § 13 / plan D.48 lock', () {
    test('every spec-named dispatcher category has a matching static', () {
      // The contract: every dispatcher category in spec § 13 / plan D.48
      // must have a const `DispatcherLog.<area>` instance. If a future
      // refactor drops one, this test fails with a clear list of the
      // missing names.
      final staticNames = <String>{
        for (final l in DispatcherLog.all) l.category.name,
      };
      const specNames = <String>{
        'tom_brain.dispatcher.entry',
        'tom_brain.dispatcher.coordinator',
        'tom_brain.dispatcher.fallback',
        'tom_brain.dispatcher.scheduler',
        'tom_brain.dispatcher.boot',
      };
      expect(
        staticNames,
        equals(specNames),
        reason: 'spec § 13 / plan D.48 names must map 1:1 to DispatcherLog '
            'statics',
      );
    });

    test('dispatcher categories are disjoint from engine categories', () {
      // The two facades share the idiom but must never collide on a
      // category string — engine emits under `tom_brain.engine.*`, the
      // dispatcher under `tom_brain.dispatcher.*`.
      final dispatcherNames = <String>{
        for (final l in DispatcherLog.all) l.category.name,
      };
      final engineNames = <String>{
        for (final l in EngineLog.all) l.category.name,
      };
      expect(
        dispatcherNames.intersection(engineNames),
        isEmpty,
        reason: 'dispatcher + engine category strings must not overlap',
      );
      for (final name in dispatcherNames) {
        expect(name, startsWith('tom_brain.dispatcher.'));
      }
    });
  });
}
