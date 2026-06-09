// Executable entry point for the Tom Brain access prototype — the actual
// running process (Plan E.9).
//
// Built on `tom_build_base`'s `ToolDefinition` + `ToolRunner` per the
// workspace rule that all CLI tools share that framework (arg parsing,
// `--version`, `--help`, exit-code handling). The tool shape and the
// `serve` executor live in the library (`lib/src/api/`) so the same
// surface is exercised black-box by the tests; `main` only wires them.
//
// The `serve` command is wired (E.41–E.45): it loads the config, provisions
// the cognition through the injected `BrainProvisioner`, and serves the
// OpenAI + Telegram + `/healthz` surface until a termination signal drives the
// graceful teardown. The standalone binary uses the default
// `unsupportedBrainProvisioner` (it may not import substrate / memory), so a
// bare `serve` reports the boundary and exits cleanly; a higher assembly that
// can boot the cognition injects a real provisioner.
import 'dart:io';

import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:tom_build_base/tom_build_base_v2.dart';

Future<void> main(List<String> args) async {
  final runner = ToolRunner(
    tool: accessPrototypeTool,
    executors: createAccessPrototypeExecutors(),
  );

  final result = await runner.run(args);

  if (!result.success) {
    exitCode = 1;
  }
}
