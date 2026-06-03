// ContractValidator — the third of the three validator layers (Plan step
// C.29; `tom_brain_procedure_prototype_specification.md` § 4.3, § 4.4, § 7
// rows 4–5).
//
// This layer owns the spec's last two validator rows:
//
//   - "Entry point `run(ProcedureInputs)` present with the expected
//     signature" → `procedure.contract.invalid` ([ProcedureContractInvalid]).
//   - "Declared `requires` matches actual bridged-API calls used" →
//     `procedure.requires.mismatch` ([ProcedureRequiresMismatch]).
//
// Like the sandbox validator (C.28), it runs *before* a procedure reaches
// `draft`/runnable and works on a [CodeProjection] of the verbatim source —
// comments and string-literal text blanked, interpolated code kept — so a
// `run(` token in a comment is never mistaken for the entry point and a
// primitive name in a string literal is never counted as a call. It is a
// defence-in-depth *static* gate; the runtime (d4rt host + bridge) is the
// authoritative check that `run` is actually invokable and returns a
// `ProcedureResult` (`procedure.contract.violation`).
//
// The signature check is lexical, not a full AST parse — the same trade-off
// C.28 took (Q-C.28.1, mirrored at Q-C.29.1). The public surface is
// parser-agnostic so the internals can be swapped for an AST visitor if the
// final subsystem needs exact analysis.

import '../procedure_store/procedure_header.dart';
import '../procedure_store/procedure_loader.dart';
import 'bridged_primitive_catalog.dart';
import 'code_projection.dart';
import 'procedure_contract_invalid.dart';
import 'procedure_requires_mismatch.dart';

/// Validates a procedure's entry-point signature and its `requires`-vs-
/// actual-calls contract (§ 7 rows 4–5).
///
/// Stateless — every method is a pure function of its input. Construct once
/// and reuse, or use the [shared] instance. Signature faults throw
/// [ProcedureContractInvalid] (`procedure.contract.invalid`); requires
/// faults throw [ProcedureRequiresMismatch] (`procedure.requires.mismatch`).
final class ContractValidator {
  const ContractValidator();

  /// A shared, reusable validator (holds no state).
  static const ContractValidator shared = ContractValidator();

  /// Matches the `run(` entry-point keyword not preceded by an identifier
  /// char or `.`. Compiled once and reused across every validation (E.2:
  /// previously rebuilt on each `validateSignature` call).
  static final RegExp _runEntryPattern = RegExp(r'(?<![\w$.])run\s*\(');

  /// Matches the required `Future<ProcedureResult>` return type, tolerating
  /// whitespace around the generic brackets. Compiled once (E.2).
  static final RegExp _futureProcedureResultPattern =
      RegExp(r'Future\s*<\s*ProcedureResult\s*>');

  /// Matches the `ProcedureInputs` parameter type as a whole word. Compiled
  /// once (E.2).
  static final RegExp _procedureInputsPattern =
      RegExp(r'(?<![\w$.])ProcedureInputs(?![\w$])');

  /// Matches the `async` modifier as a whole word. Compiled once (E.2).
  static final RegExp _asyncPattern = RegExp(r'(?<![\w$.])async(?![\w$])');

  /// Per-token cache of the call-site patterns [_callPattern] builds. The
  /// token set is the fixed bridged-primitive catalog, so this is bounded;
  /// caching avoids recompiling the same handful of regexes for every
  /// procedure validated (E.2).
  static final Map<String, RegExp> _callPatternCache = <String, RegExp>{};

