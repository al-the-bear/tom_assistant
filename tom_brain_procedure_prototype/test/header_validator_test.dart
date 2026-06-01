// C.27 — HeaderValidator unit tests.
//
// Covers the first validator layer (`tom_brain_procedure_prototype_
// specification.md` § 7, row 1 → `procedure.header.invalid`):
//
//   - validateHeader: the happy path, and one malformed case per required
//     field (empty id / summary / successCriterion, non-positive version,
//     empty budget). Success-criterion presence is exercised explicitly.
//   - validateVersionChain: monotonic singleton + multi-version chains in
//     any input order; the empty-chain, non-positive-version, and duplicate
//     branches; gaps are accepted (procedures are never deleted, only
//     demoted).
//   - validateAll: a well-formed loaded set passes; a bad header or a bad
//     chain fails the whole set.
//
// Every failure carries the stable wire code `procedure.header.invalid`;
// the tests assert on `code` (and `field` where it identifies the fault),
// not on the human message, matching the C.24/C.25 style.

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';
import 'package:test/test.dart';

/// Builds a [ProcedureHeader] with all required fields valid by default;
/// named params override a single field to exercise one malformed branch.
ProcedureHeader _header({
  String id = 'answer_with_memory',
  int version = 1,
  String summary = 'recall, answer, persist',
  String successCriterion = 'a streamed answer is delivered',
  ProcedureBudget? budget,
}) =>
    ProcedureHeader(
      id: id,
      version: version,
      summary: summary,
      successCriterion: successCriterion,
      budget: budget ?? ProcedureBudget(const {'wallClockMs': 60000}),
    );

/// Builds a [LoadedProcedure] wrapping [_header] for the [validateAll] tests.
LoadedProcedure _loaded(String id, int version) => LoadedProcedure(
      ref: ProcedureRef.system('/$id.v$version.dart'),
      header: _header(id: id, version: version),
      source: '// body',
    );

/// Asserts [body] throws a [ProcedureHeaderInvalid] carrying the canonical
/// wire code, and (when [field] is given) the expected offending field.
void _expectHeaderInvalid(void Function() body, {String? field}) {
  expect(
    body,
    throwsA(
      isA<ProcedureHeaderInvalid>()
          .having((e) => e.code, 'code', procedureHeaderInvalidCode)
          .having((e) => e.field, 'field', field ?? anything),
    ),
  );
}

void main() {
  const validator = HeaderValidator.shared;

  group('HeaderValidator.validateHeader', () {
    test('accepts a fully valid header', () {
      expect(() => validator.validateHeader(_header()), returnsNormally);
    });

    test('rejects an empty id', () {
      _expectHeaderInvalid(
        () => validator.validateHeader(_header(id: '   ')),
        field: 'id',
      );
    });

    test('rejects a zero version', () {
      _expectHeaderInvalid(
        () => validator.validateHeader(_header(version: 0)),
        field: 'version',
      );
    });

    test('rejects a negative version', () {
      _expectHeaderInvalid(
        () => validator.validateHeader(_header(version: -3)),
        field: 'version',
      );
    });

    test('rejects an empty summary', () {
      _expectHeaderInvalid(
        () => validator.validateHeader(_header(summary: '')),
        field: 'summary',
      );
    });

    test('rejects an empty success criterion (presence check)', () {
      _expectHeaderInvalid(
        () => validator.validateHeader(_header(successCriterion: '   ')),
        field: 'successCriterion',
      );
    });

    test('rejects an empty budget', () {
      _expectHeaderInvalid(
        () => validator.validateHeader(
          _header(budget: ProcedureBudget(const {})),
        ),
        field: 'budget',
      );
    });
  });

  group('HeaderValidator.validateVersionChain', () {
    test('accepts a singleton chain', () {
      expect(
        () => validator.validateVersionChain('foo', const [1]),
        returnsNormally,
      );
    });

    test('accepts a strictly-increasing multi-version chain', () {
      expect(
        () => validator.validateVersionChain('foo', const [1, 2, 3]),
        returnsNormally,
      );
    });

    test('accepts versions handed in descending (resolver) order', () {
      expect(
        () => validator.validateVersionChain('foo', const [3, 2, 1]),
        returnsNormally,
      );
    });

    test('accepts a gap (demoted intermediate version)', () {
      expect(
        () => validator.validateVersionChain('foo', const [1, 3]),
        returnsNormally,
      );
    });

    test('rejects an empty chain', () {
      _expectHeaderInvalid(
        () => validator.validateVersionChain('foo', const <int>[]),
        field: 'version',
      );
    });

    test('rejects a non-positive version in the chain', () {
      _expectHeaderInvalid(
        () => validator.validateVersionChain('foo', const [0, 1]),
        field: 'version',
      );
    });

    test('rejects a duplicate version (two sources, same identity)', () {
      _expectHeaderInvalid(
        () => validator.validateVersionChain('foo', const [1, 2, 2]),
        field: 'version',
      );
    });
  });

  group('HeaderValidator.validateAll', () {
    test('accepts a well-formed multi-id, multi-version set', () {
      expect(
        () => validator.validateAll([
          _loaded('foo', 1),
          _loaded('foo', 2),
          _loaded('bar', 1),
        ]),
        returnsNormally,
      );
    });

    test('rejects the set when one header is malformed', () {
      _expectHeaderInvalid(
        () => validator.validateAll([
          _loaded('foo', 1),
          LoadedProcedure(
            ref: ProcedureRef.system('/bad.dart'),
            header: _header(id: 'bar', successCriterion: ''),
            source: '// body',
          ),
        ]),
        field: 'successCriterion',
      );
    });

    test('rejects the set when one id has a duplicate version', () {
      _expectHeaderInvalid(
        () => validator.validateAll([
          _loaded('foo', 1),
          _loaded('foo', 1),
        ]),
        field: 'version',
      );
    });
  });
}
