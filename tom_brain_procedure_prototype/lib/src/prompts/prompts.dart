// Extension F — prompt-assembly module barrel
// (`tom_brain_procedure_prototype_specification.md` § 16, § 21.5, § 21.7).
//
// Step 1 lands the placeholder system: the scope stack, the d4rt
// expression context + evaluator seam, the resolver, and the typed
// failures. The `PromptTemplateConfig` loader (§ 21.5) lands at step 3 in
// the `config/` module (beside the layer-1/2 provider + model configs it
// binds), not here — the dependency arrows point `config → prompts` only,
// so the template loader (which depends on `ProviderRegistry` /
// `ModelConfigStore`) lives where it can import them without a cycle. It
// is exported through `config/config.dart`.

export 'd4rt_expression_context.dart';
export 'expression_evaluator.dart';
export 'placeholder_errors.dart';
export 'placeholder_resolver.dart';
export 'placeholder_stack.dart';
