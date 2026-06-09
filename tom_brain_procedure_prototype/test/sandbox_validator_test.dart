// C.28 — SandboxValidator unit tests.
//
// Covers the second validator layer (`tom_brain_procedure_prototype_
// specification.md` § 7, row 3 → `procedure.sandbox.violation`):
//
//   - validateSource: accepts a legit recall → llm → persist procedure;
//     rejects `import` / `export` directives; rejects each family of
//     disallowed top-level identifier (file system, process, isolate,
//     network, standard streams, eval).
//   - code projection: a banned word inside a line comment, a block
//     comment, or a string literal is *not* flagged; a banned word inside
//     a string interpolation *is* flagged (interpolated code is real code);
//     a member access (`obj.Process`) and a longer identifier
//     (`Processor`) are not flagged.
//   - validate / validateAll: attribution to the procedure id; a clean set
//     passes, a set containing one malicious procedure fails.
//   - configurable deny sets via the constructor.
//
// Every failure carries the stable wire code `procedure.sandbox.violation`;
// the tests assert on `code`, `kind`, and `offender`, not on the human
// message, matching the C.24/C.25/C.27 style.

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';
import 'package:test/test.dart';

/// A representative legit procedure: a header doc-comment plus a `run`
/// function that only touches the bridged primitive API. Reaches none of
/// the deny sets.
const String _legitSource = '''
/// @procedure
/// id: answer_with_memory
/// version: 1
/// summary: recall, answer, persist
/// successCriterion: a streamed answer is delivered
/// budget: { wallClockMs: 60000 }
/// requires: [ recall, llm, persist ]
Future<ProcedureResult> run(ProcedureInputs inputs) async {
  final hits = await recall(inputs.text, k: 8);
  final answer = await llm('Answer using: \${hits.summary}', role: 'assistant');
  await persist(answer);
  return ProcedureResult.ok(answer);
}
''';

/// Wraps [source] in a [LoadedProcedure] so the `validate` / `validateAll`
/// paths can be exercised.
LoadedProcedure _loaded(String source, {String id = 'p', int version = 1}) =>
    LoadedProcedure(
      ref: ProcedureRef.system('/$id.v$version.dart'),
      header: ProcedureHeader(
        id: id,
        version: version,
        summary: 'summary',
        successCriterion: 'criterion',
        budget: ProcedureBudget(const {'wallClockMs': 60000}),
      ),
      source: source,
    );

/// Asserts [body] throws a [ProcedureSandboxViolation] carrying the
/// canonical wire code and (when given) the expected [kind] and [offender].
void _expectViolation(
  void Function() body, {
  SandboxViolationKind? kind,
  String? offender,
}) {
  expect(
    body,
    throwsA(
      isA<ProcedureSandboxViolation>()
          .having((e) => e.code, 'code', procedureSandboxViolationCode)
          .having((e) => e.kind, 'kind', kind ?? anything)
          .having((e) => e.offender, 'offender', offender ?? anything),
    ),
  );
}

