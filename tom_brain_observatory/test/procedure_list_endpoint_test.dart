// `GET /api/procedures` lists the procedure-script ids the running brain hosts
// under `scripts/system/*.dart` (§ 4.6, § 8.3(5)), so the gear configuration
// editor's Procedures tab can offer each script for inspection/authoring beside
// its yaml config — the same scripts the Run Tree opens by id. Tests cover the
// happy path (only `.dart` stems, sorted), the unconfigured-root case (an empty
// list, never an error), and read-only behaviour (it returns names, mutates
// nothing).

import 'dart:convert';
import 'dart:io';

import 'package:tom_brain_observatory/tom_brain_observatory.dart';
import 'package:test/test.dart';

import 'support/obs_harness.dart';

void main() {
  test('lists the .dart script stems, sorted, ignoring non-dart files',
      () async {
    final root = Directory.systemTemp.createTempSync('obs_proc_list_');
    addTearDown(() => root.deleteSync(recursive: true));
    File('${root.path}/recall_hyde_v1.dart').writeAsStringSync('// x\n');
    File('${root.path}/answer_with_memory_v1.dart').writeAsStringSync('// y\n');
    File('${root.path}/notes.md').writeAsStringSync('not a script\n');

    final api = TrailReadApi(
      host: TrailHost.at(fixtureHostPath),
      scriptRoot: root,
    );

    final res = await obsGet(api, 'api/procedures');
    expect(res.statusCode, 200);
    final body = jsonDecode(await res.readAsString()) as List<dynamic>;
    expect(body, <String>['answer_with_memory_v1', 'recall_hyde_v1']);
  });

  test('returns an empty list when the script root is unconfigured', () async {
    final api = TrailReadApi(host: TrailHost.at(fixtureHostPath));
    final res = await obsGet(api, 'api/procedures');
    expect(res.statusCode, 200);
    expect(jsonDecode(await res.readAsString()), isEmpty);
  });
}
