// C.24 — ProcedureLoader unit tests.
//
// Covers the header loader and its value types:
//
//   - extraction of the `/// @procedure` doc-comment block from full d4rt
//     source (header followed by a body), including leading-space-indented
//     doc comments and a body that is not parsed;
//   - parsing of every header field (id, version, summary,
//     successCriterion, inputs, outputs, budget, requires) into the typed
//     `ProcedureHeader`;
//   - the five required-field rejections (`procedure.header.invalid`) plus
//     structural rejections (no marker, empty block, non-mapping YAML,
//     unparseable YAML);
//   - value semantics of `ProcedureHeader` / `ProcedureBudget` /
//     `ProcedureInputDecl` / `ProcedureOutputDecl`;
//   - `load(ProcedureSource)` bundling the ref + verbatim source.
//
// The canonical valid header mirrors the spec § 4.4 example for
// `answer_with_memory_v1`.

import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:test/test.dart';

/// The spec § 4.4 example header followed by a trivial body. The body is
/// intentionally present to prove the loader stops at the end of the
/// doc-comment block and never parses code.
const String _validSource = '''
/// @procedure
/// id: answer_with_memory_v1
/// version: 1
/// summary: Recall relevant memory, answer the user, persist the exchange.
/// successCriterion: A streamed answer is delivered and an Event + Conclusion + edges are persisted.
/// inputs:
///   - { name: text, type: String, required: true }
/// outputs:
///   - { name: answer, type: String }
/// budget: { wallClockMs: 60000, tokenSpend: 8000, toolCalls: 12, memoryWrites: 6 }
/// requires: [ recall, llm, persist, edge, note, stack.push ]
Future<ProcedureResult> run(ProcedureInputs inputs) async {
  return ProcedureResult.ok();
}
''';

