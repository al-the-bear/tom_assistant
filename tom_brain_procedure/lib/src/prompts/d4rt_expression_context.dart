// D4rtExpressionContext — the d4rt-backed implementation of the shared
// `PlaceholderExpressions` seam (Extension F, step 1;
// `tom_brain_procedure_specification.md` § 21.7).
//
// The placeholder resolver core lives in `tom_core_agentic` and keeps no
// d4rt dependency; it delegates the `${{ … }}` form to an injected
// [PlaceholderExpressions] backing. This class is that backing for the
// engine: it turns a single `${{ expr }}` body into a one-function d4rt
// source whose parameters are the current scope's identifier bindings,
// hands it to an [ExpressionEvaluator], and surfaces any d4rt failure as a
// typed [PlaceholderExpressionException].
//
// [runSetup] executes a template's `setup:` script once and returns the
// bindings it produced for the caller to seed into the resolver's stack.

import 'package:tom_core_agentic/tom_core_agentic.dart';

import 'expression_evaluator.dart';

/// The synthesised entry-point name for an evaluated expression. Chosen to
/// be collision-proof with any identifier a binding or expression uses.
const String _expressionEntryPoint = r'$tomBrainPlaceholderExpr';

/// Evaluates the `${{ … }}` placeholder form by running it as a d4rt
/// expression against the resolver's scope.
///
/// Pairs an [ExpressionEvaluator] (the d4rt run seam) with the source
/// synthesis. Defaults to a standalone [D4rtExpressionEvaluator] (a bare
/// `tom_d4rt` interpreter, PE-10) so a resolver can be stood up without an
/// engine host; production wiring passes a [HostExpressionEvaluator] to
/// share the engine's interpreter.
final class D4rtExpressionContext implements PlaceholderExpressions {
  /// Creates a context over [evaluator] (a fresh standalone
  /// [D4rtExpressionEvaluator] by default).
  D4rtExpressionContext({ExpressionEvaluator? evaluator})
      : _evaluator = evaluator ?? D4rtExpressionEvaluator();

  final ExpressionEvaluator _evaluator;

  /// Runs a [setupSource] script once and returns the bindings it produced.
  ///
  /// The setup contract is intentionally simple: the script's [entryPoint]
  /// function returns a `Map` of name → value bindings (a `null` return
  /// binds nothing, yielding an empty map). The caller seeds the result
  /// into the resolver's stack (`resolver.stack.bindAll(...)`).
  ///
  /// A non-`Map`, non-`null` return is a setup-contract violation and
  /// throws a [StateError]; a script that fails to run rethrows the
  /// evaluator's error.
  Future<Map<String, Object?>> runSetup(
    String setupSource, {
    String entryPoint = 'main',
  }) async {
    final result = await _evaluator.evaluate(
      setupSource,
      entryPoint: entryPoint,
      inputs: const <Object?>[],
    );
    if (result == null) {
      return <String, Object?>{};
    }
    if (result is Map) {
      return <String, Object?>{
        for (final entry in result.entries) '${entry.key}': entry.value,
      };
    }
    throw StateError(
      'placeholder setup script "$entryPoint" must return a Map of bindings; '
      'got ${result.runtimeType}',
    );
  }

  /// Evaluates a single `${{ … }}` [body] against [scope].
  ///
  /// The scope's identifier bindings become the parameters of a synthesised
  /// one-function d4rt source (`return (<body>);`), passed positionally — so
  /// the expression reads exactly the live namespace the simple `${name}`
  /// form reads. Any d4rt parse or runtime failure is surfaced as a
  /// [PlaceholderExpressionException].
  @override
  Future<Object?> evaluate(String body, Map<String, Object?> scope) async {
    final names =
        scope.keys.where(isSimpleIdentifier).toList(growable: false);
    final source = 'dynamic $_expressionEntryPoint(${names.join(', ')}) {\n'
        '  return ($body);\n'
        '}\n';
    final inputs = <Object?>[for (final name in names) scope[name]];
    try {
      return await _evaluator.evaluate(
        source,
        entryPoint: _expressionEntryPoint,
        inputs: inputs,
      );
    } catch (error) {
      throw PlaceholderExpressionException(
        expression: body,
        cause: error,
      );
    }
  }
}
