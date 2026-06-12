// Extension F — prompt-assembly module barrel
// (`tom_brain_procedure_specification.md` § 16, § 21.5, § 21.7).
//
// The placeholder resolver *core* — the scope stack, the resolver, the
// typed failures, and the `PlaceholderExpressions` seam — now lives in
// `tom_core_agentic` (the lowest shared layer, so the substrate / access /
// memory config loaders resolve through the same mechanism). What stays
// here is the engine's d4rt backing for that seam: the
// `D4rtExpressionContext` (which synthesises d4rt source) and the
// `ExpressionEvaluator` implementations that own the d4rt dependency.

export 'd4rt_expression_context.dart';
export 'expression_evaluator.dart';
