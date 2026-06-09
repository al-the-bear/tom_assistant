// D4rtExpressionContext — the initialised d4rt evaluation state a
// `PlaceholderResolver` resolves `${{ … }}` expressions against
// (Extension F, step 1; `tom_brain_procedure_specification.md`
// § 21.7).
//
// § 21.7: "A `PlaceholderResolver` holds a `D4rtExpressionContext` — a
// d4rt interpreter whose state is set up by running a setup script first
// […] Once the context is initialised, expressions are evaluated against
// that interpreter state."
//
// The context pairs a [PlaceholderStack] (the live binding namespace) with
// an [ExpressionEvaluator] (the d4rt run seam). [runSetup] executes the
// template's `setup:` script once and merges the bindings it returns into
// the current frame. [evaluate] turns a single `${{ expr }}` body into a
// one-function d4rt source whose parameters are the current scope's
// identifier bindings, hands it to the evaluator, and surfaces any d4rt
// failure as a typed [PlaceholderExpressionException].

import 'expression_evaluator.dart';
import 'placeholder_errors.dart';
import 'placeholder_stack.dart';

/// The synthesised entry-point name for an evaluated expression. Chosen to
/// be collision-proof with any identifier a binding or expression uses.
const String _expressionEntryPoint = r'$tomBrainPlaceholderExpr';

/// Holds the d4rt state placeholder expressions evaluate against: a
/// [PlaceholderStack] of bindings plus the [ExpressionEvaluator] that runs
/// d4rt source.
final class D4rtExpressionContext {
  /// Creates a context over [stack] and [evaluator].
  ///
  /// Defaults to a fresh [PlaceholderStack] and a standalone
  /// [D4rtExpressionEvaluator] (a bare `tom_d4rt` interpreter, PE-10) so a
  /// resolver can be stood up without an engine host; production wiring
  /// passes a [HostExpressionEvaluator] to share the engine's interpreter.
  D4rtExpressionContext({
    PlaceholderStack? stack,
    ExpressionEvaluator? evaluator,
  })  : stack = stack ?? PlaceholderStack(),
        _evaluator = evaluator ?? D4rtExpressionEvaluator();

  /// The live binding namespace both placeholder forms read.
  final PlaceholderStack stack;

  final ExpressionEvaluator _evaluator;

  /// Runs a [setupSource] script once and merges the bindings it returns
  /// into the current scope frame.
  ///
  /// The prototype's setup contract is intentionally simple: the script's
  /// [entryPoint] function returns a `Map` of name → value bindings (a
  /// `null` return binds nothing). This keeps the setup mechanism reusing
  /// the same evaluator the expression form uses, and keeps every binding
  /// flowing through the one [PlaceholderStack] namespace (§ 21.7).
  ///
  /// A non-`Map`, non-`null` return is a setup-contract violation and
  /// throws a [StateError]; a script that fails to run rethrows the
  /// evaluator's error.
  Future<void> runSetup(
    String setupSource, {
    String entryPoint = 'main',
  }) async {
    final result = await _evaluator.evaluate(
      setupSource,
      entryPoint: entryPoint,
      inputs: const <Object?>[],
    );
    if (result == null) {
      return;
    }
    if (result is Map) {
      stack.bindAll(<String, Object?>{
        for (final entry in result.entries) '${entry.key}': entry.value,
      });
      return;
    }
    throw StateError(
      'placeholder setup script "$entryPoint" must return a Map of bindings; '
      'got ${result.runtimeType}',
    );
  }

  /// Evaluates a single `${{ … }}` [expression] against the current scope.
  ///
  /// The current scope's identifier bindings become the parameters of a
  /// synthesised one-function d4rt source (`return (<expression>);`),
  /// passed positionally — so the expression reads exactly the live
  /// namespace the simple `${name}` form reads. Any d4rt parse or runtime
  /// failure is surfaced as a [PlaceholderExpressionException].
  Future<Object?> evaluate(String expression) async {
    final bindings = stack.flatten();
    final names =
        bindings.keys.where(isSimpleIdentifier).toList(growable: false);
    final source = 'dynamic $_expressionEntryPoint(${names.join(', ')}) {\n'
        '  return ($expression);\n'
        '}\n';
    final inputs = <Object?>[for (final name in names) bindings[name]];
    try {
      return await _evaluator.evaluate(
        source,
        entryPoint: _expressionEntryPoint,
        inputs: inputs,
      );
    } catch (error) {
      throw PlaceholderExpressionException(
        expression: expression,
        cause: error,
      );
    }
  }
}
