// CodeProjection — a comment- and string-literal-aware lexical projection
// of a procedure's source (Plan steps C.28 / C.29;
// `tom_brain_procedure_specification.md` § 7).
//
// Both static validator layers that scan a procedure's verbatim source —
// the sandbox validator (C.28) and the contract validator (C.29) — need
// the *code* of a procedure isolated from its prose. A banned word inside
// a `//` comment or a `'string literal'` must not trip the sandbox scan,
// and a `run(` token inside a comment must not be mistaken for the entry
// point by the contract scan. Both layers therefore work on a projection
// of the source in which:
//
//   - comment bodies (line + nested block comments) are blanked to spaces;
//   - string-literal text is blanked to spaces;
//   - the code inside string interpolations (`${ ... }` and `$identifier`)
//     is kept — interpolated expressions are real code and could otherwise
//     smuggle a reference past the scan;
//   - newlines are preserved everywhere, so byte positions and 1-based line
//     numbers in the projection map exactly onto the original source.
//
// The projection is deliberately *not* a full Dart parser. The
// "d4rt source parses" check (`procedure.parse.failed`) is the host's job;
// nested string literals inside an interpolation are not tracked. For the
// prototype's defence-in-depth static gates — backed by the runtime d4rt
// sandbox and the bridge layer — a lexical projection is the right amount
// of machinery. See Q-C.28.1 in `prototype_implementation_questions.md`.
//
// Extracted from the C.28 sandbox validator (which carried it inline) so
// the C.29 contract validator reuses the exact same projection rather than
// a second, subtly-different copy.

/// A comment- and string-aware lexical projection of Dart/d4rt source.
///
/// Pure utility — no state. Use [project] to blank comments and
/// string-literal text (keeping interpolated code), and [lineOf] to turn a
/// projection index into a 1-based line number.
final class CodeProjection {
  const CodeProjection._();

  /// Produces a copy of [src] with comment bodies and string-literal text
  /// blanked to spaces (newlines preserved, so positions and line numbers
  /// are stable), while keeping the code inside string interpolations.
  static String project(String src) {
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

  /// 1-based line number of [index] within [text].
  static int lineOf(String text, int index) {
    var line = 1;
    for (var i = 0; i < index && i < text.length; i++) {
      if (text[i] == '\n') line++;
    }
    return line;
  }

  /// Whether the char at [i] begins a raw string (`r"` / `r'`) and is not
  /// the tail of an identifier (so `recall(` is never mistaken for raw).
  static bool _isRawStringStart(String src, int i) {
    if (src[i] != 'r') return false;
    if (i + 1 >= src.length) return false;
    final next = src[i + 1];
    if (next != '"' && next != "'") return false;
    return i == 0 || !isIdentChar(src[i - 1]);
  }

  /// Consumes a (possibly nested) block comment starting at [start],
  /// writing spaces (newlines preserved) to [out]. Returns the index just
  /// past the comment, or the source length if unterminated.
  static int _blankBlockComment(String src, int start, StringBuffer out) {
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
  static int _blankString(String src, int start, StringBuffer out) {
    final n = src.length;
    var i = start;
    var raw = false;
    if (src[i] == 'r') {
      raw = true;
      out.write(' ');
      i++;
    }
    final quote = src[i];
    final triple = i + 2 < n && src[i + 1] == quote && src[i + 2] == quote;
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
  static bool _matchesDelim(String src, int i, String quote, int delimLen) {
    if (i + delimLen > src.length) return false;
    for (var k = 0; k < delimLen; k++) {
      if (src[i + k] != quote) return false;
    }
    return true;
  }

  /// Copies an interpolation starting at the `$` at [start] into [out] as
  /// code, blanking the `$` (and braces) themselves. Returns the index just
  /// past the interpolation.
  static int _copyInterpolation(String src, int start, StringBuffer out) {
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
    while (i < n && isIdentChar(src[i])) {
      out.write(src[i]);
      i++;
    }
    return i;
  }

  /// Whether [ch] is a Dart identifier character (letter, digit, `_`, `$`).
  static bool isIdentChar(String ch) {
    final code = ch.codeUnitAt(0);
    final isDigit = code >= 0x30 && code <= 0x39;
    final isUpper = code >= 0x41 && code <= 0x5A;
    final isLower = code >= 0x61 && code <= 0x7A;
    final isUnderscore = code == 0x5F;
    final isDollar = code == 0x24;
    return isDigit || isUpper || isLower || isUnderscore || isDollar;
  }
}
