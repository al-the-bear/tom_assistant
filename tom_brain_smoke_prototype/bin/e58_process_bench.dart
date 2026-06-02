// Runnable process-level latency bench (E.58).
//
// Stands the smoke process up (stub substrate + isolate-hosted memory + OpenAI
// adapter), runs the inbound-prompt → first-SSE-chunk bench, prints the summary,
// optionally writes a Markdown report, and exits non-zero if the p95 target
// (≤ 250 ms) is missed — so a CI invocation fails loudly on a regression.
//
//   dart run bin/e58_process_bench.dart \
//       [--samples=60] [--warmup=5] [--output=ztmp/e58_bench_report.md]
//
// Per the workspace temp-file rule, the default report path is under ztmp/.

import 'dart:io';

import 'package:tom_brain_smoke_prototype/tom_brain_smoke_prototype.dart';

Future<void> main(List<String> args) async {
  final int samples = _intArg(args, '--samples', 60);
  final int warmup = _intArg(args, '--warmup', 5);
  final String? output = _strArg(args, '--output');

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

    if (!summary.meetsTarget()) {
      stderr.writeln('FAIL: p95 exceeds ${processBenchP95Target.inMilliseconds} ms');
      exitCode = 1;
    }
  } finally {
    await smoke.stop();
  }
}

int _intArg(List<String> args, String flag, int fallback) {
  final String? raw = _strArg(args, flag);
  if (raw == null) return fallback;
  return int.tryParse(raw) ?? fallback;
}

String? _strArg(List<String> args, String flag) {
  final String prefix = '$flag=';
  for (final String a in args) {
    if (a.startsWith(prefix)) return a.substring(prefix.length);
  }
  return null;
}
