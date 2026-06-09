// C.30 — Validator branch-coverage / consolidation acceptance suite.
//
// Plan step C.30 (`prototype_implementation_plan.md` § Phase C, subphase
// "C.7 — Validator"): "Tests: each validator branch covered with
// malformed-input cases."
//
// The per-layer suites (C.27 header, C.28 sandbox, C.29 contract) already
// exercise their own branches in isolation. This step is the *consolidation*
// pass: a single suite that walks every rejection branch of all three
// validator layers with a malformed input and asserts the stable wire code
// (and the `kind` / `field` / `offender` that lets a trail entry route
// without parsing the human message), then proves the combined gate behaves
// the way the engine (C.38) will drive it — header → sandbox → contract,
// in that order, over a loaded set.
//
// What this suite owns over the per-layer suites:
//
//   - One table per layer enumerating *every* documented rejection branch,
//     so adding a branch to a validator without a malformed-input case here
//     fails the coverage assertion at the bottom of each group.
//   - The cross-layer gate: a clean procedure clears all three layers; a
//     procedure malformed in exactly one layer is rejected by that layer and
//     carries that layer's wire code; layer ordering is asserted (a source
//     that is malformed in two layers surfaces the earlier layer's fault
//     when the engine runs them in order).
//
// Assertions are on `code` / `kind` / `field` / `offender`, never the human
// message — matching the C.24–C.29 style.

import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:test/test.dart';

// --------------------------------------------------------------------------
// Builders
// --------------------------------------------------------------------------

/// Builds a [ProcedureHeader] with all required fields valid by default;
/// named params override a single field to exercise one malformed branch.
ProcedureHeader _header({
  String id = 'answer_with_memory',
  int version = 1,
  String summary = 'recall, answer, persist',
  String successCriterion = 'a streamed answer is delivered',
  ProcedureBudget? budget,
  List<String> requires = const <String>[],
}) =>
    ProcedureHeader(
      id: id,
      version: version,
      summary: summary,
      successCriterion: successCriterion,
      budget: budget ?? ProcedureBudget(const {'wallClockMs': 60000}),
      requires: requires,
    );

/// Wraps a [source] + [header] in a [LoadedProcedure] for the gate paths.
LoadedProcedure _loaded({
  required String source,
  String id = 'answer_with_memory',
  int version = 1,
  List<String> requires = const <String>[],
}) =>
    LoadedProcedure(
      ref: ProcedureRef.system('/$id.v$version.dart'),
      header: _header(id: id, version: version, requires: requires),
      source: source,
    );

