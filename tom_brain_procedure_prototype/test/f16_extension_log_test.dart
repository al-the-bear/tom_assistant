// Extension F step 16 — `ExtensionLog` + `ExtensionLogCategory`
// (`prototype_tools_mcp_extension_plan.md` step 16;
// `tom_brain_procedure_prototype_specification.md` § 13).
//
// Covers:
//
//   - The five categories named in spec § 13 (`tom_brain.tools.registry`,
//     `…tools.invoke`, `…mcp.client`, `…prompt.template`, `…placeholder`)
//     are surfaced as const `ExtensionLog` instances whose `category.name`
//     matches verbatim.
//   - Each level method forwards to the global `tomLog` with the canonical
//     `'[<category>] '` prefix, preserving the lazy `() => String` contract.
//   - `ExtensionLog.all` enumerates every category once, in enum order.
//   - The spec § 13 name list maps 1:1 to the statics (the drift guard) and
//     is disjoint from the engine + dispatcher categories.
//
// Drives the public API only — everything flows through the package barrel.
// Mirrors `d48_dispatcher_log_test.dart` (D.48) and `engine_log_test.dart`
// (C.43).

import 'package:test/test.dart';
import 'package:tom_basics/tom_basics.dart';
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';

/// A `TomLogOutput` that records every call without filtering on level.
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

void main() {
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

  group('ExtensionLogCategory — closed enumeration of five categories', () {
    test('exactly the five categories named in spec § 13', () {
      expect(
        ExtensionLogCategory.values,
        equals(<ExtensionLogCategory>[
          ExtensionLogCategory.toolsRegistry,
          ExtensionLogCategory.toolsInvoke,
          ExtensionLogCategory.mcpClient,
          ExtensionLogCategory.promptTemplate,
          ExtensionLogCategory.placeholder,
        ]),
      );
    });

    test('each category carries its canonical string identifier', () {
      expect(ExtensionLogCategory.toolsRegistry.name,
          equals('tom_brain.tools.registry'));
      expect(ExtensionLogCategory.toolsInvoke.name,
          equals('tom_brain.tools.invoke'));
      expect(
          ExtensionLogCategory.mcpClient.name, equals('tom_brain.mcp.client'));
      expect(ExtensionLogCategory.promptTemplate.name,
          equals('tom_brain.prompt.template'));
      expect(ExtensionLogCategory.placeholder.name,
          equals('tom_brain.placeholder'));
    });
  });

  group('ExtensionLog — static instances mirror the enum', () {
    test('ExtensionLog.all enumerates every category once, in enum order', () {
      expect(ExtensionLog.all, hasLength(ExtensionLogCategory.values.length));
      for (var i = 0; i < ExtensionLogCategory.values.length; i++) {
        expect(
          ExtensionLog.all[i].category,
          equals(ExtensionLogCategory.values[i]),
        );
      }
    });

    test('each static carries the matching category', () {
      expect(ExtensionLog.toolsRegistry.category,
          equals(ExtensionLogCategory.toolsRegistry));
      expect(ExtensionLog.toolsInvoke.category,
          equals(ExtensionLogCategory.toolsInvoke));
      expect(ExtensionLog.mcpClient.category,
          equals(ExtensionLogCategory.mcpClient));
      expect(ExtensionLog.promptTemplate.category,
          equals(ExtensionLogCategory.promptTemplate));
      expect(ExtensionLog.placeholder.category,
          equals(ExtensionLogCategory.placeholder));
    });

    test('static instances are const-identical across reads', () {
      expect(
          identical(ExtensionLog.toolsRegistry, ExtensionLog.toolsRegistry),
          isTrue);
      expect(identical(ExtensionLog.placeholder, ExtensionLog.placeholder),
          isTrue);
    });
  });

  group('ExtensionLog — category-prefixed forwarding for every level', () {
    test('info prepends the category prefix and forwards once', () {
      ExtensionLog.toolsRegistry.info('hello');
      expect(capturing.records, hasLength(1));
      expect(capturing.records.single.level, equals('INFO'));
      expect(
        capturing.records.single.message,
        equals('[tom_brain.tools.registry] hello'),
      );
    });

    test('each level method emits at the matching tomLog level', () {
      ExtensionLog.mcpClient.trace('a');
      ExtensionLog.mcpClient.debug('b');
      ExtensionLog.mcpClient.traffic('c');
      ExtensionLog.mcpClient.info('d');
      ExtensionLog.mcpClient.warn('e');
      ExtensionLog.mcpClient.status('f');
      ExtensionLog.mcpClient.error('g');
      ExtensionLog.mcpClient.severe('h');
      ExtensionLog.mcpClient.fatal('i');

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
      for (final r in capturing.records) {
        expect(r.message, startsWith('[tom_brain.mcp.client] '));
      }
    });

    test('all five categories produce distinct, well-formed prefixes', () {
      for (final logger in ExtensionLog.all) {
        capturing.records.clear();
        logger.status('lifecycle');
        expect(capturing.records, hasLength(1));
        expect(
          capturing.records.single.message,
          equals('[${logger.category.name}] lifecycle'),
        );
      }
    });
  });

  group('ExtensionLog — lazy-evaluation contract', () {
    test('lazy String Function is invoked exactly once with the prefix', () {
      var calls = 0;
      ExtensionLog.promptTemplate.debug(() {
        calls++;
        return 'computed';
      });
      expect(calls, equals(1));
      expect(
        capturing.records.single.message,
        equals('[tom_brain.prompt.template] computed'),
      );
    });

    test('non-function messages are stringified as-is with the prefix', () {
      ExtensionLog.placeholder.warn(42);
      expect(
        capturing.records.single.message,
        equals('[tom_brain.placeholder] 42'),
      );
    });
  });

  group('ExtensionLog — toString surface', () {
    test('toString includes the category name for diagnostic dumps', () {
      expect(
        ExtensionLog.toolsInvoke.toString(),
        equals('ExtensionLog(tom_brain.tools.invoke)'),
      );
    });
  });

  group('ExtensionLog — spec § 13 lock', () {
    test('every spec-named extension category has a matching static', () {
      final staticNames = <String>{
        for (final l in ExtensionLog.all) l.category.name,
      };
      const specNames = <String>{
        'tom_brain.tools.registry',
        'tom_brain.tools.invoke',
        'tom_brain.mcp.client',
        'tom_brain.prompt.template',
        'tom_brain.placeholder',
      };
      expect(staticNames, equals(specNames));
    });

    test('extension categories are disjoint from engine + dispatcher', () {
      final extensionNames = <String>{
        for (final l in ExtensionLog.all) l.category.name,
      };
      final engineNames = <String>{
        for (final l in EngineLog.all) l.category.name,
      };
      final dispatcherNames = <String>{
        for (final l in DispatcherLog.all) l.category.name,
      };
      expect(extensionNames.intersection(engineNames), isEmpty);
      expect(extensionNames.intersection(dispatcherNames), isEmpty);
    });
  });
}