  /// Validates that [source] declares the required entry point
  /// `Future<ProcedureResult> run(ProcedureInputs inputs) async { … }`.
  ///
  /// Checks, in order: the entry point is present, its return type is
  /// `Future<ProcedureResult>`, its single parameter is typed
  /// `ProcedureInputs`, and it is declared `async`. Throws
  /// [ProcedureContractInvalid] on the first fault, with [ContractViolationKind]
  /// naming the cause. [procedureId] is woven into the failure when known.
  void validateSignature(String source, {String? procedureId}) {
    final projection = CodeProjection.project(source);

    final runMatch = _runEntryPattern.firstMatch(projection);
    if (runMatch == null) {
      throw ProcedureContractInvalid(
        'no top-level `run(ProcedureInputs)` entry point found; a procedure '
        'must declare `Future<ProcedureResult> run(ProcedureInputs inputs) '
        'async { … }` (§ 4.3)',
        kind: ContractViolationKind.missingEntryPoint,
        procedureId: procedureId,
      );
    }

    final line = CodeProjection.lineOf(projection, runMatch.start);
    final openParen = projection.indexOf('(', runMatch.start);
    final closeParen = _matchParen(projection, openParen);
    if (closeParen == -1) {
      throw ProcedureContractInvalid(
        '`run` parameter list is not closed',
        kind: ContractViolationKind.wrongParameterType,
        line: line,
        procedureId: procedureId,
      );
    }

    // Return type — the code between the previous statement boundary and the
    // `run` keyword must contain `Future<ProcedureResult>`.
    final returnWindow = _returnTypeWindow(projection, runMatch.start);
    if (!_futureProcedureResultPattern.hasMatch(returnWindow)) {
      throw ProcedureContractInvalid(
        '`run` must return `Future<ProcedureResult>` (§ 4.3)',
        kind: ContractViolationKind.wrongReturnType,
        line: line,
        procedureId: procedureId,
      );
    }

    // Parameter — exactly one parameter, typed `ProcedureInputs`.
    final params = projection.substring(openParen + 1, closeParen).trim();
    if (params.isEmpty || _topLevelCommaCount(params) > 0) {
      throw ProcedureContractInvalid(
        '`run` must take exactly one parameter of type `ProcedureInputs` '
        '(§ 4.3)',
        kind: ContractViolationKind.wrongParameterType,
        line: line,
        procedureId: procedureId,
      );
    }
    if (!_procedureInputsPattern.hasMatch(params)) {
      throw ProcedureContractInvalid(
        "`run`'s parameter must be typed `ProcedureInputs`, was `$params` "
        '(§ 4.3)',
        kind: ContractViolationKind.wrongParameterType,
        line: line,
        procedureId: procedureId,
      );
    }

    // Async — between the parameter list and the body opener.
    final asyncWindow = _asyncWindow(projection, closeParen + 1);
    if (!_asyncPattern.hasMatch(asyncWindow)) {
      throw ProcedureContractInvalid(
        '`run` must be declared `async` (§ 4.3 — every bridged call is '
        'awaited)',
        kind: ContractViolationKind.notAsync,
        line: line,
        procedureId: procedureId,
      );
    }
  }

  /// Validates that the [header]'s declared `requires` set is exactly the
  /// set of bridged primitives [source]'s body calls.
  ///
  /// Rejects, in order: a `requires` entry that is not a known bridged
  /// primitive ([RequiresMismatchKind.unknownPrimitive]); a primitive the
  /// body calls but the header did not declare
  /// ([RequiresMismatchKind.undeclaredCall]); a `requires` entry the body
  /// never calls ([RequiresMismatchKind.unusedRequire]). Throws
  /// [ProcedureRequiresMismatch] on the first fault.
  void validateRequires(
    ProcedureHeader header,
    String source, {
    String? procedureId,
  }) {
    final id = procedureId ?? header.id;
    final declared = header.requires.toSet();

    // Every declared entry must be a known bridged primitive.
    for (final name in header.requires) {
      if (!BridgedPrimitiveCatalog.isKnown(name)) {
        throw ProcedureRequiresMismatch(
          '`requires` lists "$name", which is not a bridged primitive; the '
          'callable surface is ${_known()}',
          kind: RequiresMismatchKind.unknownPrimitive,
          offender: name,
          procedureId: id,
        );
      }
    }

    final projection = CodeProjection.project(source);
    final called = _calledPrimitives(projection);

    // Every primitive the body calls must be declared.
    for (final name in called.toList(growable: false)..sort()) {
      if (!declared.contains(name)) {
        throw ProcedureRequiresMismatch(
          'body calls bridged primitive "$name" but `requires` does not '
          'declare it',
          kind: RequiresMismatchKind.undeclaredCall,
          offender: name,
          procedureId: id,
        );
      }
    }

    // Every declared primitive must be called.
    for (final name in header.requires) {
      if (!called.contains(name)) {
        throw ProcedureRequiresMismatch(
          '`requires` declares "$name" but the body never calls it',
          kind: RequiresMismatchKind.unusedRequire,
          offender: name,
          procedureId: id,
        );
      }
    }
  }

