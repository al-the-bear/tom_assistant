// Todo 7 (G-PR2) — the deterministic, LLM-free `validate(source)` dry-run
// (`procedure_specification.md` § 7.205, § 8.3).
//
// `ProcedureValidationChain` is what the new engine-native `validate`
// primitive calls: it runs the three-layer validator chain (header → sandbox →
// contract) over a candidate procedure source *without executing it*, and
// returns a `ProcedureValidation` — an `ok` flag plus ordered findings. Unlike
// the individual validators (which throw on the first fault, fail-fast), the
// chain catches each layer's typed exception and continues, so the authoring
// loop's re-draft step gets every fault it can fix in one pass.
//
// These tests pin: a clean source validates; each layer's fault surfaces under
// its wire code; faults are collected across layers (not just the first); and
// the `toMap()` projection the d4rt boundary hands back is well-shaped.

import 'package:tom_brain_procedure/src/validator/validator.dart';
import 'package:test/test.dart';

/// A minimal procedure source that passes all three validator layers.
const String _validSource = '''
/// @procedure
/// id: sample_v1
/// version: 1
/// summary: A sample procedure used by the validation tests.
/// successCriterion: returns a succeeded ProcedureResult.
/// budget: { wallClockMs: 1000 }
/// requires: [ note ]
import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure/src/api/procedure_result.dart';
import 'package:tom_brain_procedure/src/primitives_native/primitives_native.dart';

Future<ProcedureResult> run(ProcedureInputs inputs) async {
  note('progress', {});
  return ProcedureResult.succeeded();
}
''';

void main() {
  group('ProcedureValidationChain.validate', () {
    const chain = ProcedureValidationChain.shared;

    test('a clean source validates with no findings', () {
      final validation = chain.validate(_validSource);
      expect(validation.ok, isTrue);
      expect(validation.findings, isEmpty);
    });

    test('a source with no @procedure header reports header.invalid', () {
      const noHeader = '''
Future<ProcedureResult> run(ProcedureInputs inputs) async {
  note('progress', {});
  return ProcedureResult.succeeded();
}
''';
      final validation = chain.validate(noHeader);
      expect(validation.ok, isFalse);
      expect(
        validation.findings.map((f) => f.code),
        contains('procedure.header.invalid'),
      );
    });

    test('a source that reaches outside the bridged surface reports '
        'sandbox.violation', () {
      // Imports dart:io and references Process — two SDK gateways.
      final sandboxViolating = _validSource.replaceFirst(
        "import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';",
        "import 'dart:io';\n"
            "import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';",
      );
      final validation = chain.validate(sandboxViolating);
      expect(validation.ok, isFalse);
      expect(
        validation.findings.map((f) => f.code),
        contains('procedure.sandbox.violation'),
      );
    });

    test('a wrong entry-point signature reports contract.invalid', () {
      final wrongSignature = _validSource.replaceFirst(
        'Future<ProcedureResult> run(ProcedureInputs inputs) async {',
        'Future<ProcedureResult> run(String wrong) async {',
      );
      final validation = chain.validate(wrongSignature);
      expect(validation.ok, isFalse);
      expect(
        validation.findings.map((f) => f.code),
        contains('procedure.contract.invalid'),
      );
    });

    test('a requires set that does not match the body reports '
        'requires.mismatch', () {
      // Declares `recall` in requires but the body never calls it.
      final requiresMismatch = _validSource.replaceFirst(
        '/// requires: [ note ]',
        '/// requires: [ note, recall ]',
      );
      final validation = chain.validate(requiresMismatch);
      expect(validation.ok, isFalse);
      expect(
        validation.findings.map((f) => f.code),
        contains('procedure.requires.mismatch'),
      );
    });

    test('collects faults across layers rather than stopping at the first',
        () {
      // Sandbox fault (dart:io) AND a contract fault (wrong parameter type)
      // in one source — both must surface.
      var broken = _validSource.replaceFirst(
        "import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';",
        "import 'dart:io';\n"
            "import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';",
      );
      broken = broken.replaceFirst(
        'Future<ProcedureResult> run(ProcedureInputs inputs) async {',
        'Future<ProcedureResult> run(String wrong) async {',
      );
      final validation = chain.validate(broken);
      expect(validation.ok, isFalse);
      final codes = validation.findings.map((f) => f.code).toSet();
      expect(codes, contains('procedure.sandbox.violation'));
      expect(codes, contains('procedure.contract.invalid'));
    });

    test('toMap projects ok + ordered findings for the d4rt boundary', () {
      final validation = chain.validate('not a procedure at all');
      final map = validation.toMap();
      expect(map['ok'], isFalse);
      final findings = map['findings'];
      expect(findings, isA<List<Object?>>());
      final first = (findings as List).first as Map<String, Object?>;
      expect(first['code'], isA<String>());
      expect(first['message'], isA<String>());
    });

    test('a clean source toMap is ok with an empty findings list', () {
      final map = chain.validate(_validSource).toMap();
      expect(map['ok'], isTrue);
      expect(map['findings'], isEmpty);
    });
  });
}
