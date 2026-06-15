// Plan step 14 — the `/api/catalogue` HTTP surface (`prompt_tracing.md` § 8.3,
// `prompt_configuration.md` § 13.4). It re-exposes the editable catalogue that
// `CognitionConfig.catalogue()` (plan step 13) derives — every registered
// template with its resolved file path(s) + present flags, the role prose files,
// and the config-file inventory — as the registry-derived index the gear
// configuration editor (§ 6.4, plan step 19) browses.
//
// Read-only: the route only reads the parsed [CognitionConfig]; it opens no
// file. The config itself is OPTIONAL, mirroring [MemoryReadApi]'s deferred
// connector — when no cognition config is wired (the observatory was launched
// without a `--cognition` root) the route answers `503 {"error": "config
// unavailable"}` so the UI degrades cleanly, never a 404.
//
// The `tom_brain_run` catalogue value types are pure data with no `toJson`
// (they stay transport-free, owned by the cognition package), so the wire shape
// is owned here — the one place that knows it is an HTTP response.

import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:tom_brain_run/tom_brain_run.dart'
    show
        CatalogueConfigFile,
        CatalogueRole,
        CatalogueTemplate,
        CatalogueTemplateFile,
        CognitionCatalogue,
        CognitionConfig;

/// Registers `GET /api/catalogue` over an optional [CognitionConfig].
final class CatalogueReadApi {
  /// The parsed cognition config the catalogue is derived from, or `null` when
  /// no cognition root was configured (the route then answers `503` "config
  /// unavailable" — the routes always exist, so the UI gets a clean signal).
  final CognitionConfig? config;

  /// The run-config file the substrate-block inventory entry points at,
  /// forwarded to [CognitionConfig.catalogue] (default `brain_run.yaml`).
  final String substrateConfigFile;

  /// Binds the catalogue route over an optional [config].
  const CatalogueReadApi({
    this.config,
    this.substrateConfigFile = 'brain_run.yaml',
  });

  /// Adds the catalogue route to [router] (the full `/api/catalogue` path, so
  /// the host router matches it alongside the trail routes without a mount).
  void registerRoutes(Router router) {
    router.get('/api/catalogue', _catalogue);
  }

  /// `GET /api/catalogue` — the registry-derived editable index (§ 13.4). `503`
  /// "config unavailable" when no cognition config is wired.
  Response _catalogue(Request request) {
    final c = config;
    if (c == null) {
      return _json(
        <String, Object?>{'error': 'config unavailable'},
        status: 503,
      );
    }
    return _json(_catalogueJson(c.catalogue(
      substrateConfigFile: substrateConfigFile,
    )));
  }

  /// The wire shape of a [CognitionCatalogue] (owned here — the transport edge —
  /// since the `tom_brain_run` catalogue types stay `toJson`-free pure data).
  static Map<String, Object?> _catalogueJson(CognitionCatalogue catalogue) =>
      <String, Object?>{
        'templates': <Object?>[
          for (final t in catalogue.templates) _templateJson(t),
        ],
        'roles': <Object?>[
          for (final r in catalogue.roles) _roleJson(r),
        ],
        'configFiles': <Object?>[
          for (final f in catalogue.configFiles) _configFileJson(f),
        ],
      };

  static Map<String, Object?> _templateJson(CatalogueTemplate t) =>
      <String, Object?>{
        'id': t.id,
        'kind': t.kind.name,
        'files': <Object?>[
          for (final f in t.files) _templateFileJson(f),
        ],
      };

  static Map<String, Object?> _templateFileJson(CatalogueTemplateFile f) =>
      <String, Object?>{
        'path': f.path,
        'part': f.part.name,
        'present': f.present,
      };

  static Map<String, Object?> _roleJson(CatalogueRole r) => <String, Object?>{
        'name': r.name,
        'personaPath': r.personaPath,
        'objectivePath': r.objectivePath,
      };

  static Map<String, Object?> _configFileJson(CatalogueConfigFile f) =>
      <String, Object?>{
        'kind': f.kind.name,
        'name': f.name,
        'path': f.path,
        'location': f.location,
      };

  Response _json(Object? body, {int status = 200}) => Response(
        status,
        body: jsonEncode(body),
        headers: const <String, String>{
          'content-type': 'application/json; charset=utf-8',
        },
      );
}