/// A procedure that clears all three validator layers: well-formed header,
/// no forbidden surface, canonical entry point, and a `requires` set that is
/// exactly the bridged primitives the body calls.
const String _cleanSource = '''
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

/// The canonical entry point + body, used when only the header is varied.
const String _cleanBody = '''
Future<ProcedureResult> run(ProcedureInputs inputs) async {
  final hits = await recall(inputs.text, k: 8);
  return ProcedureResult.ok(hits.summary);
}
''';

void main() {
  // ------------------------------------------------------------------------
  // Layer 1 — HeaderValidator: procedure.header.invalid
  // ------------------------------------------------------------------------
  group('C.30 layer 1 — header validator branches', () {
    const validator = HeaderValidator.shared;

    void expectHeaderInvalid(void Function() body, {required String field}) {
      expect(
        body,
        throwsA(isA<ProcedureHeaderInvalid>()
            .having((e) => e.code, 'code', procedureHeaderInvalidCode)
            .having((e) => e.field, 'field', field)),
      );
    }

    // Every documented validateHeader rejection branch, malformed singly.
    final headerBranches = <String, ({ProcedureHeader header, String field})>{
      'empty id': (header: _header(id: '   '), field: 'id'),
      'zero version': (header: _header(version: 0), field: 'version'),
      'negative version': (header: _header(version: -3), field: 'version'),
      'empty summary': (header: _header(summary: ''), field: 'summary'),
      'empty successCriterion': (
        header: _header(successCriterion: '  '),
        field: 'successCriterion',
      ),
      'empty budget': (
        header: _header(budget: ProcedureBudget(const {})),
        field: 'budget',
      ),
    };

    for (final entry in headerBranches.entries) {
      test('validateHeader rejects ${entry.key}', () {
        expectHeaderInvalid(
          () => validator.validateHeader(entry.value.header),
          field: entry.value.field,
        );
      });
    }

    // Every documented validateVersionChain rejection branch.
    test('validateVersionChain rejects an empty chain', () {
      expectHeaderInvalid(
        () => validator.validateVersionChain('p', const <int>[]),
        field: 'version',
      );
    });

    test('validateVersionChain rejects a non-positive version', () {
      expectHeaderInvalid(
        () => validator.validateVersionChain('p', const [0, 1, 2]),
        field: 'version',
      );
    });

    test('validateVersionChain rejects a duplicate version', () {
      expectHeaderInvalid(
        () => validator.validateVersionChain('p', const [1, 2, 2]),
        field: 'version',
      );
    });

    test('validateHeader accepts a fully-valid header', () {
      expect(() => validator.validateHeader(_header()), returnsNormally);
    });

    test('validateVersionChain accepts a gapped chain (demotion is legal)',
        () {
      expect(
        () => validator.validateVersionChain('p', const [1, 3]),
        returnsNormally,
      );
    });

    test('every validateHeader required field has a malformed-input case', () {
      // Guards against adding a required-field check without a C.30 branch.
      expect(
        headerBranches.values.map((b) => b.field).toSet(),
        containsAll(<String>{
          'id',
          'version',
          'summary',
          'successCriterion',
          'budget',
        }),
      );
    });
  });

  // ------------------------------------------------------------------------
  // Layer 2 — SandboxValidator: procedure.sandbox.violation
  // ------------------------------------------------------------------------
  group('C.30 layer 2 — sandbox validator branches', () {
    const validator = SandboxValidator.shared;

    void expectSandboxViolation(
      String source, {
      required SandboxViolationKind kind,
      required String offender,
    }) {
      expect(
        () => validator.validateSource(source),
        throwsA(isA<ProcedureSandboxViolation>()
            .having((e) => e.code, 'code', procedureSandboxViolationCode)
            .having((e) => e.kind, 'kind', kind)
            .having((e) => e.offender, 'offender', offender)),
      );
    }

    // forbiddenDirective branch — every keyword in the default deny set
    // (only `export` after E.3.5; `import` moved to the allow-list branch).
    for (final directive in SandboxValidator.defaultDisallowedDirectives) {
      test('rejects the `$directive` directive', () {
        expectSandboxViolation(
          "$directive 'dart:io';\n$_cleanBody",
          kind: SandboxViolationKind.forbiddenDirective,
          offender: directive,
        );
      });
    }

    // import allow-list branch (E.3.5) — an `import` of a URI off the
    // host-injected allow-list is a forbiddenDirective violation, but the
    // keyword itself is `import` (allow-listed by URI, not blanket-banned).
    test('rejects an off-allow-list import', () {
      expectSandboxViolation(
        "import 'dart:io';\n$_cleanBody",
        kind: SandboxViolationKind.forbiddenDirective,
        offender: 'import',
      );
    });

    // disallowedIdentifier branch — a representative from each SDK family.
    const identifierProbes = <String>[
      'File', // dart:io file system
      'Process', // dart:io processes
      'Platform', // dart:io platform
      'Socket', // dart:io sockets
      'HttpClient', // dart:io network client
      'Isolate', // dart:isolate
      'stdout', // standard streams
      'exit', // process control
      'eval', // eval-style indirection
    ];

    for (final ident in identifierProbes) {
      test('rejects a reference to `$ident`', () {
        expectSandboxViolation(
          'Future<ProcedureResult> run(ProcedureInputs inputs) async {\n'
          '  final x = $ident;\n'
          '  return ProcedureResult.ok(x.toString());\n'
          '}\n',
          kind: SandboxViolationKind.disallowedIdentifier,
          offender: ident,
        );
      });
    }

    test('every default deny set has a malformed-input case', () {
      // Directives: all covered above. Identifiers: probes are a subset; the
      // guard asserts every probe is genuinely in the deny set (so a typo in
      // a probe name surfaces here rather than as a silent false pass).
      expect(
        SandboxValidator.defaultDisallowedIdentifiers,
        containsAll(identifierProbes),
      );
      expect(
        SandboxValidator.defaultDisallowedDirectives,
        unorderedEquals(<String>{'export'}),
      );
    });

    test('accepts a clean source touching only bridged primitives', () {
      expect(
        () => validator.validateSource(_cleanSource),
        returnsNormally,
      );
    });

    test('a banned word in a comment or string literal does not trip', () {
      const benign = '''
