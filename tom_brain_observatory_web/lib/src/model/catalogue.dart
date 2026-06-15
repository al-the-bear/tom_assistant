// Plan step 19 — the client model for `GET /api/catalogue` (§ 6.4, § 13.4): the
// registry-derived editable index the gear configuration editor browses. The
// `tom_brain_run` catalogue value types are transport-free, so the wire shape is
// owned by the observatory's `catalogue_read_api.dart`; this mirror parses it.
//
// Three families flow through: [CatalogueTemplate]s (prompt/fragment files,
// edited via `/api/templates`), [CatalogueRole]s (persona/objective prose, also
// `/api/templates`), and [CatalogueConfigFile]s (registry / procedure / llm /
// substrate, edited via `/api/config`).

/// One template file in the catalogue: its cognition-root-relative [path], the
/// [part] it plays (`system` / `user` / `fragment`), and whether it is [present]
/// on disk. An absent file (`present == false`) opens as an empty editable
/// document — the first save materialises it (§ 6.4).
class CatalogueTemplateFile {
  final String path;
  final String part;
  final bool present;

  const CatalogueTemplateFile({
    required this.path,
    required this.part,
    required this.present,
  });

  factory CatalogueTemplateFile.fromJson(Map<String, dynamic> json) =>
      CatalogueTemplateFile(
        path: json['path'] as String? ?? '',
        part: json['part'] as String? ?? '',
        present: json['present'] as bool? ?? false,
      );
}

/// One registered template, flattened: its full `<main>.<sub>.<prompt>` [id],
/// its [kind] (`prompt` or `fragment`), and its resolved [files] (a `system` +
/// `user` pair for a prompt, a single `fragment` for a fragment).
class CatalogueTemplate {
  final String id;
  final String kind;
  final List<CatalogueTemplateFile> files;

  const CatalogueTemplate({
    required this.id,
    required this.kind,
    required this.files,
  });

  factory CatalogueTemplate.fromJson(Map<String, dynamic> json) =>
      CatalogueTemplate(
        id: json['id'] as String? ?? '',
        kind: json['kind'] as String? ?? '',
        files: <CatalogueTemplateFile>[
          for (final f in (json['files'] as List<dynamic>? ?? const <dynamic>[]))
            CatalogueTemplateFile.fromJson(f as Map<String, dynamic>),
        ],
      );
}

/// A role's externalised prose files: the [name] and the persona/objective
/// paths. Edited via `/api/templates?id=<name>&part=persona|objective`.
class CatalogueRole {
  final String name;
  final String? personaPath;
  final String? objectivePath;

  const CatalogueRole({
    required this.name,
    this.personaPath,
    this.objectivePath,
  });

  factory CatalogueRole.fromJson(Map<String, dynamic> json) => CatalogueRole(
        name: json['name'] as String? ?? '',
        personaPath: json['personaPath'] as String?,
        objectivePath: json['objectivePath'] as String?,
      );
}

/// One config-file inventory entry: the registry, a per-procedure config, a
/// per-route llm config, or the `substrate:` block.
///
/// The catalogue enum names the per-route llm config `llm`, while the
/// `/api/config` wire alphabet names it `llm_route` — [configWireKind] is the
/// single frontend translation point (the backend mirror is `_kindFromWire`).
class CatalogueConfigFile {
  final String kind;
  final String name;
  final String path;
  final String? location;

  const CatalogueConfigFile({
    required this.kind,
    required this.name,
    required this.path,
    this.location,
  });

  factory CatalogueConfigFile.fromJson(Map<String, dynamic> json) =>
      CatalogueConfigFile(
        kind: json['kind'] as String? ?? '',
        name: json['name'] as String? ?? '',
        path: json['path'] as String? ?? '',
        location: json['location'] as String?,
      );

  /// The wire kind `/api/config` expects: catalogue `llm` → `llm_route`; every
  /// other kind passes through unchanged.
  String get configWireKind => kind == 'llm' ? 'llm_route' : kind;

  /// True for the registry index and the per-procedure yaml configs — the
  /// config files that belong on the gear editor's "Procedures" tab beside the
  /// procedure scripts.
  bool get isPromptConfig => kind == 'registry' || kind == 'procedure';
}

/// The whole catalogue: every editable template, role, and config file. Parsed
/// from `GET /api/catalogue`'s `{templates, roles, configFiles}` body.
class CognitionCatalogue {
  final List<CatalogueTemplate> templates;
  final List<CatalogueRole> roles;
  final List<CatalogueConfigFile> configFiles;

  const CognitionCatalogue({
    this.templates = const <CatalogueTemplate>[],
    this.roles = const <CatalogueRole>[],
    this.configFiles = const <CatalogueConfigFile>[],
  });

  factory CognitionCatalogue.fromJson(Map<String, dynamic> json) =>
      CognitionCatalogue(
        templates: <CatalogueTemplate>[
          for (final t
              in (json['templates'] as List<dynamic>? ?? const <dynamic>[]))
            CatalogueTemplate.fromJson(t as Map<String, dynamic>),
        ],
        roles: <CatalogueRole>[
          for (final r in (json['roles'] as List<dynamic>? ?? const <dynamic>[]))
            CatalogueRole.fromJson(r as Map<String, dynamic>),
        ],
        configFiles: <CatalogueConfigFile>[
          for (final f
              in (json['configFiles'] as List<dynamic>? ?? const <dynamic>[]))
            CatalogueConfigFile.fromJson(f as Map<String, dynamic>),
        ],
      );
}
