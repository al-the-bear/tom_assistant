// runProcedure — the first engine-native primitive (Plan step C.19;
// `tom_brain_procedure_specification.md` § 5.1, § 3.4;
// `tom_brain_definition.md` § 7.3).
//
// ── What C.19 owns ──────────────────────────────────────────────────
//
// `runProcedure(id, inputs, {version, depthDelta})` invokes another
// procedure. The engine-native part C.19 implements is the **recursion
// bookkeeping**: it tracks the depth of the currently-executing procedure
// frame, computes the child frame's depth, and refuses any call that
// would push the chain past the hard cap of 10 (PE-3) — the 11th level
// errors with [RecursionLimitExceeded]. There is no
// `request_depth_extension` in v1; the cap cannot be raised from inside.
//
// ── What C.19 deliberately does NOT own ─────────────────────────────
//
// *Resolution and execution* of the target procedure (parsing its header,
// loading its source, running it on the host) belong to the procedure
// store + loader + resolver (C.23–C.26) and the engine API (C.38). C.19
// keeps those behind a single injectable [ProcedureExecutor] seam so the
// depth machinery is testable in isolation now and the store/engine plug
// in their real executor later without touching this primitive. This is
// the same separation-of-concerns the host (C.16) used for its
// native-primitive seam: C.19 supplies the *primitive*, the later steps
// supply what it delegates to.

import '../api/procedure_inputs.dart';
import '../api/procedure_result.dart';
import 'recursion_limit_exceeded.dart';

/// A single resolved request to run a procedure, handed to a
/// [ProcedureExecutor].
///
/// Carries the target [id] (a procedure id string such as `think_v1`), the
/// optional pinned [version], the [inputs], and the [depth] the engine has
/// already validated this call may run at. The executor's only job is to
/// resolve and run the target; the depth has already passed the cap check
/// by the time it sees a [ProcedureCall].
final class ProcedureCall {
  /// Records a depth-validated request to run [id] with [inputs].
  const ProcedureCall({
    required this.id,
    required this.inputs,
    required this.depth,
    this.version,
  });

  /// The target procedure id (e.g. `think_v1`).
  final String id;

  /// The explicit version requested, or `null` to let the resolver pick.
  final int? version;

  /// The inputs to pass to the target procedure's `run` entry point.
  final ProcedureInputs inputs;

  /// The (cap-validated) frame depth this call runs at. The top-level
  /// procedure runs at depth 1; each nested `runProcedure` adds its
  /// `depthDelta`.
  final int depth;

  @override
  String toString() {
    final target = version == null ? id : '$id (v$version)';
    return 'ProcedureCall($target @ depth $depth)';
  }
}

/// Resolves and runs the procedure named by a [ProcedureCall].
///
/// Supplied by the store/engine (C.23–C.26, C.38); the depth-capped
/// primitive delegates the actual run to it. Must complete with the
/// target procedure's [ProcedureResult].
typedef ProcedureExecutor = Future<ProcedureResult> Function(
  ProcedureCall call,
);

/// The engine-native `runProcedure` primitive with its hard recursion cap.
///
/// Holds the depth of the currently-executing frame and guards every
/// nested invocation against the [hardDepthCap]. The top-level procedure
/// the engine invokes runs at [startDepth] (1 by default); a
/// `runProcedure` call from a frame at depth `d` targets depth
/// `d + depthDelta`, and any target depth above [hardDepthCap] is refused
/// with [RecursionLimitExceeded] *before* the executor is ever called.
final class RunProcedurePrimitive {
  /// Builds the primitive over an injected [executor].
  ///
  /// [hardDepthCap] is 10 in v1 (PE-3) and is exposed only for tests that
  /// want a smaller chain. [startDepth] is the depth of the top-level
  /// frame the engine invokes; it must be in `1..hardDepthCap`.
  RunProcedurePrimitive({
    required this.executor,
    this.hardDepthCap = defaultHardDepthCap,
    int startDepth = 1,
  }) : _currentDepth = startDepth {
    if (hardDepthCap < 1) {
      throw ArgumentError.value(
        hardDepthCap,
        'hardDepthCap',
        'must be >= 1',
      );
    }
    if (startDepth < 1 || startDepth > hardDepthCap) {
      throw ArgumentError.value(
        startDepth,
        'startDepth',
        'must be in 1..$hardDepthCap',
      );
    }
  }

  /// The hard recursion ceiling in v1 (`tom_brain_definition.md` § 7.3).
  static const int defaultHardDepthCap = 10;

  /// Resolves and runs each depth-validated [ProcedureCall].
  final ProcedureExecutor executor;

  /// The hard ceiling no `runProcedure` chain may exceed.
  final int hardDepthCap;

  int _currentDepth;

  /// The depth of the frame currently executing. Starts at the configured
  /// `startDepth`; rises while a nested `runProcedure` is in flight and
  /// falls back when it returns.
  int get currentDepth => _currentDepth;

  /// Invokes the procedure named [id] with [inputs].
  ///
  /// [version] optionally pins a specific version (the resolver picks the
  /// latest when omitted). [depthDelta] is how many depth levels this call
  /// consumes — 1 by default, and at least 1 (a call must advance the
  /// chain). The call targets depth `currentDepth + depthDelta`; if that
  /// exceeds [hardDepthCap] the call is refused with
  /// [RecursionLimitExceeded] and the [executor] is never invoked. While
  /// the executor runs, [currentDepth] reflects the child frame so a
  /// further nested `runProcedure` is measured from the right depth; it is
  /// always restored afterwards, even on failure.
  Future<ProcedureResult> runProcedure(
    String id,
    ProcedureInputs inputs, {
    int? version,
    int depthDelta = 1,
  }) async {
    if (depthDelta < 1) {
      throw ArgumentError.value(
        depthDelta,
        'depthDelta',
        'must be >= 1 — a runProcedure call must advance the chain',
      );
    }

    final childDepth = _currentDepth + depthDelta;
    if (childDepth > hardDepthCap) {
      throw RecursionLimitExceeded(
        attemptedDepth: childDepth,
        hardDepthCap: hardDepthCap,
        procedureId: id,
        version: version,
      );
    }

    final call = ProcedureCall(
      id: id,
      inputs: inputs,
      depth: childDepth,
      version: version,
    );

    final previousDepth = _currentDepth;
    _currentDepth = childDepth;
    try {
      return await executor(call);
    } finally {
      _currentDepth = previousDepth;
    }
  }
}
