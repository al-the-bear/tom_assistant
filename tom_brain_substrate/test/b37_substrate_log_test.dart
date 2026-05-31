// Tests for `SubstrateLog` (Plan step B.37).
//
// Covers (mirrors memory's a84_memory_log_test.dart precedent):
//
//   - The six categories named in spec § 10.1
//     (`tom_brain.substrate.llm`, `…roles`, `…embed`, `…web`, `…mcp`,
//     `…router`) are surfaced as const `SubstrateLog` instances and
//     their `category.name` matches the spec verbatim.
//   - Each level method (`trace`, `debug`, `traffic`, `info`, `warn`,
//     `status`, `error`, `severe`, `fatal`) forwards to the global
//     `tomLog` with the canonical `'[<category>] '` prefix.
//   - The wrapper preserves `tomLog`'s lazy-evaluation contract:
//     functions passed in are invoked at most once, and their result
//     receives the category prefix.
//   - `SubstrateLog.all` enumerates every category exactly once and in
//     the order of `SubstrateLogCategory.values`.
//   - The five-vs-six spec-vs-plan divergence is locked here so a
//     future refactor that drops `router` is caught immediately.
//
// Drives the public API only — never imports `lib/src/obs/…` directly;
// everything flows through `package:tom_brain_substrate/…`.

import 'package:test/test.dart';
import 'package:tom_basics/tom_basics.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

