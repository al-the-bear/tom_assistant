// Executable entry point for the Tom Brain access prototype — the actual
// running process (Plan E.9).
//
// Built on `tom_build_base`'s `ToolDefinition` + `ToolRunner` per the
// workspace rule that all CLI tools share that framework (arg parsing,
// `--version`, `--help`, exit-code handling). The tool shape and the
// `serve` executor live in the library (`lib/src/api/`) so the same
// surface is exercised black-box by the tests; `main` only wires them.
//
// At E.9 the `serve` command is a not-yet-wired stub (boot lands at
// E.41–E.45). `--version` and `--help` are fully functional now.
import 'dart:io';

import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart';
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
