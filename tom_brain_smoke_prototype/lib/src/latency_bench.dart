// Process-level latency bench (E.58) — inbound-prompt → first-SSE-chunk.
//
// Plan step E.58 (verbatim): "Process-level bench: measure inbound-prompt →
// first-SSE-chunk latency p50/p95 with the stub substrate (isolate-hosted
// memory). Target: p95 ≤ 250 ms." (`prototype_implementation_plan.md` § E.11;
// access spec § "Process bench (E.58)".)
//
// ── What this module measures ────────────────────────────────────────
//
// One sample is the wall-clock from "the streaming `POST /v1/chat/completions`
// request bytes are on the wire" to "the first `data:` SSE frame arrives on the
// response stream". For the prototype's buffered SSE edge (E.48 / Q-E.48.1) the
// first frame arrives only once the whole answer is produced, so a sample is the
// full inbound-prompt → dispatcher → engine → procedure → memory → stub
// substrate → answer → SSE-replay round-trip — exactly the access-layer latency
// the plan asks to bench. The substrate is the in-process stub [SmokeSubstrate]
// and memory is the isolate-hosted [SmokeMemory], so the number reflects the
// framework's own overhead, not a real provider's token latency.
//
// ── Why the bench logic lives in `lib/`, not the test ────────────────
//
// The percentile maths and the report rendering are pure and deterministic;
// they are unit-tested in isolation (`e58_process_level_bench_test.dart`),
// separately from the timing-dependent end-to-end run. The measurement +
// orchestration helpers are shared between that test and the runnable
// `bin/e58_process_bench.dart`, so they belong in the library, not duplicated in
// two entry points.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tom_core_agentic/tom_core_agentic.dart' show LatencySummary;

import 'smoke_brain.dart' show SmokeProcess, smokeBearerToken;

/// The default prompt the bench drives. Stable text so every sample exercises
/// the same procedure path (and, after the first, the memory recall warm path).
const String defaultBenchPrompt = 'how do I automate backups?';

/// The plan's pass target: first-SSE-chunk p95 must not exceed this. The
/// generic [LatencySummary.meetsTarget] is target-agnostic; this is the
/// brain-specific figure the bench gates on.
const Duration processBenchP95Target = Duration(milliseconds: 250);

/// Measures one inbound-prompt → first-SSE-chunk latency sample.
///
/// Issues a streaming `POST /v1/chat/completions` for [prompt] against the smoke
/// process on [port], authenticated with [token]. The stopwatch starts the
/// instant the request bytes are queued and stops when the first `data:` SSE
/// frame arrives; the rest of the body is then drained so the keep-alive
/// connection on [client] can be reused by the next sample. Throws [StateError]
/// if the stream closes before any `data:` frame is seen.
Future<Duration> measureTimeToFirstSseFrame(
  HttpClient client,
  int port,
  String prompt, {
  required String token,
}) async {
  final HttpClientRequest request =
      await client.postUrl(Uri.parse('http://127.0.0.1:$port/v1/chat/completions'));
  request.headers.contentType =
      ContentType('application', 'json', charset: 'utf-8');
  request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  final List<int> body = utf8.encode(jsonEncode(_streamBody(prompt)));

  final Stopwatch stopwatch = Stopwatch()..start();
  request.add(body);
  final HttpClientResponse response = await request.close();

  // Decode the response line-by-line. A `LineSplitter` reassembles SSE lines
  // across decoder chunk boundaries (decoder chunks follow network reads, not
  // SSE lines), so a `data:` token split across two reads — `…da` | `ta: {…}` —
  // is still matched on the reassembled line. Scanning raw decoder chunks for
  // `contains('data:')` would miss that split and attribute the sample to a
  // later frame (inflating the very latency this bench measures) or throw the
  // "closed before any data: frame" error. SSE data frames begin a line with
  // `data:`, so a `startsWith` on the reassembled line is both correct and
  // tighter than a substring scan.
  Duration? firstFrame;
  final Stream<String> lines =
      response.transform(utf8.decoder).transform(const LineSplitter());
  await for (final String line in lines) {
    if (firstFrame == null && line.startsWith('data:')) {
      firstFrame = stopwatch.elapsed;
    }
    // Keep draining to completion so the connection returns to the pool; the
    // first-frame timestamp is already captured.
  }
  if (firstFrame == null) {
    throw StateError(
      'streaming response closed before any data: frame arrived',
    );
  }
  return firstFrame;
}

