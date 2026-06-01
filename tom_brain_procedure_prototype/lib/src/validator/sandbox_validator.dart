// SandboxValidator — the second of the three validator layers (Plan step
// C.28; `tom_brain_procedure_prototype_specification.md` § 7 row 3, § 4.2).
//
// This layer owns the spec's third row — "No forbidden imports / SDK
// touchpoints / disallowed identifiers" → `procedure.sandbox.violation`.
// It is the *static* half of the PE-1 surface lock: the bridged primitive
// API is the only surface a procedure can touch, enforced at two layers
// (d4rt sandbox + bridge). The validator scans a procedure's verbatim
// source *before* it ever reaches the host, so a script that imports
// `dart:io` or calls `Process.run` is kept out of the runnable set rather
// than being stopped only at runtime.
//
// The scan works on a **code projection** of the source: comments and the
// literal text of string literals are blanked out (replaced with spaces,
// newlines preserved), while the code inside string interpolations
// (`${ ... }` and `$identifier`) is kept — interpolated expressions are
// real code and could otherwise smuggle a disallowed reference past the
// scan. Working on the projection means a banned word that appears only in
// a comment or inside a string literal does not trip the validator.
//
// What the projection deliberately does *not* do: it is not a full Dart
// parser. The "d4rt source parses" check (`procedure.parse.failed`) is the
// host's job; nested string literals inside an interpolation are not
// tracked. For the prototype's defence-in-depth static gate — backed by
// the runtime d4rt sandbox and the bridge layer — a lexical projection is
// the right amount of machinery. See Q-C.28.x in
// `prototype_implementation_questions.md`.

import '../procedure_store/procedure_loader.dart';
import 'procedure_sandbox_violation.dart';

/// Statically rejects procedure sources that reach outside the bridged
/// primitive API: `import`/`export` directives, or references to a
/// disallowed top-level identifier (an SDK gateway such as `Process`,
/// `File`, `Isolate`).
///
/// Stateless once constructed — every method is a pure function of its
/// input and the configured deny sets. Construct once and reuse, or use
/// the [shared] instance with the default deny sets. Failures throw
/// [ProcedureSandboxViolation] (wire code `procedure.sandbox.violation`).
final class SandboxValidator {
  /// Builds a validator with the given deny sets (defaulting to the
  /// built-in [defaultDisallowedDirectives] / [defaultDisallowedIdentifiers]).
  const SandboxValidator({
    this.disallowedDirectives = defaultDisallowedDirectives,
    this.disallowedIdentifiers = defaultDisallowedIdentifiers,
  });

  /// A shared, reusable validator with the default deny sets.
  static const SandboxValidator shared = SandboxValidator();

  /// Directive keywords a procedure may never use. Procedures may not
  /// `import` (or `export`) anything (§ 4.2); both pull in code from
  /// outside the bridged surface. `library` / `part` are excluded — they
  /// cannot legitimately appear in a single-file procedure, so the host's
  /// parse layer (`procedure.parse.failed`) rejects that shape first, and
  /// keeping them out of this set avoids false positives on the common
  /// identifiers `part` / `library`. See Q-C.28.2.
  static const Set<String> defaultDisallowedDirectives = {'import', 'export'};

  /// Top-level identifiers a procedure may never reference. These are the
  /// SDK gateways through which a script could touch the file system, the
  /// network, processes, isolates, the standard streams, or `eval`-style
  /// indirection — every effect PE-1 reserves for the bridged primitives.
  ///
  /// Only *top-level* references are matched: `obj.Process` (a member named
  /// `Process`) is not flagged, because the deny scan requires the name to
  /// not be preceded by a `.`. A procedure cannot construct one of these
  /// types without naming it at the top level, so the top-level scan is
  /// sufficient for the static gate.
  static const Set<String> defaultDisallowedIdentifiers = {
    // dart:io — file system
    'File', 'Directory', 'Link', 'FileSystemEntity', 'FileStat',
    'RandomAccessFile',
    // dart:io — processes + platform
    'Process', 'ProcessResult', 'ProcessSignal', 'Platform',
    // dart:io — sockets + network
    'Socket', 'RawSocket', 'ServerSocket', 'RawServerSocket', 'SecureSocket',
    'RawDatagramSocket', 'Datagram', 'InternetAddress',
    'HttpClient', 'HttpServer', 'WebSocket',
    // dart:html
    'HttpRequest', 'window', 'document',
    // dart:isolate — concurrency / interpreter spawning
    'Isolate', 'ReceivePort', 'RawReceivePort', 'SendPort', 'Capability',
    // dart:io — standard streams + process control
    'stdin', 'stdout', 'stderr', 'exit', 'pid',
    // eval-style indirection over the procedure's own source
    'eval',
  };