void main() {
  const loader = ProcedureLoader.shared;

  group('C.24 ProcedureLoader.parse — full valid header', () {
    late final ProcedureHeader header;

    setUpAll(() => header = loader.parse(_validSource));

    test('parses id / version / summary / successCriterion', () {
      expect(header.id, 'answer_with_memory_v1');
      expect(header.version, 1);
      expect(
        header.summary,
        'Recall relevant memory, answer the user, persist the exchange.',
      );
      expect(
        header.successCriterion,
        'A streamed answer is delivered and an Event + Conclusion + edges '
        'are persisted.',
      );
    });

    test('parses the inputs list with required flag', () {
      expect(header.inputs, hasLength(1));
      expect(
        header.inputs.single,
        const ProcedureInputDecl(name: 'text', type: 'String', required: true),
      );
    });

    test('parses the outputs list', () {
      expect(header.outputs, hasLength(1));
      expect(
        header.outputs.single,
        const ProcedureOutputDecl(name: 'answer', type: 'String'),
      );
    });

    test('parses the budget caps', () {
      expect(header.budget.wallClockMs, 60000);
      expect(header.budget.tokenSpend, 8000);
      expect(header.budget.toolCalls, 12);
      expect(header.budget.memoryWrites, 6);
    });

    test('parses the requires primitive list', () {
      expect(
        header.requires,
        ['recall', 'llm', 'persist', 'edge', 'note', 'stack.push'],
      );
    });
  });

  group('C.24 ProcedureLoader.parse — extraction', () {
    test('stops at the end of the doc-comment block (body not parsed)', () {
      const malformedBody = '''
/// @procedure
/// id: a_v1
/// version: 1
/// summary: A.
/// successCriterion: Done.
/// budget: { wallClockMs: 1000 }
this is { not ] valid dart at all;
''';
      // Body is garbage; the loader must succeed because it never looks at
      // anything past the doc-comment block.
      final header = loader.parse(malformedBody);
      expect(header.id, 'a_v1');
    });

    test('tolerates indented doc-comment lines', () {
      const indented = '''
class Foo {
  /// @procedure
  /// id: indented_v1
  /// version: 2
  /// summary: Indented.
  /// successCriterion: Ok.
  /// budget: { toolCalls: 3 }
  Future run() async {}
}
''';
      final header = loader.parse(indented);
      expect(header.id, 'indented_v1');
      expect(header.version, 2);
      expect(header.budget.toolCalls, 3);
    });

    test('inputs / outputs / requires default to empty when omitted', () {
      const minimal = '''
/// @procedure
/// id: minimal_v1
/// version: 1
/// summary: Minimal.
/// successCriterion: Ok.
/// budget: { wallClockMs: 500 }
''';
      final header = loader.parse(minimal);
      expect(header.inputs, isEmpty);
      expect(header.outputs, isEmpty);
      expect(header.requires, isEmpty);
    });
  });

  group('C.24 ProcedureLoader.parse — required-field rejection', () {
    // Each case drops exactly one required field from an otherwise-valid
    // header.
    const cases = <String, String>{
      'id': '''
/// @procedure
/// version: 1
/// summary: S.
/// successCriterion: C.
/// budget: { wallClockMs: 1 }
''',
      'version': '''
/// @procedure
/// id: x_v1
/// summary: S.
/// successCriterion: C.
/// budget: { wallClockMs: 1 }
''',
      'summary': '''
/// @procedure
/// id: x_v1
/// version: 1
/// successCriterion: C.
/// budget: { wallClockMs: 1 }
''',
      'successCriterion': '''
/// @procedure
/// id: x_v1
/// version: 1
/// summary: S.
/// budget: { wallClockMs: 1 }
''',
      'budget': '''
/// @procedure
/// id: x_v1
/// version: 1
/// summary: S.
/// successCriterion: C.
''',
    };

    cases.forEach((field, source) {
      test('rejects header missing "$field"', () {
        expect(
          () => loader.parse(source),
          throwsA(
            isA<ProcedureHeaderInvalid>()
                .having((e) => e.field, 'field', field)
                .having((e) => e.code, 'code', 'procedure.header.invalid'),
          ),
        );
      });
    });
  });

  group('C.24 ProcedureLoader.parse — structural rejection', () {
    test('rejects source with no @procedure marker', () {
      expect(
        () => loader.parse('Future run() async {}'),
        throwsA(isA<ProcedureHeaderInvalid>()
            .having((e) => e.field, 'field', isNull)),
      );
    });

    test('rejects an empty header block', () {
      expect(
        () => loader.parse('/// @procedure\nFuture run() async {}'),
        throwsA(isA<ProcedureHeaderInvalid>()),
      );
    });

    test('rejects a non-mapping header body', () {
      const scalar = '''
/// @procedure
/// just a bare string
''';
      expect(
        () => loader.parse(scalar),
        throwsA(isA<ProcedureHeaderInvalid>()),
      );
    });

    test('rejects a non-integer version', () {
      const badVersion = '''
/// @procedure
/// id: x_v1
/// version: one
/// summary: S.
/// successCriterion: C.
/// budget: { wallClockMs: 1 }
''';
      expect(
        () => loader.parse(badVersion),
        throwsA(isA<ProcedureHeaderInvalid>()
            .having((e) => e.field, 'field', 'version')),
      );
    });

    test('rejects an empty budget block', () {
      const emptyBudget = '''
/// @procedure
/// id: x_v1
/// version: 1
/// summary: S.
/// successCriterion: C.
/// budget: {}
''';
      expect(
        () => loader.parse(emptyBudget),
        throwsA(isA<ProcedureHeaderInvalid>()
            .having((e) => e.field, 'field', 'budget')),
      );
    });

    test('rejects a non-integer budget cap', () {
      const badCap = '''
/// @procedure
/// id: x_v1
/// version: 1
/// summary: S.
/// successCriterion: C.
/// budget: { wallClockMs: lots }
''';
      expect(
        () => loader.parse(badCap),
        throwsA(isA<ProcedureHeaderInvalid>()
            .having((e) => e.field, 'field', 'budget')),
      );
    });

    test('rejects a malformed input entry (missing type)', () {
      const badInput = '''
/// @procedure
/// id: x_v1
/// version: 1
/// summary: S.
/// successCriterion: C.
/// budget: { wallClockMs: 1 }
/// inputs:
///   - { name: text }
''';
      expect(
        () => loader.parse(badInput),
        throwsA(isA<ProcedureHeaderInvalid>()
            .having((e) => e.field, 'field', 'inputs')),
      );
    });

    test('names a missing entry key distinctly from a wrong-typed one (E.3.6)',
        () {
      const missingName = '''
/// @procedure
/// id: x_v1
/// version: 1
/// summary: S.
/// successCriterion: C.
/// budget: { wallClockMs: 1 }
/// inputs:
///   - { type: String }
''';
      expect(
        () => loader.parse(missingName),
        throwsA(isA<ProcedureHeaderInvalid>()
            .having((e) => e.field, 'field', 'inputs')
            .having((e) => e.reason, 'reason',
                allOf(contains('name'), contains('required')))),
      );
    });
  });

  group('E.4.3 ProcedureLoader.parseHeaderYaml — contract checks in isolation',
      () {
    // The validation half of `parse`, exercised straight from a bare YAML
    // body — no `/// @procedure` doc-comment wrapper required.
    test('builds a header from a minimal YAML body', () {
      final header = loader.parseHeaderYaml(
        'id: bare_v1\n'
        'version: 3\n'
        'summary: Bare.\n'
        'successCriterion: Ok.\n'
        'budget: { wallClockMs: 500 }\n',
      );
      expect(header.id, 'bare_v1');
      expect(header.version, 3);
      expect(header.budget.wallClockMs, 500);
    });

    test('rejects a missing required field without a doc-comment block', () {
      expect(
        () => loader.parseHeaderYaml(
          'id: bare_v1\n'
          'summary: Bare.\n'
          'successCriterion: Ok.\n'
          'budget: { wallClockMs: 500 }\n',
        ),
        throwsA(isA<ProcedureHeaderInvalid>()
            .having((e) => e.field, 'field', 'version')
            .having((e) => e.code, 'code', 'procedure.header.invalid')),
      );
    });

    test('rejects an empty YAML body', () {
      expect(
        () => loader.parseHeaderYaml('   '),
        throwsA(isA<ProcedureHeaderInvalid>()),
      );
    });

    test('parse composes extraction with parseHeaderYaml', () {
      // The same field body, reached the two ways, yields equal headers.
      final viaParse = loader.parse(_validSource);
      final viaYaml = loader.parseHeaderYaml(
        'id: answer_with_memory_v1\n'
        'version: 1\n'
        'summary: ${viaParse.summary}\n'
        'successCriterion: ${viaParse.successCriterion}\n'
        'inputs:\n'
        '  - { name: text, type: String, required: true }\n'
        'outputs:\n'
        '  - { name: answer, type: String }\n'
        'budget: { wallClockMs: 60000, tokenSpend: 8000, toolCalls: 12, memoryWrites: 6 }\n'
        'requires: [ recall, llm, persist, edge, note, stack.push ]\n',
      );
      expect(viaYaml, equals(viaParse));
    });
  });

  group('C.24 ProcedureLoader.load — bundles ref + source', () {
    test('load attaches the ref and keeps verbatim source', () {
      const ref = ProcedureRef.system('/scripts/system/answer.dart');
      final loaded =
          loader.load(ProcedureSource(ref: ref, source: _validSource));
      expect(loaded.ref, ref);
      expect(loaded.source, _validSource);
      expect(loaded.header.id, 'answer_with_memory_v1');
    });
  });

  group('C.24 value types', () {
    test('ProcedureBudget value equality on caps', () {
      final a = ProcedureBudget({'wallClockMs': 1, 'toolCalls': 2});
      final b = ProcedureBudget({'toolCalls': 2, 'wallClockMs': 1});
      final c = ProcedureBudget({'wallClockMs': 1});
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });

    test('ProcedureHeader value equality', () {
      final h1 = loader.parse(_validSource);
      final h2 = loader.parse(_validSource);
      expect(h1, equals(h2));
      expect(h1.hashCode, equals(h2.hashCode));
    });

    test('ProcedureInputDecl required defaults to false', () {
      const decl = ProcedureInputDecl(name: 'x', type: 'String');
      expect(decl.required, isFalse);
    });

    test('header collections are unmodifiable', () {
      final header = loader.parse(_validSource);
      expect(() => header.requires.add('hack'), throwsUnsupportedError);
      expect(() => header.inputs.clear(), throwsUnsupportedError);
    });
  });
}
