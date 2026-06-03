// The `tom_build_base` tool definition + executor for the E.58 process bench.
//
// The bench is a CLI entry point, so per the workspace rule (`CLAUDE.md`,
// `tool_dependencies.md`) its arg parsing — `--samples` / `--warmup` /
// `--output`, plus `--version` / `--help` — is built on `tom_build_base`'s
// shared parser, never hand-rolled. This file declares the tool shape and the
// run logic; `bin/e58_process_bench.dart` only wires it to a `ToolRunner`.
//
// The single command (`bench`) is declared non-traversal (a bench runs once in
// the current process, it does not traverse projects), so the `ToolRunner`
// dispatches it to [CommandExecutor.executeWithoutTraversal]. [execute] is part
// of the contract but unreachable for a non-traversal command; it delegates to
// the same routine so the two paths cannot drift.

import 'dart:io';

import 'package:tom_build_base/tom_build_base_v2.dart';
import 'package:tom_core_agentic/tom_core_agentic.dart' show LatencySummary;

import 'latency_bench.dart';
import 'smoke_brain.dart';

/// Semantic version of the bench tool. Kept in lockstep with `pubspec.yaml`'s
/// `version:` field by hand.
const String e58BenchVersion = '0.0.1';

/// Full `--version` banner for the bench.
const String e58BenchVersionString =
    'Tom Brain E.58 process-level latency bench v$e58BenchVersion';

/// Name of the default (and only) command — the bench run.
const String e58BenchCommandName = 'bench';

/// Name of the `--samples` option (measured samples).
const String benchSamplesOptionName = 'samples';

/// Name of the `--warmup` option (discarded warm-up samples).
const String benchWarmupOptionName = 'warmup';

/// Name of the `--output` option (Markdown report path).
const String benchOutputOptionName = 'output';

/// Default measured-sample count when `--samples` is absent.
const int defaultBenchSampleCount = 60;

/// Default warm-up-sample count when `--warmup` is absent.
const int defaultBenchWarmupSamples = 5;

/// The `--samples` option — the number of measured round-trips.
const OptionDefinition benchSamplesOption = OptionDefinition.option(
  name: benchSamplesOptionName,
  abbr: 's',
  description:
      'Number of measured samples (default $defaultBenchSampleCount).',
  valueName: 'count',
);

/// The `--warmup` option — the number of discarded warm-up round-trips.
const OptionDefinition benchWarmupOption = OptionDefinition.option(
  name: benchWarmupOptionName,
  abbr: 'w',
  description:
      'Number of warm-up samples to discard (default $defaultBenchWarmupSamples).',
  valueName: 'count',
);

/// The `--output` option — where to write the Markdown report (under `ztmp/`).
const OptionDefinition benchOutputOption = OptionDefinition.option(
  name: benchOutputOptionName,
  abbr: 'o',
  description: 'Optional path to write the Markdown report (e.g. '
      'ztmp/e58_bench_report.md).',
  valueName: 'path',
);

/// The `bench` command — a single non-traversal run.
const CommandDefinition e58BenchCommand = CommandDefinition(
  name: e58BenchCommandName,
  description:
      'Run the process-level inbound-prompt → first-SSE-chunk latency bench '
      'against a stood-up smoke process and assert the p95 target.',
  requiresTraversal: false,
  supportsProjectTraversal: false,
  examples: [
    'e58_process_bench --samples=60 --warmup=5',
    'e58_process_bench --output=ztmp/e58_bench_report.md',
  ],
);

/// The E.58 bench tool definition.
final ToolDefinition e58BenchTool = ToolDefinition(
  name: 'e58_process_bench',
  description:
      'Tom Brain E.58 process-level latency bench — measures inbound-prompt → '
      'first-SSE-chunk latency p50/p95 against the plan target with the stub '
      'substrate + isolate-hosted memory.',
  version: e58BenchVersion,
  versionString: e58BenchVersionString,
  mode: ToolMode.multiCommand,
  defaultCommand: e58BenchCommandName,
  globalOptions: const [
    benchSamplesOption,
    benchWarmupOption,
    benchOutputOption,
  ],
  commands: const [e58BenchCommand],
  helpFooter: '''
Running the bench:
  e58_process_bench                              # 60 samples, 5 warm-up
  e58_process_bench --samples=40 --warmup=5
  e58_process_bench --output=ztmp/e58_report.md  # also write a Markdown report

Exits non-zero when the measured p95 exceeds the plan target (≤ 250 ms), so a
CI invocation fails loudly on a regression.''',
);

/// Executor for the `bench` command (E.58).
///
/// Stands the smoke process up (stub substrate + isolate-hosted memory + OpenAI
/// adapter), runs the inbound-prompt → first-SSE-chunk bench, prints the
/// summary, optionally writes a Markdown report, and fails when the p95 target
/// is missed.
class E58BenchExecutor extends CommandExecutor {
  @override
  Future<ToolResult> executeWithoutTraversal(CliArgs args) => _runBench(args);

  // Unreachable for a non-traversal command, but the contract requires it.
  @override
  Future<ItemResult> execute(CommandContext context, CliArgs args) async {
    final ToolResult result = await _runBench(args);
    return result.success
        ? ItemResult.success(
            path: context.path,
            name: context.name,
            message: 'bench met the p95 target',
          )
        : ItemResult.failure(
            path: context.path,
            name: context.name,
            error: result.errorMessage ?? 'bench failed',
          );
  }

  /// Stands the process up, runs the bench, and reports pass / fail.
  Future<ToolResult> _runBench(CliArgs args) async {
    final int samples =
        _intOption(args, benchSamplesOptionName, defaultBenchSampleCount);
    final int warmup =
        _intOption(args, benchWarmupOptionName, defaultBenchWarmupSamples);
    final String? output = args.extraOptions[benchOutputOptionName] as String?;

    final SmokeProcess smoke = await standUpSmokeProcess();
    try {
      final LatencySummary summary = await runProcessLatencyBench(
        smoke,
        sampleCount: samples,
        warmupSamples: warmup,
      );

      final String report = renderLatencyReport(summary, warmupSamples: warmup);
      stdout.writeln(report);

      if (output != null) {
        final File file = File(output);
        await file.parent.create(recursive: true);
        await file.writeAsString(report);
        stdout.writeln('Wrote $output');
      }

      if (!summary.meetsTarget(processBenchP95Target)) {
        return ToolResult.failure(
          'p95 exceeds ${processBenchP95Target.inMilliseconds} ms',
        );
      }
      return const ToolResult.success(processedCount: 1);
    } finally {
      await smoke.stop();
    }
  }

  /// Reads an int-valued option from [CliArgs.extraOptions] (a value option
  /// surfaces as a `String`, a bare flag as `true`), falling back when absent
  /// or unparseable.
  static int _intOption(CliArgs args, String name, int fallback) {
    final Object? raw = args.extraOptions[name];
    if (raw is int) return raw;
    if (raw is String) return int.tryParse(raw) ?? fallback;
    return fallback;
  }
}

/// Builds the executor map the `ToolRunner` dispatches against (keyed by command
/// name); the bare invocation routes here via the tool's `defaultCommand`.
Map<String, CommandExecutor> createE58BenchExecutors() =>
    <String, CommandExecutor>{e58BenchCommandName: E58BenchExecutor()};