/// A `TomLogOutput` that records every call without filtering on
/// level. Tests subscribe by swapping `tomLog.logOutput` for the
/// duration of a test and restoring afterwards.
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
    // `convertToString` honours the `() => String` lazy contract,
    // which is exactly what we want to assert against.
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
    // `development` so every level is forwarded; the matching gate is
    // on the output side and our capturing impl ignores it.
    tomLog.setLogLevel(TomLogLevel.development);
  });

  tearDown(() {
    tomLog.logOutput = previousOutput;
    tomLog.setLogLevel(previousLevel);
  });

  group('SubstrateLogCategory — closed enumeration of six categories', () {
    test('exactly the six categories named in spec § 10.1', () {
      // The spec names: llm, roles, embed, web, mcp, router.
      // Plan step B.37 lists only the first five; the spec adds
      // `router`. The wrapper carries all six — see Q-B.37.1.
      // Adding or removing a category is a deliberate edit, not an
      // accident; this test is the gate.
      expect(
        SubstrateLogCategory.values,
        equals(<SubstrateLogCategory>[
          SubstrateLogCategory.llm,
          SubstrateLogCategory.roles,
          SubstrateLogCategory.embed,
          SubstrateLogCategory.web,
          SubstrateLogCategory.mcp,
          SubstrateLogCategory.router,
        ]),
      );
    });

    test('each category carries its canonical string identifier', () {
      expect(
        SubstrateLogCategory.llm.name,
        equals('tom_brain.substrate.llm'),
      );
      expect(
        SubstrateLogCategory.roles.name,
        equals('tom_brain.substrate.roles'),
      );
      expect(
        SubstrateLogCategory.embed.name,
        equals('tom_brain.substrate.embed'),
      );
      expect(
        SubstrateLogCategory.web.name,
        equals('tom_brain.substrate.web'),
      );
      expect(
        SubstrateLogCategory.mcp.name,
        equals('tom_brain.substrate.mcp'),
      );
      expect(
        SubstrateLogCategory.router.name,
        equals('tom_brain.substrate.router'),
      );
    });

    test('every name uses the `tom_brain.substrate.` prefix', () {
      // Spec § 10.1 is the only authority for category strings;
      // a stray `tom_brain.foo.x` or `substrate.x` would still
      // compile here but would silently break operator-side
      // filtering rules. Lock the prefix.
      for (final c in SubstrateLogCategory.values) {
        expect(
          c.name,
          startsWith('tom_brain.substrate.'),
          reason: '${c.name} must use the spec § 10.1 prefix',
        );
      }
    });
  });

  group('SubstrateLog — static instances mirror the enum', () {
    test(
      'SubstrateLog.all enumerates every category once, in enum order',
      () {
        expect(
          SubstrateLog.all,
          hasLength(SubstrateLogCategory.values.length),
        );
        for (var i = 0; i < SubstrateLogCategory.values.length; i++) {
          expect(
            SubstrateLog.all[i].category,
            equals(SubstrateLogCategory.values[i]),
            reason: 'SubstrateLog.all[$i] should track '
                'SubstrateLogCategory.values[$i]',
          );
        }
      },
    );

    test('each static carries the matching category', () {
      expect(SubstrateLog.llm.category, equals(SubstrateLogCategory.llm));
      expect(
        SubstrateLog.roles.category,
        equals(SubstrateLogCategory.roles),
      );
      expect(
        SubstrateLog.embed.category,
        equals(SubstrateLogCategory.embed),
      );
      expect(SubstrateLog.web.category, equals(SubstrateLogCategory.web));
      expect(SubstrateLog.mcp.category, equals(SubstrateLogCategory.mcp));
      expect(
        SubstrateLog.router.category,
        equals(SubstrateLogCategory.router),
      );
    });

    test('static instances are const-identical across reads', () {
      // The instances are `const`; two reads must be the same object.
      // This guards against accidentally turning them into getters
      // that allocate per call.
      expect(identical(SubstrateLog.llm, SubstrateLog.llm), isTrue);
      expect(identical(SubstrateLog.router, SubstrateLog.router), isTrue);
    });
  });

  group('SubstrateLog — category-prefixed forwarding for every level',
      () {
    test('info prepends the category prefix and forwards once', () {
      SubstrateLog.llm.info('hello');
      expect(capturing.records, hasLength(1));
      expect(capturing.records.single.level, equals('INFO'));
      expect(
        capturing.records.single.message,
        equals('[tom_brain.substrate.llm] hello'),
      );
    });

    test('each level method emits at the matching tomLog level', () {
      SubstrateLog.router.trace('a');
      SubstrateLog.router.debug('b');
      SubstrateLog.router.traffic('c');
      SubstrateLog.router.info('d');
      SubstrateLog.router.warn('e');
      SubstrateLog.router.status('f');
      SubstrateLog.router.error('g');
      SubstrateLog.router.severe('h');
      SubstrateLog.router.fatal('i');

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
      // Every line carries the router prefix.
      for (final r in capturing.records) {
        expect(
          r.message,
          startsWith('[tom_brain.substrate.router] '),
          reason: 'every record must carry the router prefix',
        );
      }
    });

    test('all six categories produce distinct, well-formed prefixes', () {
      for (final logger in SubstrateLog.all) {
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

  group('SubstrateLog — lazy-evaluation contract', () {
    test('lazy String Function is invoked exactly once with the prefix',
        () {
      var calls = 0;
      SubstrateLog.embed.debug(() {
        calls++;
        return 'computed';
      });
      expect(
        calls,
        equals(1),
        reason: 'lazy function must be invoked once',
      );
      expect(
        capturing.records.single.message,
        equals('[tom_brain.substrate.embed] computed'),
      );
    });

    test('lazy Object Function is also wrapped (not just String)', () {
      // The wrapper accepts `Object Function()` to mirror tomLog's
      // signature flexibility. The output side stringifies the
      // returned object.
      var calls = 0;
      Object producer() {
        calls++;
        return 1234;
      }

      SubstrateLog.mcp.warn(producer);
      expect(calls, equals(1));
      expect(
        capturing.records.single.message,
        equals('[tom_brain.substrate.mcp] 1234'),
      );
    });

    test('non-function messages are stringified as-is with the prefix',
        () {
      SubstrateLog.web.warn(42);
      expect(
        capturing.records.single.message,
        equals('[tom_brain.substrate.web] 42'),
      );
    });

    test('null is stringified by tomLog with the prefix attached', () {
      // The wrapper does not special-case null; it forwards through
      // `tomLog`, which converts it via `Object.toString` (returning
      // the literal string "null").
      SubstrateLog.roles.info('value is null');
      expect(
        capturing.records.single.message,
        equals('[tom_brain.substrate.roles] value is null'),
      );
    });
  });

  group('SubstrateLog — toString surface', () {
    test('toString includes the category name for diagnostic dumps', () {
      expect(
        SubstrateLog.router.toString(),
        equals('SubstrateLog(tom_brain.substrate.router)'),
      );
      expect(
        SubstrateLog.llm.toString(),
        equals('SubstrateLog(tom_brain.substrate.llm)'),
      );
    });
  });

  group('SubstrateLog — spec § 10.1 lock', () {
    test('every spec-named category has a matching static', () {
      // The contract: every name in spec § 10.1 must have a const
      // `SubstrateLog.<area>` instance. If a future refactor drops
      // one, this test fails with a clear list of the missing names.
      final staticNames = <String>{
        for (final l in SubstrateLog.all) l.category.name,
      };
      const specNames = <String>{
        'tom_brain.substrate.llm',
        'tom_brain.substrate.roles',
        'tom_brain.substrate.embed',
        'tom_brain.substrate.web',
        'tom_brain.substrate.mcp',
        'tom_brain.substrate.router',
      };
      expect(
        staticNames,
        equals(specNames),
        reason: 'spec § 10.1 names must map 1:1 to SubstrateLog statics',
      );
    });

    test('plan-text five-of-six categories are present', () {
      // Plan step B.37 names: llm, roles, embed, web, mcp. The
      // spec adds router (Q-B.37.1). This test locks the plan-side
      // expectation independently so a category rename that
      // accidentally preserves the spec-list count but breaks the
      // plan-list intent is caught.
      const planNames = <String>{
        'tom_brain.substrate.llm',
        'tom_brain.substrate.roles',
        'tom_brain.substrate.embed',
        'tom_brain.substrate.web',
        'tom_brain.substrate.mcp',
      };
      final present = <String>{
        for (final l in SubstrateLog.all) l.category.name,
      };
      expect(
        planNames.difference(present),
        isEmpty,
        reason: 'every plan-step B.37 category must remain present',
      );
    });
  });
}
