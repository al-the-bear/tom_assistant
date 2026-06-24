// tom_brain — the unified Tom Brain CLI (CLI plan step #8; `tom_brain_cli.md`
// § 5). One `tom_build_base` executable with subcommands `serve` (the default),
// `memory-mcp`, `observatory`, `init`, and `bundle`, with uniform
// `--help` / `--version` / error formatting.
//
// This replaces the hand-rolled `bin/brain_serve.dart` launcher: `tom_brain
// serve` boots the cognition and co-hosts the memory MCP server + the
// Observatory in one process (the old launcher's behaviour, now the default
// command). `run_tom_brain.sh` calls `tom_brain serve <config>`.
//
// The `tom_build_base` parser only routes `:`-prefixed tokens as commands, so
// [normalizeSubcommand] promotes a leading bare subcommand (`serve`, …) to its
// `:`-form before `ToolRunner.run`. The executors hold the *raw* (normalised)
// argv because the serve flag surface (repeatable / optional-value / `${env:…}`)
// is parsed by the assembler, not the parser (CLP-38).

import 'dart:io';

import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:tom_build_base/tom_build_base_v2.dart';

Future<void> main(List<String> args) async {
  final List<String> normalized = normalizeSubcommand(args);
  final runner = ToolRunner(
    tool: tomBrainTool,
    executors: createTomBrainExecutors(
      rawArgs: normalized,
      env: Platform.environment,
    ),
  );
  final ToolResult result = await runner.run(normalized);
  if (!result.success) {
    if (result.errorMessage != null) {
      stderr.writeln('tom_brain: ${result.errorMessage}');
    }
    exitCode = 1;
  }
}
