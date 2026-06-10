// ProcessRunToolSurface — the real, `Process.run`-backed [ToolProcessSurface]
// the engine binds over the `analyze.*` / `test.*` tools at wiring time
// (`creation_specification.md` § 5.2, § 5.3, § 5.4; completion-plan item 2).
//
// The `tool_process_surface.dart` doc promises that "the engine binds [the
// surface] over a real `Process.run`-backed implementation … bound to a fixed
// allow-list of executables". This is that implementation. It is the *only*
// place in the procedure package that reaches for `Process.run`: the
// code-understanding and test tools name an executable and hand it here, and
// this class — not the tool — runs it, after checking the executable against a
// fixed allow-list. Holding a `ToolContext` (and thus this surface) therefore
// grants no arbitrary command-execution capability: anything off the list is
// refused with [ProcessExecutableNotAllowed] before a process is spawned, so
// "no general shell" (§ 5.4) is a structural guarantee.
//
// The allow-list is exactly the executables the shipped process tools name:
//
//   - `dart`     — `analyze.dart` (`dart analyze`), `analyze.format`
//                  (`dart format --set-exit-if-changed`).
//   - `testkit`  — `test.run` (`testkit :test`), `test.baseline`
//                  (`testkit :baseline`).
//   - `tom`      — `analyze.schema` (`tom schema validate …`).
//
// A new process tool that needs a new executable widens this list *here*,
// reviewed against § 5.4 — never by opening a shell.

import 'dart:convert';
import 'dart:io';

import 'tool_failures.dart';
import 'tool_process_surface.dart';

/// The real [ToolProcessSurface]: runs an allow-listed executable to completion
/// via `Process.run` and returns the captured [ProcessRunResult].
///
/// Const-constructible so the engine can default to a shared instance. The
/// allow-list is fixed at the type level ([allowedExecutables]); a request for
/// anything outside it raises [ProcessExecutableNotAllowed] before any process
/// is spawned (PE-1). Streams are decoded with [systemEncoding] (the platform
/// console encoding) and captured whole — a tool result is data, never a live
/// handle.
final class ProcessRunToolSurface implements ToolProcessSurface {
  /// Builds the surface. `const` so the engine can hold a shared default.
  const ProcessRunToolSurface();

  /// The fixed set of executables this surface will spawn — exactly the ones
  /// the shipped `analyze.*` / `test.*` tools name (§ 5.2, § 5.3). Anything
  /// else is refused with [ProcessExecutableNotAllowed].
  static const Set<String> allowedExecutables = <String>{
    'dart',
    'testkit',
    'tom',
  };

  @override
  Future<ProcessRunResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    if (!allowedExecutables.contains(executable)) {
      throw ProcessExecutableNotAllowed(
        executable: executable,
        allowed: allowedExecutables,
      );
    }
    final result = await Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      stdoutEncoding: systemEncoding,
      stderrEncoding: systemEncoding,
      runInShell: false,
    );
    return ProcessRunResult(
      exitCode: result.exitCode,
      stdout: result.stdout is String
          ? result.stdout as String
          : utf8.decode(result.stdout as List<int>),
      stderr: result.stderr is String
          ? result.stderr as String
          : utf8.decode(result.stderr as List<int>),
    );
  }
}