/// Runs the full process-level latency bench against a stood-up [smoke] process.
///
/// Issues [warmupSamples] discarded warm-up requests (to amortise first-call
/// costs: JIT, connection setup, the cold memory recall), then [sampleCount]
/// measured requests over a single keep-alive [HttpClient], and summarises the
/// measured samples. [prompt] defaults to [defaultBenchPrompt].
Future<LatencySummary> runProcessLatencyBench(
  SmokeProcess smoke, {
  int sampleCount = 60,
  int warmupSamples = 5,
  String prompt = defaultBenchPrompt,
}) async {
  if (sampleCount < 1) {
    throw ArgumentError.value(sampleCount, 'sampleCount', 'must be ≥ 1');
  }
  final HttpClient client = HttpClient();
  try {
    for (int i = 0; i < warmupSamples; i++) {
      await measureTimeToFirstSseFrame(
        client,
        smoke.port,
        prompt,
        token: smokeBearerToken,
      );
    }
    final List<Duration> samples = <Duration>[];
    for (int i = 0; i < sampleCount; i++) {
      samples.add(
        await measureTimeToFirstSseFrame(
          client,
          smoke.port,
          prompt,
          token: smokeBearerToken,
        ),
      );
    }
    return LatencySummary.fromSamples(samples);
  } finally {
    client.close(force: true);
  }
}

/// Renders a [summary] as a Markdown bench report.
///
/// Pure (no I/O): the runnable bench writes the returned string to disk and the
/// unit suite asserts its shape. [target] is the pass threshold quoted in the
/// report (default: the plan's [processBenchP95Target]); [warmupSamples] is
/// recorded for reproducibility.
String renderLatencyReport(
  LatencySummary summary, {
  Duration target = processBenchP95Target,
  int warmupSamples = 5,
  DateTime? generatedAt,
}) {
  final DateTime when = generatedAt ?? DateTime.now();
  final bool passed = summary.meetsTarget(target);
  final String verdict = passed ? 'PASS' : 'FAIL';
  String ms(Duration d) => (d.inMicroseconds / 1000).toStringAsFixed(2);

  final StringBuffer out = StringBuffer()
    ..writeln('# Phase E — Process-level latency bench (E.58)')
    ..writeln()
    ..writeln('**Metric:** inbound-prompt → first-SSE-chunk latency '
        '(streaming `POST /v1/chat/completions`).')
    ..writeln()
    ..writeln('**Substrate:** in-process stub `SmokeSubstrate`; '
        '**memory:** isolate-hosted `SmokeMemory`.')
    ..writeln()
    ..writeln('**Generated:** ${when.toUtc().toIso8601String()}')
    ..writeln()
    ..writeln('| Metric | Value |')
    ..writeln('| --- | --- |')
    ..writeln('| samples | ${summary.sampleCount} |')
    ..writeln('| warm-up (discarded) | $warmupSamples |')
    ..writeln('| min | ${ms(summary.min)} ms |')
    ..writeln('| p50 | ${ms(summary.p50)} ms |')
    ..writeln('| p95 | ${ms(summary.p95)} ms |')
    ..writeln('| max | ${ms(summary.max)} ms |')
    ..writeln('| target (p95 ≤) | ${ms(target)} ms |')
    ..writeln('| verdict | **$verdict** |')
    ..writeln()
    ..writeln(passed
        ? '✅ p95 (${ms(summary.p95)} ms) is within the '
            '${ms(target)} ms target.'
        : '❌ p95 (${ms(summary.p95)} ms) exceeds the '
            '${ms(target)} ms target.');
  return out.toString();
}

/// A `chat/completions` request body for [prompt] with `stream=true` — the
/// streaming surface the bench measures the first-frame latency of.
Map<String, Object?> _streamBody(String prompt) => <String, Object?>{
      'model': 'tom-brain',
      'messages': <Object?>[
        <String, Object?>{'role': 'user', 'content': prompt},
      ],
      'stream': true,
    };
