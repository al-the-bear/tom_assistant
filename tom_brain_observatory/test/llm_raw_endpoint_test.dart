// PT-2.4 (backend) — `GET /api/llm?turn=&path=` serves the verbatim raw LLM
// dump (§ 3.7) behind a run-tree LlmCall's `rawPath` link, so the front-end can
// render the full §4.5 detail (hashes, wire body, answer). Tests cover the
// happy path (the dump is returned verbatim), the containment guard (a link
// that escapes `<root>/llm/` is refused), the not-an-llm-dump refusal, the
// missing-dump 404, the bad-request when params are absent, and OBS-1 (no
// mutation).
//
// MSPP-55 (resolving the MSPP-54 deferral) — the same endpoint also accepts
// `run=<runId>` as the turn-less counterpart of `turn=<turnId>`, so a dream/
// free-time run's LLM-call wire body is fetchable through the *same* seam and
// guard. The `run=` group below mirrors the `turn=` cases against a turn-less
// dream-run fixture (`dream_extract_v1/run_1781400000000001_0`).

import 'dart:convert';
import 'dart:io';

import 'package:tom_brain_observatory/tom_brain_observatory.dart';
import 'package:test/test.dart';

import 'support/obs_harness.dart';

void main() {
  final api = TrailReadApi(host: TrailHost.at(fixtureHostPath));

  // The link a run-tree LlmCall carries (relative to procedures/<proc>/).
  const turnId = '260101-120000.000001';
  const goodLink = '../../llm/assistant_to_user/260101-120000.000001__02.raw.json';

  test('serves the verbatim §3.7 raw dump for a valid link', () async {
    final res = await obsGet(api, 'api/llm?turn=$turnId&path=${Uri.encodeQueryComponent(goodLink)}');
    expect(res.statusCode, 200);
    expect(res.headers['content-type'], contains('application/json'));
    final dump = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
    expect(dump['callType'], 'assistant_to_user');
    expect(dump['provider'], 'local');
    expect(dump['model'], 'fixture-model');
    expect(dump['anchorHash'], startsWith('sha256:'));
    expect(dump['promptHash'], startsWith('sha256:'));
    expect((dump['wire'] as Map)['messages'], isA<List<dynamic>>());
    expect(dump['answer'], isA<String>());
  });

  test('refuses a link that escapes the llm root (containment guard)', () async {
    const escape = '../../llm/../../../secret_outside_webroot.txt';
    final res = await obsGet(api, 'api/llm?turn=$turnId&path=${Uri.encodeQueryComponent(escape)}');
    expect(res.statusCode, HttpStatus.forbidden);
  });

  test('refuses a non-.raw.json link under llm/', () async {
    const notDump = '../../llm/assistant_to_user/notes.txt';
    final res = await obsGet(api, 'api/llm?turn=$turnId&path=${Uri.encodeQueryComponent(notDump)}');
    expect(res.statusCode, HttpStatus.forbidden);
  });

  test('404 when the dump does not exist', () async {
    const missing = '../../llm/assistant_to_user/does_not_exist.raw.json';
    final res = await obsGet(api, 'api/llm?turn=$turnId&path=${Uri.encodeQueryComponent(missing)}');
    expect(res.statusCode, HttpStatus.notFound);
  });

  test('400 when turn or path is missing', () async {
    expect((await obsGet(api, 'api/llm?turn=$turnId')).statusCode, HttpStatus.badRequest);
    expect((await obsGet(api, 'api/llm')).statusCode, HttpStatus.badRequest);
  });

  // MSPP-55 — the turn-less `run=` counterpart for dream/free-time runs. The
  // dream run `dream_extract_v1/run_1781400000000001_0` carries an LLM call
  // whose link resolves (relative to procedures/dream_extract_v1/) to
  // `llm/extractor/run_1781400000000001_0__01.raw.json`.
  group('run= (turn-less dream runs)', () {
    const runId = 'run_1781400000000001_0';
    const dreamLink = '../../llm/extractor/run_1781400000000001_0__01.raw.json';

    test('serves the verbatim §3.7 raw dump for a dream-run link', () async {
      final res = await obsGet(
          api, 'api/llm?run=$runId&path=${Uri.encodeQueryComponent(dreamLink)}');
      expect(res.statusCode, 200);
      expect(res.headers['content-type'], contains('application/json'));
      final dump = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(dump['callType'], 'extractor');
      expect(dump['runId'], runId);
      expect(dump['turnId'], isNull); // turn-less dream call (§ 3.6).
      expect(dump['provider'], 'local');
      expect((dump['wire'] as Map)['messages'], isA<List<dynamic>>());
      expect(dump['answer'], isA<String>());
    });

    test('refuses a dream link that escapes the llm root', () async {
      const escape = '../../llm/../../../secret_outside_webroot.txt';
      final res = await obsGet(
          api, 'api/llm?run=$runId&path=${Uri.encodeQueryComponent(escape)}');
      expect(res.statusCode, HttpStatus.forbidden);
    });

    test('refuses a non-.raw.json dream link under llm/', () async {
      const notDump = '../../llm/extractor/notes.txt';
      final res = await obsGet(
          api, 'api/llm?run=$runId&path=${Uri.encodeQueryComponent(notDump)}');
      expect(res.statusCode, HttpStatus.forbidden);
    });

    test('404 when the dream dump does not exist', () async {
      const missing = '../../llm/extractor/does_not_exist.raw.json';
      final res = await obsGet(
          api, 'api/llm?run=$runId&path=${Uri.encodeQueryComponent(missing)}');
      expect(res.statusCode, HttpStatus.notFound);
    });

    test('404 when the runId is unknown', () async {
      final res = await obsGet(api,
          'api/llm?run=run_does_not_exist_9&path=${Uri.encodeQueryComponent(dreamLink)}');
      expect(res.statusCode, HttpStatus.notFound);
    });

    test('404 when a turn-bound runId is passed as a dream run', () async {
      // A `<turnId>__<runId>` log is not a dream run (it has `__`); dreamRunLog
      // must not resolve it.
      final res = await obsGet(api,
          'api/llm?run=run_1781337010868413_2&path=${Uri.encodeQueryComponent(dreamLink)}');
      expect(res.statusCode, HttpStatus.notFound);
    });

    test('400 when both turn and run are supplied', () async {
      final res = await obsGet(api,
          'api/llm?turn=$turnId&run=$runId&path=${Uri.encodeQueryComponent(goodLink)}');
      expect(res.statusCode, HttpStatus.badRequest);
    });

    test('400 when run is given but path is missing', () async {
      expect((await obsGet(api, 'api/llm?run=$runId')).statusCode,
          HttpStatus.badRequest);
    });
  });

  // OBS-1 (no mutation) for this endpoint is proven in the comprehensive
  // read-only walk in `obs_conformance_test.dart` (Phase 8).
}
