// Plan step 19 (model) — the `/api/catalogue` body parses into a
// [CognitionCatalogue], and the catalogue `llm` kind translates to the
// `/api/config` wire kind `llm_route` (the single frontend translation point,
// mirroring the host's `_kindFromWire`).

import 'package:flutter_test/flutter_test.dart';
import 'package:tom_brain_observatory_web/src/model/catalogue.dart';

void main() {
  test('parses the templates / roles / configFiles body', () {
    final catalogue = CognitionCatalogue.fromJson(<String, dynamic>{
      'templates': <Object?>[
        <String, Object?>{
          'id': 'answer.user.system',
          'kind': 'prompt',
          'files': <Object?>[
            <String, Object?>{
              'path': 'answer/user.system.md',
              'part': 'system',
              'present': true,
            },
            <String, Object?>{
              'path': 'answer/user.user.md',
              'part': 'user',
              'present': false,
            },
          ],
        },
      ],
      'roles': <Object?>[
        <String, Object?>{
          'name': 'analyser',
          'personaPath': 'roles/analyser.persona.md',
          'objectivePath': 'roles/analyser.objective.md',
        },
      ],
      'configFiles': <Object?>[
        <String, Object?>{
          'kind': 'registry',
          'name': 'registry',
          'path': 'registry.yaml',
          'location': null,
        },
        <String, Object?>{
          'kind': 'llm',
          'name': 'default',
          'path': 'llm/default.yaml',
          'location': null,
        },
        <String, Object?>{
          'kind': 'substrate',
          'name': 'substrate',
          'path': 'brain_run.yaml',
          'location': 'substrate',
        },
      ],
    });

    expect(catalogue.templates.single.id, 'answer.user.system');
    expect(catalogue.templates.single.files, hasLength(2));
    expect(catalogue.templates.single.files.last.present, isFalse);
    expect(catalogue.roles.single.name, 'analyser');
    expect(catalogue.configFiles, hasLength(3));
  });

  test('translates the catalogue `llm` kind to the wire `llm_route`', () {
    const llm = CatalogueConfigFile(
        kind: 'llm', name: 'default', path: 'llm/default.yaml');
    const substrate = CatalogueConfigFile(
        kind: 'substrate', name: 'substrate', path: 'brain_run.yaml');
    const registry = CatalogueConfigFile(
        kind: 'registry', name: 'registry', path: 'registry.yaml');

    expect(llm.configWireKind, 'llm_route');
    expect(substrate.configWireKind, 'substrate');
    expect(registry.configWireKind, 'registry');
    expect(registry.isPromptConfig, isTrue);
    expect(substrate.isPromptConfig, isFalse);
  });
}