  /// Validates a loaded [procedure]'s signature and `requires` contract,
  /// attributing any failure to its header id. Signature is checked first.
  void validate(LoadedProcedure procedure) {
    validateSignature(procedure.source, procedureId: procedure.header.id);
    validateRequires(procedure.header, procedure.source,
        procedureId: procedure.header.id);
  }

  /// Validates every procedure in a loaded set. Throws on the first fault.
  void validateAll(Iterable<LoadedProcedure> procedures) {
    for (final procedure in procedures) {
      validate(procedure);
    }
  }

  // --- requires scan -----------------------------------------------------

  /// The set of catalog primitives [projection] calls — a primitive counts
  /// as called when any of its accepted call-site spellings appears
  /// immediately before a `(`.
  Set<String> _calledPrimitives(String projection) {
    final called = <String>{};
    for (final name in BridgedPrimitiveCatalog.all) {
      for (final token in BridgedPrimitiveCatalog.callTokensFor(name)) {
        if (_callPattern(token).hasMatch(projection)) {
          called.add(name);
          break;
        }
      }
    }
    return called;
  }

  /// A regex matching a call to [token]: the token (dotted segments allow
  /// surrounding whitespace) not preceded by an identifier char or `.`,
  /// followed by `(`.
  RegExp _callPattern(String token) =>
      _callPatternCache.putIfAbsent(token, () {
        final segments = token.split('.').map(RegExp.escape).join(r'\s*\.\s*');
        return RegExp('(?<![\\w\$.])$segments\\s*\\(');
      });

  // --- signature helpers -------------------------------------------------

  /// Index of the `)` that closes the `(` at [openIndex], or `-1` if
  /// unbalanced.
  int _matchParen(String s, int openIndex) {
    var depth = 0;
    for (var i = openIndex; i < s.length; i++) {
      final c = s[i];
      if (c == '(') {
        depth++;
      } else if (c == ')') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  /// The code window before the `run` keyword at [runStart], back to the
  /// previous statement/scope boundary (`{`, `}`, `;`) or the source start.
  /// This is where the return type sits.
  String _returnTypeWindow(String projection, int runStart) {
    var from = 0;
    for (var i = runStart - 1; i >= 0; i--) {
      final c = projection[i];
      if (c == '{' || c == '}' || c == ';') {
        from = i + 1;
        break;
      }
    }
    return projection.substring(from, runStart);
  }

  /// The code window after the `run` parameter list (starting at [from]),
  /// up to the body opener (`{` or `=>`). This is where `async` sits.
  String _asyncWindow(String projection, int from) {
    final braceIndex = projection.indexOf('{', from);
    final arrowIndex = projection.indexOf('=>', from);
    var to = projection.length;
    if (braceIndex != -1) to = braceIndex;
    if (arrowIndex != -1 && arrowIndex < to) to = arrowIndex;
    return projection.substring(from, to);
  }

  /// Number of top-level commas in a parameter list [params] (commas inside
  /// `()`, `<>`, `[]`, or `{}` are not counted), used to detect arity.
  int _topLevelCommaCount(String params) {
    var depth = 0;
    var count = 0;
    for (var i = 0; i < params.length; i++) {
      final c = params[i];
      if (c == '(' || c == '<' || c == '[' || c == '{') {
        depth++;
      } else if (c == ')' || c == '>' || c == ']' || c == '}') {
        if (depth > 0) depth--;
      } else if (c == ',' && depth == 0) {
        count++;
      }
    }
    return count;
  }

  String _known() =>
      (BridgedPrimitiveCatalog.all.toList(growable: false)..sort()).join(', ');
}