  /// The directive keywords this validator rejects.
  final Set<String> disallowedDirectives;

  /// The top-level identifiers this validator rejects.
  final Set<String> disallowedIdentifiers;

  /// Scans a bare [source] for forbidden directives and disallowed
  /// top-level identifiers.
  ///
  /// [procedureId] is woven into the failure message when known. Throws
  /// [ProcedureSandboxViolation] on the first violation found (directives
  /// are checked before identifiers).
  void validateSource(String source, {String? procedureId}) {
    final projection = _codeProjection(source);
    _checkDirectives(projection, procedureId);
    _checkIdentifiers(projection, procedureId);
  }

  /// Scans a loaded [procedure]'s verbatim source, attributing any failure
  /// to its header id.
  void validate(LoadedProcedure procedure) =>
      validateSource(procedure.source, procedureId: procedure.header.id);

  /// Scans every procedure in a loaded set. Throws on the first violation.
  void validateAll(Iterable<LoadedProcedure> procedures) {
    for (final procedure in procedures) {
      validate(procedure);
    }
  }

  // --- checks ------------------------------------------------------------

  void _checkDirectives(String projection, String? procedureId) {
    for (final keyword in disallowedDirectives) {
      final match =
          RegExp('(?<![\\w\$.])$keyword(?![\\w\$])').firstMatch(projection);
      if (match != null) {
        throw ProcedureSandboxViolation(
          'procedures may not use the `$keyword` directive; the bridged '
          'primitive API is the only surface a procedure can touch (PE-1)',
          kind: SandboxViolationKind.forbiddenDirective,
          offender: keyword,
          line: _lineOf(projection, match.start),
          procedureId: procedureId,
        );
      }
    }
  }

  void _checkIdentifiers(String projection, String? procedureId) {
    for (final identifier in disallowedIdentifiers) {
      final match = RegExp('(?<![\\w\$.])${RegExp.escape(identifier)}(?![\\w\$])')
          .firstMatch(projection);
      if (match != null) {
        throw ProcedureSandboxViolation(
          'procedures may not reference `$identifier`; reach the file '
          'system, network, processes, isolates, or providers only through '
          'a bridged primitive (PE-1)',
          kind: SandboxViolationKind.disallowedIdentifier,
          offender: identifier,
          line: _lineOf(projection, match.start),
          procedureId: procedureId,
        );
      }
    }
  }

  /// 1-based line number of [index] within [text].
  int _lineOf(String text, int index) {
    var line = 1;
    for (var i = 0; i < index && i < text.length; i++) {
      if (text[i] == '\n') line++;
    }
    return line;
  }

  // --- code projection ---------------------------------------------------

  /// Produces a copy of [src] with comment bodies and string-literal text
  /// blanked to spaces (newlines preserved, so positions and line numbers
  /// are stable), while keeping the code inside string interpolations.
  String _codeProjection(String src) {
    final out = StringBuffer();
    final n = src.length;
    var i = 0;
    while (i < n) {
      final c = src[i];
      // line comment
      if (c == '/' && i + 1 < n && src[i + 1] == '/') {
        while (i < n && src[i] != '\n') {
          out.write(' ');
          i++;
        }
        continue;
      }
      // block comment (Dart block comments nest)
      if (c == '/' && i + 1 < n && src[i + 1] == '*') {
        i = _blankBlockComment(src, i, out);
        continue;
      }
      // string literal (raw or normal, single/double, possibly triple)
      if (c == '"' || c == "'" || _isRawStringStart(src, i)) {
        i = _blankString(src, i, out);
        continue;
      }
      out.write(c);
      i++;
    }
    return out.toString();
  }

