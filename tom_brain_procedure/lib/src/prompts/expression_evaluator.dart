// ExpressionEvaluator — the seam through which the placeholder system runs
// d4rt source (Extension F, step 1;
// `tom_brain_procedure_specification.md` § 21.7, PE-10).
//
// § 21.7 requires the `${{ … }}` form to be a **d4rt expression**
// evaluated against an interpreter, reusing "the engine's own d4rt host
// (PE-10) rather than embedding a second expression language". This thin
// interface is that reuse point: `D4rtExpressionContext` synthesises a
// one-function d4rt source and hands it to an `ExpressionEvaluator`.
//
// Two implementations ship:
//
//   - [D4rtExpressionEvaluator] owns a bare [D4rt] interpreter — the
//     standalone default a `PlaceholderResolver` constructs when no host
//     is wired in. It reuses `tom_d4rt` (no new interpreter, PE-10); a
//     bare interpreter is enough for expressions whose only inputs are the
//     scope locals passed positionally.
//   - [HostExpressionEvaluator] adapts the engine's own [D4rtDcliHost], so
//     production prompt assembly evaluates expressions on the **same**
//     interpreter a procedure body runs on — identical sandbox, identical
//     `mem` / `sub` globals (the path § 21.7's "sandboxed exactly as a
//     procedure body is" describes). The adapter points prompts → host
//     (higher level → lower level), never the reverse.

import 'package:tom_d4rt/d4rt.dart';

import '../d4rt_host/d4rt_dcli_host.dart';

/// Runs a d4rt [source], invoking the top-level function [entryPoint] with
/// [inputs] passed positionally, and returns its result.
///
/// The placeholder system uses this for both the optional `setup` script
/// (run once to seed bindings) and each `${{ … }}` expression (synthesised
/// into a one-function source). Implementations may throw any d4rt error;
/// [D4rtExpressionContext] is responsible for classifying those as
/// placeholder failures.
abstract interface class ExpressionEvaluator {
  /// Executes [source] and returns the value of [entryPoint].
  Future<Object?> evaluate(
    String source, {
    String entryPoint,
    List<Object?> inputs,
  });
}

/// An [ExpressionEvaluator] over a standalone [D4rt] interpreter.
///
/// Reuses `tom_d4rt` (PE-10); no bridges are registered, so an expression
/// can touch only the scope locals it is handed positionally — the locked
/// default a `PlaceholderResolver` uses when assembled without an engine
/// host.
final class D4rtExpressionEvaluator implements ExpressionEvaluator {
  /// Wraps [interpreter], or creates a fresh [D4rt] when none is supplied.
  D4rtExpressionEvaluator([D4rt? interpreter])
      : _interpreter = interpreter ?? D4rt();

  final D4rt _interpreter;

  @override
  Future<Object?> evaluate(
    String source, {
    String entryPoint = 'main',
    List<Object?> inputs = const <Object?>[],
  }) async {
    // `execute` returns `Object?` — a direct value for synchronous source,
    // a `Future` for source that awaits. Awaiting normalises both, exactly
    // as `D4rtDcliHost.run` does.
    return await _interpreter.execute(
      source: source,
      name: entryPoint,
      positionalArgs: inputs,
    );
  }
}

/// An [ExpressionEvaluator] that runs source on the engine's own
/// [D4rtDcliHost].
///
/// Production prompt assembly uses this so expressions evaluate under the
/// same sandbox + bridged globals (`mem` / `sub`) as a procedure body
/// (§ 21.7). The host owns the interpreter; this adapter only forwards.
final class HostExpressionEvaluator implements ExpressionEvaluator {
  /// Adapts [host] as an expression evaluator.
  const HostExpressionEvaluator(this._host);

  final D4rtDcliHost _host;

  @override
  Future<Object?> evaluate(
    String source, {
    String entryPoint = 'main',
    List<Object?> inputs = const <Object?>[],
  }) {
    return _host.run(source, entryPoint: entryPoint, inputs: inputs);
  }
}