/// This procedure does not import anything and never calls Process.
Future<ProcedureResult> run(ProcedureInputs inputs) async {
  final note = 'the word File appears only in this string';
  return ProcedureResult.ok(note);
}
''';
      expect(() => validator.validateSource(benign), returnsNormally);
    });
  });

  // ------------------------------------------------------------------------
  // Layer 3a — ContractValidator signature: procedure.contract.invalid
  // ------------------------------------------------------------------------
  group('C.30 layer 3a — contract signature branches', () {
    const validator = ContractValidator.shared;

    void expectContractInvalid(
      String source, {
      required ContractViolationKind kind,
    }) {
      expect(
        () => validator.validateSignature(source),
        throwsA(isA<ProcedureContractInvalid>()
            .having((e) => e.code, 'code', procedureContractInvalidCode)
            .having((e) => e.kind, 'kind', kind)),
      );
    }

    final signatureBranches =
        <String, ({String source, ContractViolationKind kind})>{
      'missing entry point': (
        source: 'final x = 1;\n',
        kind: ContractViolationKind.missingEntryPoint,
      ),
      'wrong return type': (
        source: 'ProcedureResult run(ProcedureInputs inputs) async {\n'
            '  return ProcedureResult.ok("x");\n'
            '}\n',
        kind: ContractViolationKind.wrongReturnType,
      ),
      'wrong parameter type': (
        source: 'Future<ProcedureResult> run(String inputs) async {\n'
            '  return ProcedureResult.ok(inputs);\n'
            '}\n',
        kind: ContractViolationKind.wrongParameterType,
      ),
      'no parameter': (
        source: 'Future<ProcedureResult> run() async {\n'
            '  return ProcedureResult.ok("x");\n'
            '}\n',
        kind: ContractViolationKind.wrongParameterType,
      ),
      'multiple parameters': (
        source:
            'Future<ProcedureResult> run(ProcedureInputs a, int b) async {\n'
                '  return ProcedureResult.ok("x");\n'
                '}\n',
        kind: ContractViolationKind.wrongParameterType,
      ),
      'not async': (
        source: 'Future<ProcedureResult> run(ProcedureInputs inputs) {\n'
            '  return ProcedureResult.ok("x");\n'
            '}\n',
        kind: ContractViolationKind.notAsync,
      ),
    };

    for (final entry in signatureBranches.entries) {
      test('validateSignature rejects ${entry.key}', () {
        expectContractInvalid(entry.value.source, kind: entry.value.kind);
      });
    }

    test('every ContractViolationKind has a malformed-input case', () {
      expect(
        signatureBranches.values.map((b) => b.kind).toSet(),
        unorderedEquals(ContractViolationKind.values),
      );
    });

    test('validateSignature accepts the canonical entry point', () {
      expect(
        () => validator.validateSignature(_cleanSource),
        returnsNormally,
      );
    });
  });

  // ------------------------------------------------------------------------
  // Layer 3b — ContractValidator requires: procedure.requires.mismatch
  // ------------------------------------------------------------------------
  group('C.30 layer 3b — contract requires branches', () {
    const validator = ContractValidator.shared;

    void expectRequiresMismatch(
      ProcedureHeader header,
      String source, {
      required RequiresMismatchKind kind,
      required String offender,
    }) {
      expect(
        () => validator.validateRequires(header, source),
        throwsA(isA<ProcedureRequiresMismatch>()
            .having((e) => e.code, 'code', procedureRequiresMismatchCode)
            .having((e) => e.kind, 'kind', kind)
            .having((e) => e.offender, 'offender', offender)),
      );
    }

    // Body that calls exactly recall + persist.
    const callsRecallPersist = '''