  /// Whether the char at [i] begins a raw string (`r"` / `r'`) and is not
  /// the tail of an identifier (so `recall(` is never mistaken for raw).
  bool _isRawStringStart(String src, int i) {
    if (src[i] != 'r') return false;
    if (i + 1 >= src.length) return false;
    final next = src[i + 1];
    if (next != '"' && next != "'") return false;
    return i == 0 || !_isIdentChar(src[i - 1]);
  }

  /// Consumes a (possibly nested) block comment starting at [start],
  /// writing spaces (newlines preserved) to [out]. Returns the index just
  /// past the comment, or the source length if unterminated.
  int _blankBlockComment(String src, int start, StringBuffer out) {
    final n = src.length;
    var i = start;
    var depth = 0;
    while (i < n) {
      if (src[i] == '/' && i + 1 < n && src[i + 1] == '*') {
        depth++;
        out.write('  ');
        i += 2;
        continue;
      }
      if (src[i] == '*' && i + 1 < n && src[i + 1] == '/') {
        depth--;
        out.write('  ');
        i += 2;
        if (depth == 0) return i;
        continue;
      }
      out.write(src[i] == '\n' ? '\n' : ' ');
      i++;
    }
    return i;
  }

  /// Consumes a string literal starting at [start], blanking the literal
  /// text to spaces (newlines preserved) but copying interpolated code
  /// (`${ ... }` and `$identifier`) verbatim. Returns the index just past
  /// the closing delimiter, or the source length if unterminated.
  int _blankString(String src, int start, StringBuffer out) {
    final n = src.length;
    var i = start;
    var raw = false;
    if (src[i] == 'r') {
      raw = true;
      out.write(' ');
      i++;
    }
    final quote = src[i];
    final triple =
        i + 2 < n && src[i + 1] == quote && src[i + 2] == quote;
    final delimLen = triple ? 3 : 1;
    out.write(' ' * delimLen);
    i += delimLen;

    while (i < n) {
      if (_matchesDelim(src, i, quote, delimLen)) {
        out.write(' ' * delimLen);
        return i + delimLen;
      }
      final ch = src[i];
      if (!raw && ch == r'\') {
        out.write(' ');
        i++;
        if (i < n) {
          out.write(src[i] == '\n' ? '\n' : ' ');
          i++;
        }
        continue;
      }
      if (!raw && ch == r'$') {
        i = _copyInterpolation(src, i, out);
        continue;
      }
      out.write(ch == '\n' ? '\n' : ' ');
      i++;
    }
    return i;
  }

  /// Whether the [delimLen] chars at [i] are all [quote] (the closing
  /// delimiter of a string).
  bool _matchesDelim(String src, int i, String quote, int delimLen) {
    if (i + delimLen > src.length) return false;
    for (var k = 0; k < delimLen; k++) {
      if (src[i + k] != quote) return false;
    }
    return true;
  }

  /// Copies an interpolation starting at the `$` at [start] into [out] as
  /// code, blanking the `$` (and braces) themselves. Returns the index just
  /// past the interpolation.
  int _copyInterpolation(String src, int start, StringBuffer out) {
    final n = src.length;
    var i = start + 1; // skip '$'
    out.write(' ');
    if (i < n && src[i] == '{') {
      out.write(' ');
      i++;
      var depth = 1;
      while (i < n && depth > 0) {
        final cc = src[i];
        if (cc == '{') {
          depth++;
        } else if (cc == '}') {
          depth--;
          if (depth == 0) {
            out.write(' ');
            i++;
            break;
          }
        }
        out.write(cc == '\n' ? '\n' : cc);
        i++;
      }
      return i;
    }
    // simple `$identifier` interpolation — copy the identifier as code
    while (i < n && _isIdentChar(src[i])) {
      out.write(src[i]);
      i++;
    }
    return i;
  }

  bool _isIdentChar(String ch) {
    final code = ch.codeUnitAt(0);
    final isDigit = code >= 0x30 && code <= 0x39;
    final isUpper = code >= 0x41 && code <= 0x5A;
    final isLower = code >= 0x61 && code <= 0x7A;
    final isUnderscore = code == 0x5F;
    final isDollar = code == 0x24;
    return isDigit || isUpper || isLower || isUnderscore || isDollar;
  }
}
