// Plan step 9 — read-only-config plumbing
// (`tom_brain_cli_plan.md` step 9; `prompt_tracing.md` § 6.3 authoring guards).
//
// The Observatory's three authoring PUTs (procedure script, template, config)
// are gated by a single `configWritable` switch. Most operators run the
// in-process observatory against a *running* brain, where editing config is the
// point. But when the brain serves a fixed cognition (e.g. a shared deployment
// the operator must not retune from the browser), `--observatory-readonly`
// forces `configWritable=false`, and every PUT short-circuits `409
// config_is_immutable` *before* the existing AUTH guards — the authoring surface
// is closed, not merely validated stricter.
//
// What this proves:
//   - a read-write api (`configWritable: true`, the default) lets all three PUTs
//     reach their normal path (a valid body → 200);
//   - a read-only api (`configWritable: false`) returns `409 config_is_immutable`
//     on each of the three PUTs, and writes nothing;
//   - `ObservatoryOptions.fromArgs([..., '--observatory-readonly'])` parses to
//     `configWritable=false` (the flag override), default `true` otherwise;
//   - `GET /api/meta` reports `configWritable` so the editor UI can grey its
//     controls without guessing from a 409.

import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart' show Response;
import 'package:tom_brain_observatory/tom_brain_observatory.dart';
import 'package:tom_brain_config/tom_brain_config.dart';
import 'package:test/test.dart';

import 'support/obs_harness.dart';

/// A minimal procedure that passes every validator layer (header + sandbox +
/// contract) — copied from `procedure_write_endpoint_test.dart` so the
/// read-write PUT lands cleanly (200), isolating the configWritable gate from
/// any validation 422.
const String _validProcedure = '''
/// @procedure
/// id: editable_v1
/// version: 1
/// summary: A minimal valid fixture procedure for the config-writable test.
/// successCriterion: throws ProcedureNotImplemented; it validates but never runs.
/// budget: { wallClockMs: 1000 }
/// requires: [ notImplemented ]
import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure/src/api/procedure_result.dart';
import 'package:tom_brain_procedure/src/primitives_native/primitives_native.dart';

Future<ProcedureResult> run(ProcedureInputs inputs) async =>
    notImplemented('editable');
''';

void main() {
  late Directory cognitionDir;
  late Directory scriptDir;
  late CognitionConfig cognition;

  setUp(() {
    cognitionDir = Directory.systemTemp.createTempSync('obs_rw_cog_');
    writeMinimalCognitionTree(cognitionDir);
    cognition = CognitionConfigLoader.loadFromDir(cognitionDir.path);

    // A fresh temp script root seeded with a stale file, so the read-write PUT
    // can land a valid body without mutating the committed fixture tree.
    scriptDir = Directory.systemTemp.createTempSync('obs_rw_scripts_');
    File('${scriptDir.path}/editable_v1.dart').writeAsStringSync('/// stale\n');
  });

  tearDown(() {
    if (cognitionDir.existsSync()) cognitionDir.deleteSync(recursive: true);
    if (scriptDir.existsSync()) scriptDir.deleteSync(recursive: true);
  });

  TrailReadApi apiWith({required bool configWritable}) => TrailReadApi(
        host: TrailHost.at(fixtureHostPath),
        scriptRoot: scriptDir,
        cognition: cognition,
        cognitionRoot: cognitionDir,
        configWritable: configWritable,
      );

  // The three authoring PUTs, each driven with a body that is valid on the
  // read-write path (so a non-409 outcome is a clean 200, never a validator
  // 422 confounding the read-only check).
  Future<Response> putProcedure(TrailReadApi api) => obsPut(
        api,
        'api/procedures/editable_v1',
        body: _validProcedure,
      );
  Future<Response> putTemplate(TrailReadApi api) => obsPut(
        api,
        'api/templates?id=assist_user.answer_with_memory.assembly&part=system',
        body: 'system framing\n',
      );
  Future<Response> putConfig(TrailReadApi api) => obsPut(
        api,
        'api/config?kind=procedure&name=assist_user',
        body: File('${cognitionDir.path}/assist_user.yaml').readAsStringSync(),
      );

  group('configWritable: true — the three PUTs reach their normal path', () {
    test('PUT /api/procedures/<id> writes (200)', () async {
      final res = await putProcedure(apiWith(configWritable: true));
      expect(res.statusCode, 200);
    });

    test('PUT /api/templates writes (200)', () async {
      final res = await putTemplate(apiWith(configWritable: true));
      expect(res.statusCode, 200);
    });

    test('PUT /api/config writes (200)', () async {
      final res = await putConfig(apiWith(configWritable: true));
      expect(res.statusCode, 200);
    });
  });

  group('configWritable: false — every PUT is 409 config_is_immutable', () {
    Future<void> expectImmutable(Response res) async {
      expect(res.statusCode, HttpStatus.conflict);
      final body = (jsonDecode(await res.readAsString()) as Map)
          .cast<String, Object?>();
      expect(body['error'], 'config_is_immutable');
    }

    test('PUT /api/procedures/<id> is 409', () async {
      await expectImmutable(await putProcedure(apiWith(configWritable: false)));
    });

    test('PUT /api/templates is 409', () async {
      await expectImmutable(await putTemplate(apiWith(configWritable: false)));
    });

    test('PUT /api/config is 409', () async {
      await expectImmutable(await putConfig(apiWith(configWritable: false)));
    });

    test('the read-only refusal writes nothing', () async {
      final before = FsSnapshot.capture(cognitionDir.path);
      await putTemplate(apiWith(configWritable: false));
      await putConfig(apiWith(configWritable: false));
      final after = FsSnapshot.capture(cognitionDir.path);
      expect(before.diff(after), isEmpty);
    });
  });

  group('GET /api/meta reports configWritable', () {
    Future<bool> metaConfigWritable(TrailReadApi api) async {
      final res = await obsGet(api, 'api/meta');
      expect(res.statusCode, 200);
      final body = (jsonDecode(await res.readAsString()) as Map)
          .cast<String, Object?>();
      return body['configWritable'] as bool;
    }

    test('true on a read-write api', () async {
      expect(await metaConfigWritable(apiWith(configWritable: true)), isTrue);
    });

    test('false on a read-only api', () async {
      expect(await metaConfigWritable(apiWith(configWritable: false)), isFalse);
    });
  });

  group('ObservatoryOptions — --observatory-readonly flag override', () {
    test('defaults to configWritable=true', () {
      final options = ObservatoryOptions.fromArgs(<String>['some/trail/root']);
      expect(options.configWritable, isTrue);
    });

    test('--observatory-readonly forces configWritable=false', () {
      final options = ObservatoryOptions.fromArgs(
          <String>['some/trail/root', '--observatory-readonly']);
      expect(options.configWritable, isFalse);
    });
  });
}
