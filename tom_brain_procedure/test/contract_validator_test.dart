// C.29 — ContractValidator unit tests.
//
// Covers the third validator layer (`tom_brain_procedure_
// specification.md` § 7, rows 4–5):
//
//   - validateSignature: accepts the canonical
//     `Future<ProcedureResult> run(ProcedureInputs inputs) async { … }`
//     entry point; rejects a missing entry point, a wrong return type, a
//     wrong/absent/multiple parameter, and a non-async function. Each
//     rejection carries `procedure.contract.invalid` and the right
//     `ContractViolationKind`.
//   - validateRequires: accepts a header whose `requires` set is exactly
//     the bridged primitives the body calls; rejects an undeclared call, an
//     unused declaration, and a `requires` entry that names no primitive.
//     Each carries `procedure.requires.mismatch` and the right
//     `RequiresMismatchKind` + `offender`.
//   - the comment/string projection inherited from C.28: a `run(` token in
//     a comment is ignored; a primitive name in a string literal is not
//     counted as a call; a primitive call inside a string interpolation is.
//   - dotted (`stack.push`) and camelCase (`stackPush`) call spellings both
//     count.
//   - validate / validateAll: attribution to the procedure id; a clean set
//     passes, a malformed set fails.
//
// The tests assert on `code`, `kind`, and `offender`, never the human
// message, matching the C.24/C.25/C.27/C.28 style.

import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:test/test.dart';

/// A representative legit procedure: a header doc-comment plus a `run`
/// entry point whose `requires` set (`recall`, `llm`, `persist`) is exactly
/// the bridged primitives the body calls.
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

/// Builds a header with the given [requires] list (all other fields fixed).
ProcedureHeader _header({
  String id = 'p',
  int version = 1,
  List<String> requires = const <String>[],
}) =>
    ProcedureHeader(
      id: id,
      version: version,
      summary: 'summary',
      successCriterion: 'criterion',
      budget: ProcedureBudget(const {'wallClockMs': 60000}),
      requires: requires,
    );

/// Wraps [source] + [requires] in a [LoadedProcedure] for the
/// `validate` / `validateAll` paths.
LoadedProcedure _loaded(
  String source, {
  String id = 'p',
  int version = 1,
  List<String> requires = const <String>[],
}) =>
    LoadedProcedure(
      ref: ProcedureRef.system('/$id.v$version.dart'),
      header: _header(id: id, version: version, requires: requires),
      source: source,
    );

/// Asserts [body] throws a [ProcedureContractInvalid] with the given [kind].
void _expectContractInvalid(
  void Function() body,
  ContractViolationKind kind,
) {
  expect(
    body,
    throwsA(isA<ProcedureContractInvalid>()
        .having((e) => e.code, 'code', procedureContractInvalidCode)
        .having((e) => e.kind, 'kind', kind)),
  );
}

/// Asserts [body] throws a [ProcedureRequiresMismatch] with [kind] +
/// [offender].
void _expectRequiresMismatch(
  void Function() body,
  RequiresMismatchKind kind,
  String offender,
) {
  expect(
    body,
    throwsA(isA<ProcedureRequiresMismatch>()
        .having((e) => e.code, 'code', procedureRequiresMismatchCode)
        .having((e) => e.kind, 'kind', kind)
        .having((e) => e.offender, 'offender', offender)),
  );
}

