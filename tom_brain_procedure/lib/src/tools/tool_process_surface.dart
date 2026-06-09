// ToolProcessSurface — the narrow, allow-listed process capability the
// `analyze.*` / `test.*` tools route through (`creation_specification.md`
// § 5.2, § 5.3, § 12.1 decision 2).
//
// The code-understanding and test tools (`analyze.dart`, `analyze.format`,
// `analyze.schema`, `test.run`, `test.baseline`) must run external processes
// (`dart analyze`, `dart format`, `testkit :test`, …). Letting the tool classes
// reach for `Process.run` directly would make them untestable and would smuggle
// a general-shell capability in through the back door — exactly what
// `creation_specification.md` § 5.4 forbids. Instead they call this method-only
// surface, which the engine binds over a real `Process.run`-backed
// implementation at wiring time. That implementation is bound to a **fixed
// allow-list of executables**, so holding a `ToolContext` grants no arbitrary
// command-execution capability (PE-1): each tool names exactly one fixed
// executable, and the surface refuses anything off the list with
// [ProcessExecutableNotAllowed].
//
// The surface returns a plain [ProcessRunResult] value (exit code + captured
// stdout/stderr) — a tool result is data, never a live handle. Tests inject a
// deterministic fake that records the calls and returns a canned result; no
// process is spawned in a unit test.

/// The captured outcome of a single allow-listed process run.
///
/// A value, not a handle: the surface runs the process to completion, captures
/// its streams as decoded strings, and hands back this immutable record. A tool
/// turns it into a JSON-serialisable map; nothing downstream can re-enter the
/// process.
final class ProcessRunResult {
  /// The process exit code (`0` conventionally meaning success).
  final int exitCode;

  /// The fully captured, decoded standard output.
  final String stdout;

  /// The fully captured, decoded standard error.
  final String stderr;

  /// Builds a result for a finished process run.
  const ProcessRunResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  /// Whether the run succeeded (exit code `0`).
  bool get ok => exitCode == 0;
}

/// The allow-listed process-running capability an `analyze.*` / `test.*`
/// `BrainTool` may use, and nothing past it (PE-1).
///
/// Method-only and result-as-data. An implementation runs [executable] with
/// [arguments] (optionally in [workingDirectory]), waits for completion, and
/// returns a [ProcessRunResult]. Implementations **must** enforce an
/// executable allow-list: a request for an executable outside the list raises
/// [ProcessExecutableNotAllowed] rather than spawning it — this is what keeps
/// "no general shell" (`creation_specification.md` § 5.4) a structural
/// guarantee, not a convention. Optional on a `ToolContext`: a run that exposes
/// no `analyze.*` / `test.*` tools carries none.
abstract interface class ToolProcessSurface {
  /// Runs [executable] with [arguments] (optionally in [workingDirectory]),
  /// returning the captured [ProcessRunResult].
  ///
  /// Raises [ProcessExecutableNotAllowed] when [executable] is not on the
  /// implementation's allow-list.
  Future<ProcessRunResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  });
}
