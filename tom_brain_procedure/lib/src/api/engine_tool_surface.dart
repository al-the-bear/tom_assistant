// EngineToolSurface — the engine's own realisation of [ToolEngineSurface], the
// narrow capability the `procedure.*` tools route through (Todo 4 / G-PR7;
// `tom_brain_procedure_specification.md` § 11, § 21.4).
//
// Until Todo 4 the engine built every run's `ToolContext` with `engine:` left
// unbound, so `procedure.list` / `procedure.run` (and the new `procedure.<verb>`
// aliases) raised `ToolSurfaceUnavailable`. This binds a real surface over the
// machinery the engine already owns — the run's depth-capped
// `RunProcedurePrimitive` and the engine's `ProcedureResolver` — so a procedure
// (or the substrate's tool loop) can list and invoke procedures by name. It
// opens **no new effect path** (Q-F.5) and introduces **no second interpreter**
// (PE-10): `runProcedure` is the same primitive a scripted `runProcedure(...)`
// call uses, so the hard depth cap (PE-3), run recording (PE-4), and effort
// roll-up are inherited unchanged.
//
// `runD4rtScript` stays deferred for the prototype: wiring a nested ad-hoc
// script needs the run's d4rt host, which is constructed *after* the tool
// context (a build-ordering knot out of Todo-4 scope). It throws the same
// `ToolSurfaceUnavailable` the unbound surface used to, so `script.run_d4rt`'s
// observable failure is unchanged — a deliberate "not yet wired", not a
// silent degrade.

import '../primitives_native/run_procedure_primitive.dart';
import '../procedure_store/procedure_resolver.dart';
import '../tools/tool_engine_surface.dart';
import '../tools/tool_failures.dart';
import 'procedure_inputs.dart';

/// Binds the engine's procedure machinery as a [ToolEngineSurface] for one run.
///
/// Constructed per run: [runPrimitive] is *that* run's depth-capped
/// `RunProcedurePrimitive` (so a tool-driven `runProcedure` advances the same
/// chain a scripted one does), and [resolver] is the engine's shared procedure
/// index.
final class EngineToolSurface implements ToolEngineSurface {
  /// Wraps [resolver] (the listing source) and [runPrimitive] (the run's
  /// depth-capped runner).
  const EngineToolSurface({
    required this.resolver,
    required this.runPrimitive,
  });

  /// The engine's procedure index — the source for [listProcedures].
  final ProcedureResolver resolver;

  /// This run's depth-capped procedure runner — backs [runProcedure].
  final RunProcedurePrimitive runPrimitive;

  @override
  Future<List<Map<String, Object?>>> listProcedures() async => <Map<String, Object?>>[
        for (final id in resolver.ids)
          <String, Object?>{
            'id': id,
            'origin': resolver.resolve(id).ref.origin.name,
            'version': resolver.latestVersion(id),
            'versions': resolver.versions(id),
          },
      ];

  @override
  Future<Map<String, Object?>> runProcedure(
    String id,
    Map<String, Object?> inputs, {
    int? version,
  }) async {
    final result = await runPrimitive.runProcedure(
      id,
      ProcedureInputs(inputs),
      version: version,
    );
    return <String, Object?>{
      'status': result.status.name,
      'outputs': result.outputs,
    };
  }

  @override
  Future<Object?> runD4rtScript(String source) {
    // Deferred (see file header): the nested-script host is built after the
    // tool context. Throw the same failure the unbound surface used to so the
    // `script.run_d4rt` tool's behaviour is preserved.
    throw const ToolSurfaceUnavailable(
      surface: 'engine',
      tool: 'script.run_d4rt',
    );
  }
}
