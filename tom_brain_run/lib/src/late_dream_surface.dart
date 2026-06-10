// LateDreamSurface — the late-bound bridge that breaks the boot-order cycle
// between the engine's tool context (built *during* boot, in
// `tom_brain_procedure`) and the [DreamController] (built *after* boot, here in
// the run assembly).
//
// The `dream.control` tool reaches the cadence through the [ToolDreamSurface]
// its `ToolContext` carries. That context is assembled inside
// `BrainProcessBoot.boot`, before `provisionBrain` has a coordinator/engine to
// build the controller from — so the real surface does not exist yet when the
// context is wired. This holder is created *before* boot, threaded into the
// boot config as the engine's `toolDreamSurface`, and then [bind]-bound to the
// live controller once `provisionBrain` has built it.
//
// Until bound, every delegated call raises (a tool invoked before the cadence
// exists is a wiring bug, not a silent no-op). Binding is single-shot: a second
// [bind] is refused, because a process has exactly one dreaming controller.

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show ToolDreamSurface;

/// A mutable, single-shot holder for the process's [ToolDreamSurface].
///
/// Constructed before the cognition boots, passed into the boot as the engine's
/// dream surface, then [bind]-bound to the real [DreamController] once the run
/// assembly has built it. Delegates every [ToolDreamSurface] verb to the bound
/// target; raises [StateError] until one is bound.
final class LateDreamSurface implements ToolDreamSurface {
  ToolDreamSurface? _target;

  /// Whether a real surface has been [bind]-bound yet.
  bool get isBound => _target != null;

  /// Binds the live [target] surface. Single-shot: a second call raises
  /// [StateError], because the process has exactly one dreaming controller.
  void bind(ToolDreamSurface target) {
    if (_target != null) {
      throw StateError('LateDreamSurface is already bound');
    }
    _target = target;
  }

  ToolDreamSurface get _bound {
    final target = _target;
    if (target == null) {
      throw StateError(
        'LateDreamSurface used before it was bound — the dreaming cadence '
        'is not yet wired',
      );
    }
    return target;
  }

  @override
  void forceFor(Duration period) => _bound.forceFor(period);

  @override
  void suspend() => _bound.suspend();

  @override
  void resume() => _bound.resume();

  @override
  Map<String, Object?> dreamStatus() => _bound.dreamStatus();
}