void main() {
  const validator = ContractValidator.shared;

  group('validateSignature — happy path', () {
    test('accepts the canonical entry point', () {
      expect(() => validator.validateSignature(_legitSource), returnsNormally);
    });

    test('accepts a multi-line / spaced signature', () {
      const src = '''
Future < ProcedureResult >  run ( ProcedureInputs  inputs )  async {
  return ProcedureResult.ok('x');
}
''';
      expect(() => validator.validateSignature(src), returnsNormally);
    });
  });

  group('validateSignature — rejections', () {
    test('missing entry point', () {
      const src = '''
Future<ProcedureResult> handle(ProcedureInputs inputs) async {
  return ProcedureResult.ok('x');
}
''';
      _expectContractInvalid(
        () => validator.validateSignature(src),
        ContractViolationKind.missingEntryPoint,
      );
    });

    test('wrong return type', () {
      const src = '''
ProcedureResult run(ProcedureInputs inputs) async {
  return ProcedureResult.ok('x');
}
''';
      _expectContractInvalid(
        () => validator.validateSignature(src),
        ContractViolationKind.wrongReturnType,
      );
    });

    test('wrong parameter type', () {
      const src = '''
Future<ProcedureResult> run(String inputs) async {
  return ProcedureResult.ok('x');
}
''';
      _expectContractInvalid(
        () => validator.validateSignature(src),
        ContractViolationKind.wrongParameterType,
      );
    });

    test('no parameter', () {
      const src = '''
Future<ProcedureResult> run() async {
  return ProcedureResult.ok('x');
}
''';
      _expectContractInvalid(
        () => validator.validateSignature(src),
        ContractViolationKind.wrongParameterType,
      );
    });

    test('more than one parameter', () {
      const src = '''
Future<ProcedureResult> run(ProcedureInputs inputs, int extra) async {
  return ProcedureResult.ok('x');
}
''';
      _expectContractInvalid(
        () => validator.validateSignature(src),
        ContractViolationKind.wrongParameterType,
      );
    });

    test('not async', () {
      const src = '''
Future<ProcedureResult> run(ProcedureInputs inputs) {
  return ProcedureResult.ok('x');
}
''';
      _expectContractInvalid(
        () => validator.validateSignature(src),
        ContractViolationKind.notAsync,
      );
    });

    test('a `run(` token in a comment is not the entry point', () {
      const src = '''
// Future<ProcedureResult> run(ProcedureInputs inputs) async { commented out }
Future<ProcedureResult> handle(ProcedureInputs inputs) async {
  return ProcedureResult.ok('x');
}
''';
      _expectContractInvalid(
        () => validator.validateSignature(src),
        ContractViolationKind.missingEntryPoint,
      );
    });
  });

  group('validateRequires — happy path', () {
    test('requires exactly matches the calls', () {
      expect(
        () => validator.validateRequires(
          _header(requires: const ['recall', 'llm', 'persist']),
          _legitSource,
        ),
        returnsNormally,
      );
    });

    test('a procedure with no calls and no requires', () {
      const src = '''
Future<ProcedureResult> run(ProcedureInputs inputs) async {
  return ProcedureResult.ok('static');
}
''';
      expect(
        () => validator.validateRequires(_header(), src),
        returnsNormally,
      );
    });

    test('dotted stack call matches a `stack.push` requirement', () {
      const src = '''
Future<ProcedureResult> run(ProcedureInputs inputs) async {
  await stack.push('inflight', inputs.text);
  return ProcedureResult.ok('x');
}
''';
      expect(
        () => validator.validateRequires(
          _header(requires: const ['stack.push']),
          src,
        ),
        returnsNormally,
      );
    });

    test('camelCase stackPush call also matches `stack.push`', () {
      const src = '''
Future<ProcedureResult> run(ProcedureInputs inputs) async {
  await stackPush('inflight', inputs.text);
  return ProcedureResult.ok('x');
}
''';
      expect(
        () => validator.validateRequires(
          _header(requires: const ['stack.push']),
          src,
        ),
        returnsNormally,
      );
    });
  });

  group('validateRequires — rejections', () {
    test('undeclared call', () {
      // Body calls `persist` but only `recall` + `llm` are declared.
      _expectRequiresMismatch(
        () => validator.validateRequires(
          _header(requires: const ['recall', 'llm']),
          _legitSource,
        ),
        RequiresMismatchKind.undeclaredCall,
        'persist',
      );
    });

    test('unused declaration', () {
      // Declares `edge` but the body never calls it.
      _expectRequiresMismatch(
        () => validator.validateRequires(
          _header(requires: const ['recall', 'llm', 'persist', 'edge']),
          _legitSource,
        ),
        RequiresMismatchKind.unusedRequire,
        'edge',
      );
    });

    test('unknown primitive name', () {
      _expectRequiresMismatch(
        () => validator.validateRequires(
          _header(requires: const ['recall', 'llm', 'persist', 'teleport']),
          _legitSource,
        ),
        RequiresMismatchKind.unknownPrimitive,
        'teleport',
      );
    });

    test('a primitive name in a string literal is not counted as a call', () {
      // The body mentions `persist` only inside a string; it is not called,
      // so declaring it is an unused requirement.
      const src = '''
Future<ProcedureResult> run(ProcedureInputs inputs) async {
  final answer = await llm('do not persist this', role: 'assistant');
  return ProcedureResult.ok(answer);
}
''';
      _expectRequiresMismatch(
        () => validator.validateRequires(
          _header(requires: const ['llm', 'persist']),
          src,
        ),
        RequiresMismatchKind.unusedRequire,
        'persist',
      );
    });

    test('a call inside a string interpolation is counted', () {
      // `recall(...)` appears only inside an interpolation — interpolated
      // code is real code, so it must be declared.
      const src = r'''
Future<ProcedureResult> run(ProcedureInputs inputs) async {
  final answer = await llm('hits: ${await recall(inputs.text)}', role: 'a');
  return ProcedureResult.ok(answer);
}
''';
      _expectRequiresMismatch(
        () => validator.validateRequires(
          _header(requires: const ['llm']),
          src,
        ),
        RequiresMismatchKind.undeclaredCall,
        'recall',
      );
    });

    test('a member access (`obj.recall(`) is not a top-level primitive call',
        () {
      // `inputs.recall(...)` is a member call, not the bridged primitive, so
      // declaring `recall` would be unused (only `llm` is actually called).
      const src = '''
Future<ProcedureResult> run(ProcedureInputs inputs) async {
  final extra = inputs.recall();
  final answer = await llm(extra, role: 'assistant');
  return ProcedureResult.ok(answer);
}
''';
      _expectRequiresMismatch(
        () => validator.validateRequires(
          _header(requires: const ['llm', 'recall']),
          src,
        ),
        RequiresMismatchKind.unusedRequire,
        'recall',
      );
    });
  });

  group('catalog', () {
    test('callTokensFor derives camel forms for dotted/snake names', () {
      expect(BridgedPrimitiveCatalog.callTokensFor('stack.push'),
          {'stack.push', 'stackPush'});
      expect(BridgedPrimitiveCatalog.callTokensFor('propose_node_type'),
          {'propose_node_type', 'proposeNodeType'});
      expect(BridgedPrimitiveCatalog.callTokensFor('recall'), {'recall'});
    });

    test('isKnown covers memory, substrate, native and sugar', () {
      expect(BridgedPrimitiveCatalog.isKnown('recall'), isTrue);
      expect(BridgedPrimitiveCatalog.isKnown('llm'), isTrue);
      expect(BridgedPrimitiveCatalog.isKnown('runProcedure'), isTrue);
      expect(BridgedPrimitiveCatalog.isKnown('think'), isTrue);
      expect(BridgedPrimitiveCatalog.isKnown('teleport'), isFalse);
    });
  });

  group('validate / validateAll', () {
    test('validate attributes a signature failure to the id', () {
      const src = '''
Future<ProcedureResult> handle(ProcedureInputs inputs) async {
  return ProcedureResult.ok('x');
}
''';
      expect(
        () => validator.validate(_loaded(src, id: 'broken')),
        throwsA(isA<ProcedureContractInvalid>()
            .having((e) => e.procedureId, 'procedureId', 'broken')),
      );
    });

    test('validate attributes a requires failure to the id', () {
      expect(
        () => validator.validate(
          _loaded(_legitSource, id: 'leaky', requires: const ['recall', 'llm']),
        ),
        throwsA(isA<ProcedureRequiresMismatch>()
            .having((e) => e.procedureId, 'procedureId', 'leaky')
            .having((e) => e.offender, 'offender', 'persist')),
      );
    });

    test('validateAll passes a clean set', () {
      final set = [
        _loaded(_legitSource,
            id: 'a', requires: const ['recall', 'llm', 'persist']),
        _loaded(_legitSource,
            id: 'b', version: 2, requires: const ['recall', 'llm', 'persist']),
      ];
      expect(() => validator.validateAll(set), returnsNormally);
    });

    test('validateAll fails when one procedure is malformed', () {
      final set = [
        _loaded(_legitSource,
            id: 'good', requires: const ['recall', 'llm', 'persist']),
        _loaded(_legitSource, id: 'bad', requires: const ['recall', 'llm']),
      ];
      expect(
        () => validator.validateAll(set),
        throwsA(isA<ProcedureRequiresMismatch>()
            .having((e) => e.procedureId, 'procedureId', 'bad')),
      );
    });
  });
}
