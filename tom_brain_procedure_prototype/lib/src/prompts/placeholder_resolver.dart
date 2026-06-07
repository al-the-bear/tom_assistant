// PlaceholderResolver — expands the four placeholder forms in a prompt
// scaffold (Extension F, step 1;
// `tom_brain_procedure_prototype_specification.md` § 21.7, § 21.10).
//
// Forms (§ 21.7):
//   ${name}      simple-identifier fast path — reads a binding from the
//                current scope; equivalent to `${{ name }}`.
//   ${{ expr }}  an arbitrary d4rt expression evaluated against the
//                interpreter state (`D4rtExpressionContext`).
//   ${env:NAME}  process-environment read — the one pure, non-d4rt form.
//   ${file:…}    reserved prefixes: recognised but not yet resolving, so a
//   ${state:…}   template author can use them without collision. They pass
//                through verbatim and are not re-scanned.
//
// After each substitution pass the result is re-scanned; expansion repeats
// up to [maxRecursion] levels (default 10) and then errors with
// `placeholder.recursion.exceeded` — so a placeholder whose value embeds
// further placeholders expands, while a cycle is caught at the cap.
//
// Strict vs lenient (§ 21.10): an unknown `${name}` / `${env:NAME}` either
// errors (`placeholder.unresolved`, strict) or renders as an empty string
// (lenient). The default is strict — an unresolved placeholder in an
// assembled prompt is a template bug we surface loudly rather than hide.

import 'dart:io';

import 'd4rt_expression_context.dart';
import 'placeholder_errors.dart';
import 'placeholder_stack.dart';

/// Which kind of placeholder a scan found.
enum _PlaceholderForm { simple, env, expression, reserved }

/// One placeholder token located by the scanner.
typedef _Token = ({
  int start,
  int tokenEnd,
  _PlaceholderForm form,
  String body,
});

/// Resolves placeholder scaffolds against a [D4rtExpressionContext].
///
/// The resolver is stateful only through its [context]'s scope stack:
/// callers push / pop / bind on `resolver.stack` to model nested call
/// frames, then [resolve] a scaffold against the current scope.
final class PlaceholderResolver {
  /// Creates a resolver over [context] (a fresh standalone context by
  /// default), in [strict] or lenient unknown-handling mode, capping
  /// recursive expansion at [maxRecursion] levels.
  PlaceholderResolver({
    D4rtExpressionContext? context,
    this.strict = true,
    this.maxRecursion = 10,
    Map<String, String>? environment,
  })  : context = context ?? D4rtExpressionContext(),
        environment = environment ?? Platform.environment;

  /// The d4rt evaluation state expressions resolve against.
  final D4rtExpressionContext context;

  /// The environment `${env:NAME}` reads from. Defaults to the live
  /// process environment ([Platform.environment]); an explicit map makes
  /// the env form injectable (config loaders pass a fixed map so a
  /// `${env:NAME}` apiKey resolves deterministically, § 21.6).
  final Map<String, String> environment;

  /// When true, an unknown `${name}` / `${env:NAME}` errors with
  /// [PlaceholderUnresolvedException]; when false it renders as empty.
  final bool strict;

  /// Maximum number of re-scan passes before declaring non-convergence.
  final int maxRecursion;

  /// Convenience accessor for the scope stack callers bind into.
  PlaceholderStack get stack => context.stack;

  /// Expands every resolvable placeholder in [template], re-scanning until
  /// the text converges or the recursion cap is hit.
  ///
  /// Reserved (`${file:…}` / `${state:…}`) placeholders are left verbatim
  /// and do not count as resolvable, so a template of only reserved
  /// placeholders converges immediately.
  Future<String> resolve(String template) async {
    var current = template;
    var level = 0;
    while (_hasResolvable(current)) {
      if (level >= maxRecursion) {
        throw PlaceholderRecursionException(
          maxRecursion: maxRecursion,
          residue: current,
        );
      }
      current = await _expandOnce(current);
      level++;
    }
    return current;
  }

