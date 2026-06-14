// Slice 3 — the source-authoring surface (`prompt_tracing.md` § 6.3, § 8.3(8),
// AUTH-1…AUTH-5): `PUT /api/procedures/<id>` writes a procedure script back to
// `scripts/system/<id>.dart` so an operator can edit what the running brain
// re-reads on its next run (AUTH-5; the brain's resolver pickup is proven in
// `tom_brain_procedure`'s `procedure_resolver_handle_test.dart`).
//
// What this proves, the AUTH guards in order:
//   - AUTH-1/AUTH-2 (containment): a valid body lands in the script root; an id
//     that escapes the root via path segments is refused (403) before any write.
//   - AUTH-3 (validate-before-write): a body whose `/// @procedure` header is
//     malformed — or that reaches outside the bridged surface — is rejected
//     (422) and the on-disk file is left byte-for-byte untouched. The gate is
//     the brain's own `ProcedureValidationChain` (header + sandbox + contract),
//     so the observatory can never accept a script the brain would reject.
//   - The unconfigured-script-root write is a clean 404 (absence is never an
//     error, § 4.1), mirroring the read endpoint.
//
// Writes always target a fresh temp dir — never the committed fixture script
// root, which the read-only conformance walk snapshots for OBS-1.

import 'dart:io';

import 'package:tom_brain_observatory/tom_brain_observatory.dart';
import 'package:test/test.dart';

import 'support/obs_harness.dart';

/// A minimal procedure that passes every validator layer — header complete, the
/// strict `Future<ProcedureResult> run(ProcedureInputs)` entry-point signature,
/// only allow-listed engine-native imports, and a `requires` set that matches
/// the one primitive it calls. Shaped exactly like the shipped `critique_v1`
/// stub, so it clears the same gate the live engine applies at load.
const String _validProcedure = '''
/// @procedure
/// id: editable_v1
/// version: 1
/// summary: A minimal valid fixture procedure for the write-endpoint test.
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
  late Directory scriptRoot;
  late File seeded;

  setUp(() {
    scriptRoot = Directory.systemTemp.createTempSync('obs_write_scripts_');
    seeded = File('${scriptRoot.path}/editable_v1.dart')
      ..writeAsStringSync('/// stale\n');
  });

  tearDown(() {
    if (scriptRoot.existsSync()) scriptRoot.deleteSync(recursive: true);
  });

  TrailReadApi apiOver(Directory root) => TrailReadApi(
        host: TrailHost.at(fixtureHostPath),
        scriptRoot: root,
      );

  test('writes a valid procedure body and returns 200', () async {
    final res = await obsPut(
      apiOver(scriptRoot),
      'api/procedures/editable_v1',
      body: _validProcedure,
    );
    expect(res.statusCode, 200);
    expect(seeded.readAsStringSync(), _validProcedure);
  });

  test('refuses a path-traversal id before any write (403)', () async {
    final before = seeded.readAsStringSync();
    final res = await obsPut(
      apiOver(scriptRoot),
      'api/procedures/${Uri.encodeComponent('../../escape')}',
      body: _validProcedure,
    );
    expect(res.statusCode, anyOf(HttpStatus.forbidden, HttpStatus.notFound));
    expect(seeded.readAsStringSync(), before);
  });

  test('rejects a malformed header (422) and leaves the file untouched',
      () async {
    final before = seeded.readAsStringSync();
    final res = await obsPut(
      apiOver(scriptRoot),
      'api/procedures/editable_v1',
      body: 'Object? run(Object? inputs) => null;\n', // no @procedure header
    );
    expect(res.statusCode, HttpStatus.unprocessableEntity);
    expect(seeded.readAsStringSync(), before);
    final body = await res.readAsString();
    expect(body, contains('procedure.header.invalid'));
  });

  test('rejects a sandbox-violating body (422) and leaves the file untouched',
      () async {
    final before = seeded.readAsStringSync();
    final res = await obsPut(
      apiOver(scriptRoot),
      'api/procedures/editable_v1',
      body: '''
/// @procedure
/// id: editable_v1
/// version: 1
/// summary: reaches outside the bridged surface.
/// successCriterion: never, it is rejected.
/// budget: { wallClockMs: 1000 }
/// requires: []
Object? run(Object? inputs) => File('/etc/passwd').readAsStringSync();
''',
    );
    expect(res.statusCode, HttpStatus.unprocessableEntity);
    expect(seeded.readAsStringSync(), before);
    final body = await res.readAsString();
    expect(body, contains('procedure.sandbox.violation'));
  });

  test('404 when the script root is unconfigured', () async {
    final unconfigured = TrailReadApi(host: TrailHost.at(fixtureHostPath));
    final res = await obsPut(
      unconfigured,
      'api/procedures/editable_v1',
      body: _validProcedure,
    );
    expect(res.statusCode, HttpStatus.notFound);
  });
}
