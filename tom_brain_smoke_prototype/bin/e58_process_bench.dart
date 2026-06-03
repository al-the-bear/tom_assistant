// Runnable process-level latency bench (E.58).
//
// Built on `tom_build_base`'s `ToolDefinition` + `ToolRunner` per the workspace
// rule that all CLI tools share that framework (arg parsing, `--version`,
// `--help`, exit-code handling). The tool shape and the bench executor live in
// the library (`lib/src/bench_tool.dart`) so the same surface is exercised by
// the tests; `main` only wires them.
//
//   dart run bin/e58_process_bench.dart \
//       [--samples=60] [--warmup=5] [--output=ztmp/e58_bench_report.md]
//
// Per the workspace temp-file rule, any report path should be under ztmp/. The
// run exits non-zero when the measured p95 misses the target (≤ 250 ms), so a
// CI invocation fails loudly on a regression.

import 'dart:io';

import 'package:tom_brain_smoke_prototype/tom_brain_smoke_prototype.dart';
import 'package:tom_build_base/tom_build_base_v2.dart';

Future<void> main(List<String> args) async {
  final runner = ToolRunner(
    tool: e58BenchTool,
    executors: createE58BenchExecutors(),
  );

  final result = await runner.run(args);

  if (!result.success) {
    exitCode = 1;
  }
}