  /// One left-to-right substitution pass: every resolvable placeholder is
  /// replaced once; reserved placeholders are copied through verbatim.
  Future<String> _expandOnce(String input) async {
    final out = StringBuffer();
    var index = 0;
    while (index < input.length) {
      final token = _nextToken(input, index);
      if (token == null) {
        out.write(input.substring(index));
        break;
      }
      out.write(input.substring(index, token.start));
      switch (token.form) {
        case _PlaceholderForm.reserved:
          out.write(input.substring(token.start, token.tokenEnd));
        case _PlaceholderForm.env:
          out.write(_resolveEnv(token.body));
        case _PlaceholderForm.simple:
          out.write(_resolveSimple(token.body));
        case _PlaceholderForm.expression:
          out.write(_render(await context.evaluate(token.body)));
      }
      index = token.tokenEnd;
    }
    return out.toString();
  }

  /// Whether [input] still holds a *resolvable* placeholder (reserved
  /// prefixes do not count).
  bool _hasResolvable(String input) {
    var index = 0;
    while (true) {
      final token = _nextToken(input, index);
      if (token == null) {
        return false;
      }
      if (token.form != _PlaceholderForm.reserved) {
        return true;
      }
      index = token.tokenEnd;
    }
  }

  String _resolveEnv(String name) {
    final value = environment[name];
    if (value != null) {
      return value;
    }
    if (strict) {
      throw PlaceholderUnresolvedException('env:$name');
    }
    return '';
  }

  String _resolveSimple(String name) {
    if (stack.has(name)) {
      return _render(stack.lookup(name));
    }
    if (strict) {
      throw PlaceholderUnresolvedException(name);
    }
    return '';
  }

  static String _render(Object? value) => value == null ? '' : '$value';

  /// Locates the next placeholder at or after [from], or `null` if none.
  ///
  /// Recognises `${{ … }}` (expression, brace-balanced) before `${…}`
  /// (simple / env / reserved). An unterminated `${` is skipped so it is
  /// emitted as literal text rather than swallowing the rest of the input.
  _Token? _nextToken(String input, int from) {
    var search = from;
    while (true) {
      final open = input.indexOf(r'${', search);
      if (open < 0) {
        return null;
      }
      if (input.startsWith(r'${{', open)) {
        final end = _findExpressionEnd(input, open + 3);
        if (end < 0) {
          search = open + 3;
          continue;
        }
        return (
          start: open,
          tokenEnd: end + 2,
          form: _PlaceholderForm.expression,
          body: input.substring(open + 3, end).trim(),
        );
      }
      final close = input.indexOf('}', open + 2);
      if (close < 0) {
        search = open + 2;
        continue;
      }
      final raw = input.substring(open + 2, close).trim();
      return (
        start: open,
        tokenEnd: close + 1,
        form: _classify(raw),
        body: _bodyOf(raw),
      );
    }
  }

  static _PlaceholderForm _classify(String raw) {
    if (raw.startsWith('env:')) {
      return _PlaceholderForm.env;
    }
    if (raw.startsWith('file:') || raw.startsWith('state:')) {
      return _PlaceholderForm.reserved;
    }
    return _PlaceholderForm.simple;
  }

  /// The lookup key for a `${…}` body: the env name without its `env:`
  /// prefix, or the raw body for the simple / reserved forms (reserved
  /// bodies are copied verbatim from the source, so the key is unused).
  static String _bodyOf(String raw) =>
      raw.startsWith('env:') ? raw.substring('env:'.length).trim() : raw;

  /// Index of the first `}` of the closing `}}` for an expression that
  /// opened at [start] (just past the `${{`), or `-1` if unterminated.
  ///
  /// Tracks nested `{ }` so an inner brace (e.g. a map literal in the
  /// expression) does not close the placeholder early.
  static int _findExpressionEnd(String input, int start) {
    var depth = 0;
    for (var i = start; i < input.length; i++) {
      final char = input[i];
      if (char == '{') {
        depth++;
      } else if (char == '}') {
        if (depth > 0) {
          depth--;
        } else if (i + 1 < input.length && input[i + 1] == '}') {
          return i;
        } else {
          return -1;
        }
      }
    }
    return -1;
  }
}