void main() {
  const validator = SandboxValidator.shared;

  group('SandboxValidator.validateSource — happy path', () {
    test('accepts a legit recall/llm/persist procedure', () {
      expect(() => validator.validateSource(_legitSource), returnsNormally);
    });

    test('accepts an empty source', () {
      expect(() => validator.validateSource(''), returnsNormally);
    });
  });

  group('SandboxValidator.validateSource — forbidden directives', () {
    test('rejects an import directive', () {
      _expectViolation(
        () => validator.validateSource("import 'dart:io';"),
        kind: SandboxViolationKind.forbiddenDirective,
        offender: 'import',
      );
    });

    test('rejects an export directive', () {
      _expectViolation(
        () => validator.validateSource("export 'something.dart';"),
        kind: SandboxViolationKind.forbiddenDirective,
        offender: 'export',
      );
    });

    test('does not flag `import` inside an identifier (importantThing)', () {
      expect(
        () => validator.validateSource('final importantThing = 1;'),
        returnsNormally,
      );
    });
  });

  group('SandboxValidator.validateSource — import allow-list (E.3.5)', () {
    test('accepts an import of the memory bridge library', () {
      expect(
        () => validator
            .validateSource("import '${BrainBridges.memoryLibrary}';"),
        returnsNormally,
      );
    });

    test('accepts the four host-injected imports together', () {
      final source = '''
import '${BrainBridges.memoryLibrary}';
import '${BrainBridges.substrateLibrary}';
import '$engineNativeLibrary';
import '$procedureInputsLibrary';

Future<Object?> run(inputs) async => 1;
''';
      expect(() => validator.validateSource(source), returnsNormally);
    });

    test('rejects an import of a package not on the allow-list', () {
      _expectViolation(
        () => validator.validateSource("import 'package:evil/evil.dart';"),
        kind: SandboxViolationKind.forbiddenDirective,
        offender: 'import',
      );
    });

    test('rejects a relative import even of a same-named source file', () {
      _expectViolation(
        () => validator.validateSource("import 'memory_bridge.dart';"),
        offender: 'import',
      );
    });

    test('the default allow-list is exactly the host-injected library URIs',
        () {
      expect(
        SandboxValidator.defaultAllowedImportUris,
        <String>{
          BrainBridges.memoryLibrary,
          BrainBridges.substrateLibrary,
          // D.43 — the tool library brings the `tool` global into scope for the
          // tool-calling loop; the engine binds a per-run `ToolBridge` on every
          // run, so the import always resolves. `BrainBridges.mcpLibrary` stays
          // off the list until the engine wires the `mcp` global.
          BrainBridges.toolLibrary,
          engineNativeLibrary,
          procedureInputsLibrary,
          procedureResultLibrary,
        },
      );
    });

    test('reports the 1-based line of an off-list import', () {
      try {
        validator.validateSource("var a = 1;\nimport 'dart:io';");
        fail('expected a ProcedureSandboxViolation');
      } on ProcedureSandboxViolation catch (e) {
        expect(e.line, 2);
      }
    });
  });

  group('SandboxValidator.validateSource — disallowed identifiers', () {
    test('rejects Process', () {
      _expectViolation(
        () => validator.validateSource("Process.run('ls', []);"),
        kind: SandboxViolationKind.disallowedIdentifier,
        offender: 'Process',
      );
    });

    test('rejects File', () {
      _expectViolation(
        () => validator.validateSource("final f = File('/etc/passwd');"),
        kind: SandboxViolationKind.disallowedIdentifier,
        offender: 'File',
      );
    });

    test('rejects Isolate', () {
      _expectViolation(
        () => validator.validateSource('Isolate.spawn(entry, msg);'),
        kind: SandboxViolationKind.disallowedIdentifier,
        offender: 'Isolate',
      );
    });

    test('rejects HttpClient', () {
      _expectViolation(
        () => validator.validateSource('final c = HttpClient();'),
        kind: SandboxViolationKind.disallowedIdentifier,
        offender: 'HttpClient',
      );
    });

    test('rejects exit', () {
      _expectViolation(
        () => validator.validateSource('exit(0);'),
        kind: SandboxViolationKind.disallowedIdentifier,
        offender: 'exit',
      );
    });

    test('rejects eval', () {
      _expectViolation(
        () => validator.validateSource('eval(mySource);'),
        kind: SandboxViolationKind.disallowedIdentifier,
        offender: 'eval',
      );
    });

    test('does not flag a member access (obj.Process)', () {
      expect(
        () => validator.validateSource('final p = host.Process;'),
        returnsNormally,
      );
    });

    test('does not flag a longer identifier that contains a banned word',
        () {
      expect(
        () => validator.validateSource('final Processor x = build();'),
        returnsNormally,
      );
    });
  });

  group('SandboxValidator.validateSource — code projection', () {
    test('ignores a banned word in a line comment', () {
      expect(
        () => validator.validateSource('// Process.run is forbidden\nvar x = 1;'),
        returnsNormally,
      );
    });

    test('ignores a banned word in a block comment', () {
      expect(
        () => validator.validateSource('/* uses File and Isolate */ var x = 1;'),
        returnsNormally,
      );
    });

    test('ignores a banned word inside a string literal', () {
      expect(
        () => validator.validateSource("final s = 'Process.run(File())';"),
        returnsNormally,
      );
    });

    test('ignores an import keyword inside a string literal', () {
      expect(
        () => validator.validateSource("final s = 'please import nothing';"),
        returnsNormally,
      );
    });

    test('ignores a banned word inside a raw string', () {
      expect(
        () => validator.validateSource(r"final s = r'File and Process';"),
        returnsNormally,
      );
    });

    test('flags a banned word inside a string interpolation', () {
      _expectViolation(
        () => validator.validateSource(r"final s = '${File('x').path}';"),
        kind: SandboxViolationKind.disallowedIdentifier,
        offender: 'File',
      );
    });

    test('reports a 1-based line number', () {
      try {
        validator.validateSource('var a = 1;\nvar b = 2;\nProcess.run();');
        fail('expected a ProcedureSandboxViolation');
      } on ProcedureSandboxViolation catch (e) {
        expect(e.line, 3);
      }
    });
  });

  group('SandboxValidator.validate / validateAll', () {
    test('validate attributes the failure to the procedure id', () {
      try {
        validator.validate(_loaded("import 'dart:io';", id: 'bad_proc'));
        fail('expected a ProcedureSandboxViolation');
      } on ProcedureSandboxViolation catch (e) {
        expect(e.procedureId, 'bad_proc');
        expect(e.offender, 'import');
      }
    });

    test('validateAll passes a clean set', () {
      final set = [
        _loaded(_legitSource, id: 'a'),
        _loaded('var x = 1;', id: 'b'),
      ];
      expect(() => validator.validateAll(set), returnsNormally);
    });

    test('validateAll fails when one procedure is malicious', () {
      final set = [
        _loaded(_legitSource, id: 'a'),
        _loaded('Process.run();', id: 'evil'),
      ];
      _expectViolation(
        () => validator.validateAll(set),
        offender: 'Process',
      );
    });
  });

  group('SandboxValidator — configurable deny sets', () {
    test('a custom identifier set rejects only its own members', () {
      const custom = SandboxValidator(
        disallowedIdentifiers: {'Forbidden'},
        disallowedDirectives: {},
        allowedImportUris: {'x'},
      );
      _expectViolation(
        () => custom.validateSource('Forbidden();'),
        offender: 'Forbidden',
      );
      // The default-banned `Process` is allowed under the custom set.
      expect(() => custom.validateSource('Process.run();'), returnsNormally);
      // An import on the custom allow-list passes; one off it still fails.
      expect(() => custom.validateSource("import 'x';"), returnsNormally);
      _expectViolation(
        () => custom.validateSource("import 'y';"),
        offender: 'import',
      );
    });

    test('a custom allow-list co-exists with a restored blanket import ban',
        () {
      // Putting `import` back into the directive deny set restores the old
      // blanket ban: every import is rejected regardless of the allow-list.
      const blanket = SandboxValidator(
        disallowedDirectives: {'import', 'export'},
        allowedImportUris: {'x'},
      );
      _expectViolation(
        () => blanket.validateSource("import 'x';"),
        kind: SandboxViolationKind.forbiddenDirective,
        offender: 'import',
      );
    });
  });
}