Future<ProcedureResult> run(ProcedureInputs inputs) async {
  final hits = await recall(inputs.text, k: 8);
  await persist(hits.summary);
  return ProcedureResult.ok(hits.summary);
}
''';

    test('rejects an unknown primitive in requires', () {
      expectRequiresMismatch(
        _header(requires: const ['recall', 'teleport']),
        callsRecallPersist,
        kind: RequiresMismatchKind.unknownPrimitive,
        offender: 'teleport',
      );
    });

    test('rejects an undeclared call', () {
      // Body calls recall + persist; requires omits persist.
      expectRequiresMismatch(
        _header(requires: const ['recall']),
        callsRecallPersist,
        kind: RequiresMismatchKind.undeclaredCall,
        offender: 'persist',
      );
    });

    test('rejects an unused requires declaration', () {
      // Body calls recall + persist; requires adds an uncalled primitive.
      expectRequiresMismatch(
        _header(requires: const ['recall', 'persist', 'edge']),
        callsRecallPersist,
        kind: RequiresMismatchKind.unusedRequire,
        offender: 'edge',
      );
    });

    test('every RequiresMismatchKind has a malformed-input case', () {
      // The three tests above each cover one kind; this guards the set.
      expect(
        <RequiresMismatchKind>{
          RequiresMismatchKind.unknownPrimitive,
          RequiresMismatchKind.undeclaredCall,
          RequiresMismatchKind.unusedRequire,
        },
        unorderedEquals(RequiresMismatchKind.values),
      );
    });

    test('accepts a requires set that exactly matches the calls', () {
      expect(
        () => validator.validateRequires(
          _header(requires: const ['recall', 'persist']),
          callsRecallPersist,
        ),
        returnsNormally,
      );
    });
  });

  // ------------------------------------------------------------------------
  // Cross-layer gate — the order the engine (C.38) drives the three layers.
  // ------------------------------------------------------------------------
  group('C.30 cross-layer gate', () {
    const header = HeaderValidator.shared;
    const sandbox = SandboxValidator.shared;
    const contract = ContractValidator.shared;

    /// Runs the three layers in the engine's order over one loaded set and
    /// rethrows the first layer's failure.
    void gate(Iterable<LoadedProcedure> set) {
      header.validateAll(set);
      sandbox.validateAll(set);
      contract.validateAll(set);
    }

    test('a clean procedure clears all three layers', () {
      final set = [
        _loaded(source: _cleanSource, requires: const ['recall', 'llm', 'persist']),
      ];
      expect(() => gate(set), returnsNormally);
    });

    test('a header-malformed procedure is rejected by layer 1', () {
      // Empty success criterion — only the header layer can see it.
      final set = [
        LoadedProcedure(
          ref: ProcedureRef.system('/bad.v1.dart'),
          header: _header(successCriterion: ''),
          source: _cleanSource,
        ),
      ];
      expect(
        () => gate(set),
        throwsA(isA<ProcedureHeaderInvalid>()
            .having((e) => e.code, 'code', procedureHeaderInvalidCode)),
      );
    });

    test('a sandbox-malformed procedure is rejected by layer 2', () {
      final set = [
        _loaded(
          source: "import 'dart:io';\n$_cleanSource",
          requires: const ['recall', 'llm', 'persist'],
        ),
      ];
      expect(
        () => gate(set),
        throwsA(isA<ProcedureSandboxViolation>()
            .having((e) => e.code, 'code', procedureSandboxViolationCode)),
      );
    });

    test('a contract-malformed procedure is rejected by layer 3', () {
      const noEntryPoint = '''
/// @procedure
final notARun = 1;
''';
      final set = [_loaded(source: noEntryPoint)];
      expect(
        () => gate(set),
        throwsA(isA<ProcedureContractInvalid>()
            .having((e) => e.code, 'code', procedureContractInvalidCode)
            .having((e) => e.kind, 'kind',
                ContractViolationKind.missingEntryPoint)),
      );
    });

    test('layer ordering: a header+sandbox fault surfaces the header first',
        () {
      // Malformed in both layer 1 (empty summary) and layer 2 (import). The
      // engine runs header before sandbox, so the header fault wins.
      final set = [
        LoadedProcedure(
          ref: ProcedureRef.system('/bad.v1.dart'),
          header: _header(summary: ''),
          source: "import 'dart:io';\n$_cleanSource",
        ),
      ];
      expect(
        () => gate(set),
        throwsA(isA<ProcedureHeaderInvalid>()),
      );
    });

    test('layer ordering: a sandbox+contract fault surfaces the sandbox first',
        () {
      // Header is fine; source both imports (layer 2) and has no entry point
      // (layer 3). Sandbox runs before contract, so the sandbox fault wins.
      final set = [
        _loaded(source: "import 'dart:io';\nfinal notARun = 1;\n"),
      ];
      expect(
        () => gate(set),
        throwsA(isA<ProcedureSandboxViolation>()),
      );
    });
  });
}
