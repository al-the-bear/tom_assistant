// Tests for `EngineLog` (Plan step C.43).
//
// Covers:
//
//   - The five categories named in the plan + spec § 13
//     (`tom_brain.engine.host`, `…bridge`, `…store`, `…recorder`,
//     `…preemption`) are surfaced as const `EngineLog` instances and
//     their `category.name` matches verbatim.
//   - Each level method (`trace`, `debug`, `traffic`, `info`, `warn`,
//     `status`, `error`, `severe`, `fatal`) forwards to the global
//     `tomLog` with the canonical `'[<category>] '` prefix.
//   - The wrapper preserves `tomLog`'s lazy-evaluation contract:
//     functions passed in are invoked exactly once, and their result
//     receives the category prefix.
//   - `EngineLog.all` enumerates every category exactly once and in the
//     order of `EngineLogCategory.values`.
//   - The spec § 13 / plan C.43 name list maps 1:1 to the statics (the
//     drift guard).
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

  group('EngineLogCategory — closed enumeration of five categories', () {
    test('exactly the five categories named in plan step C.43', () {
      // The plan + spec § 13 name: host, bridge, store, recorder,
      // preemption. Adding or removing a category is a deliberate edit,
      // not an accident; this test is the gate.
      expect(
        EngineLogCategory.values,
        equals(<EngineLogCategory>[
          EngineLogCategory.host,
          EngineLogCategory.bridge,
          EngineLogCategory.store,
          EngineLogCategory.recorder,
          EngineLogCategory.preemption,
        ]),
      );
    });

    test('each category carries its canonical string identifier', () {
      expect(EngineLogCategory.host.name, equals('tom_brain.engine.host'));
      expect(EngineLogCategory.bridge.name, equals('tom_brain.engine.bridge'));
      expect(EngineLogCategory.store.name, equals('tom_brain.engine.store'));
      expect(
        EngineLogCategory.recorder.name,
        equals('tom_brain.engine.recorder'),
      );
      expect(
        EngineLogCategory.preemption.name,
        equals('tom_brain.engine.preemption'),
      );
    });
  });

  group('EngineLog — static instances mirror the enum', () {
    test('EngineLog.all enumerates every category once, in enum order', () {
      expect(EngineLog.all, hasLength(EngineLogCategory.values.length));
      for (var i = 0; i < EngineLogCategory.values.length; i++) {
        expect(
          EngineLog.all[i].category,
          equals(EngineLogCategory.values[i]),
          reason: 'EngineLog.all[$i] should track '
              'EngineLogCategory.values[$i]',
        );
      }
    });

    test('each static carries the matching category', () {
      expect(EngineLog.host.category, equals(EngineLogCategory.host));
      expect(EngineLog.bridge.category, equals(EngineLogCategory.bridge));
      expect(EngineLog.store.category, equals(EngineLogCategory.store));
      expect(EngineLog.recorder.category, equals(EngineLogCategory.recorder));
      expect(
        EngineLog.preemption.category,
        equals(EngineLogCategory.preemption),
      );
    });

    test('static instances are const-identical across reads', () {
      // The instances are `const`; two reads must be the same object.
      // Guards against accidentally turning them into getters that
      // allocate per call.
      expect(identical(EngineLog.host, EngineLog.host), isTrue);
      expect(identical(EngineLog.preemption, EngineLog.preemption), isTrue);
    });
  });

  group('EngineLog — category-prefixed forwarding for every level', () {
    test('info prepends the category prefix and forwards once', () {
      EngineLog.host.info('hello');
      expect(capturing.records, hasLength(1));
      expect(capturing.records.single.level, equals('INFO'));
      expect(
        capturing.records.single.message,
        equals('[tom_brain.engine.host] hello'),
      );
    });

    test('each level method emits at the matching tomLog level', () {
      EngineLog.recorder.trace('a');
      EngineLog.recorder.debug('b');
      EngineLog.recorder.traffic('c');
      EngineLog.recorder.info('d');
      EngineLog.recorder.warn('e');
      EngineLog.recorder.status('f');
      EngineLog.recorder.error('g');
      EngineLog.recorder.severe('h');
      EngineLog.recorder.fatal('i');

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
      // Every line carries the recorder prefix.
      for (final r in capturing.records) {
        expect(
          r.message,
          startsWith('[tom_brain.engine.recorder] '),
          reason: 'every record must carry the recorder prefix',
        );
      }
    });

    test('all five categories produce distinct, well-formed prefixes', () {
      for (final logger in EngineLog.all) {
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

  group('EngineLog — lazy-evaluation contract', () {
    test('lazy String Function is invoked exactly once with the prefix', () {
      var calls = 0;
      EngineLog.store.debug(() {
        calls++;
        return 'computed';
      });
      expect(calls, equals(1), reason: 'lazy function must be invoked once');
      expect(
        capturing.records.single.message,
        equals('[tom_brain.engine.store] computed'),
      );
    });

    test('the wrapper does not pre-evaluate the lazy callback', () {
      // Switch to silent (errors + status only) — debug must drop on the
      // output side. The wrapper itself must still forward a Function
      // (not a pre-stringified value), so the call count never exceeds 1.
      tomLog.setLogLevel(TomLogLevel.silent);
      var calls = 0;
      EngineLog.preemption.debug(() {
        calls++;
        return 'expensive';
      });
      expect(calls, lessThanOrEqualTo(1));
    });

    test('non-function messages are stringified as-is with the prefix', () {
      EngineLog.bridge.warn(42);
      expect(
        capturing.records.single.message,
        equals('[tom_brain.engine.bridge] 42'),
      );
    });
  });

  group('EngineLog — toString surface', () {
    test('toString includes the category name for diagnostic dumps', () {
      expect(
        EngineLog.bridge.toString(),
        equals('EngineLog(tom_brain.engine.bridge)'),
      );
      expect(
        EngineLog.host.toString(),
        equals('EngineLog(tom_brain.engine.host)'),
      );
    });
  });

  group('EngineLog — spec § 13 / plan C.43 lock', () {
    test('every spec-named engine category has a matching static', () {
      // The contract: every engine category in spec § 13 / plan C.43 must
      // have a const `EngineLog.<area>` instance. If a future refactor
      // drops one, this test fails with a clear list of the missing names.
      final staticNames = <String>{
        for (final l in EngineLog.all) l.category.name,
      };
      const specNames = <String>{
        'tom_brain.engine.host',
        'tom_brain.engine.bridge',
        'tom_brain.engine.store',
        'tom_brain.engine.recorder',
        'tom_brain.engine.preemption',
      };
      expect(
        staticNames,
        equals(specNames),
        reason: 'spec § 13 / plan C.43 names must map 1:1 to EngineLog '
            'statics',
      );
    });
  });
}
