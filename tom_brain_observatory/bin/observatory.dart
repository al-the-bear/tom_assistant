// The Tom Brain Observatory backend — one process serving the read-only Trail
// Read API under `/api` and the embedded Flutter-web build under `/`, from a
// single loopback origin (`prompt_tracing.md` § 8.5, § 7.1; plan PT-2.0). This
// is the "launch the backend, open the loopback URL" entrypoint: it binds
// 127.0.0.1 by default so the observatory is never exposed off-host.
//
// Usage:
//   dart run bin/observatory.dart <trail-host-root> [--web=<dir>] [--scripts=<dir>] [--prompts=<dir>] [--cognition=<dir>] [--port=N] [--host=ADDR]
//
//   <trail-host-root>   the trail tree to read, e.g. _ai/tom_brain_trail/<host>
//   --web=<dir>         the `flutter build web` output to serve at `/`
//                       (default: ../tom_brain_observatory_web/build/web)
//   --scripts=<dir>     the running brain's procedure scripts served read-only
//                       by GET /api/procedures/<id> (§ 4.6; default:
//                       ../tom_brain_procedure/scripts/system) and written by
//                       PUT /api/procedures/<id> under the authoring guards
//                       (§ 6.3, AUTH-1…AUTH-3)
//   --prompts=<dir>     the running brain's externalized prompt files
//                       (<roleId>.persona.md / <roleId>.objective.md, the
//                       cognition's roles folder), read+written by
//                       GET/PUT /api/prompts/<roleId>/<part> under the same
//                       guards (§ 6.3); no default — the prompt endpoints 404
//                       until it points at the brain's roles folder
//   --cognition=<dir>   the running brain's cognition root (registry.yaml +
//                       per-procedure configs + templates), served read-only by
//                       GET /api/catalogue (§ 8.3, step 14); no default — the
//                       catalogue route 503s "config unavailable" until it
//                       points at the brain's cognition root
//   --port=N            loopback port (default 8787)
//   --host=ADDR         bind address (default 127.0.0.1; loopback-only by design)
//
// Read-only is load-bearing (OBS-1..OBS-5): this process never opens a trail
// file, the memory store, or any brain control surface for writing.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:tom_brain_observatory/tom_brain_observatory.dart';
import 'package:tom_brain_run/tom_brain_run.dart'
    show CognitionConfig, CognitionConfigException, CognitionConfigLoader;

const _defaultPort = 8787;
const _defaultHost = '127.0.0.1';

Future<void> main(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('-')).toList();
  if (positional.length != 1) {
    stderr.writeln(
      'usage: dart run bin/observatory.dart <trail-host-root> '
      '[--web=<dir>] [--scripts=<dir>] [--prompts=<dir>] '
      '[--cognition=<dir>] [--port=N] [--host=ADDR]',
    );
    exitCode = 64; // EX_USAGE
    return;
  }

  final trailRoot = positional.single;
  if (!Directory(trailRoot).existsSync()) {
    stderr.writeln('observatory: trail-host root not found: $trailRoot');
    exitCode = 66; // EX_NOINPUT
    return;
  }

  final flags = _flags(args);
  final webDir = flags['web'] ?? _defaultWebRoot();
  final scriptsDir = flags['scripts'] ?? _defaultScriptRoot();
  final promptsDir = flags['prompts'];
  final cognitionDir = flags['cognition'];
  final port = int.tryParse(flags['port'] ?? '') ?? _defaultPort;
  final bindHost = flags['host'] ?? _defaultHost;

  final webRoot = Directory(webDir);
  if (!webRoot.existsSync()) {
    stderr.writeln(
      'observatory: web build not found at $webDir — run '
      '`flutter build web` in tom_brain_observatory_web first '
      '(serving the /api surface only).',
    );
  }

  final scriptRoot = Directory(scriptsDir);
  if (!scriptRoot.existsSync()) {
    stderr.writeln(
      'observatory: procedure scripts not found at $scriptsDir — '
      'GET/PUT /api/procedures/<id> will 404 until --scripts points at the '
      "brain's scripts/system directory.",
    );
  }

  final promptsRoot = promptsDir == null ? null : Directory(promptsDir);
  if (promptsRoot == null) {
    stderr.writeln(
      'observatory: no --prompts root — GET/PUT /api/prompts/<roleId>/<part> '
      "will 404 until it points at the brain's roles folder.",
    );
  } else if (!promptsRoot.existsSync()) {
    stderr.writeln(
      'observatory: prompts root not found at $promptsDir — '
      'GET/PUT /api/prompts/<roleId>/<part> will 404 until --prompts points '
      "at the brain's roles folder.",
    );
  }

  // The editable catalogue (§ 8.3, step 14): GET /api/catalogue serves the
  // parsed cognition config's registry-derived index. Loaded read-only from the
  // --cognition root; a malformed config is reported (not fatal — the
  // observatory is a read-only mirror) and leaves the catalogue route to 503
  // "config unavailable", exactly as an absent root does.
  final cognition = _loadCognition(cognitionDir);

  // The Module-2 memory surface (§ 8.4) is deferred: the real `dart_mcp`-backed
  // McpReadConnection is wired at the run-assembly seam, not here. Until then
  // `memory:` stays null, so every `/api/memory/*` route answers 503 "memory
  // unavailable" — the routes exist, the UI degrades cleanly, nothing crashes.
  stderr.writeln(
    'observatory: memory connector not wired — /api/memory/* will 503 '
    '"memory unavailable" until the MCP read connection is injected (§ 8.4).',
  );
  final api = TrailReadApi(
    host: TrailHost.at(trailRoot),
    webRoot: webRoot.existsSync() ? webRoot : null,
    scriptRoot: scriptRoot.existsSync() ? scriptRoot : null,
    promptsRoot:
        promptsRoot != null && promptsRoot.existsSync() ? promptsRoot : null,
    cognition: cognition,
  );
  final server = await shelf_io.serve(api.handler, bindHost, port);

  stdout.writeln(
    'tom_brain_observatory serving on http://${server.address.host}:${server.port}/ '
    '(trail: $trailRoot${webRoot.existsSync() ? ', web: $webDir' : ', /api only'}).',
  );
  stdout.writeln('Press Ctrl-C to stop.');
  await stdout.flush();

  Future<void> shutdown(ProcessSignal signal) async {
    stdout.writeln('observatory: $signal — stopping…');
    await server.close(force: true);
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen(shutdown);
  }
}

/// Loads the cognition config from [cognitionDir] for `GET /api/catalogue`, or
/// returns `null` when no root is configured or the config fails to parse (the
/// route then 503s "config unavailable"). The observatory is a read-only mirror,
/// so a malformed cognition tree is reported but never fatal.
CognitionConfig? _loadCognition(String? cognitionDir) {
  if (cognitionDir == null) {
    stderr.writeln(
      'observatory: no --cognition root — GET /api/catalogue will 503 '
      '"config unavailable" until it points at the brain\'s cognition root.',
    );
    return null;
  }
  if (!Directory(cognitionDir).existsSync()) {
    stderr.writeln(
      'observatory: cognition root not found at $cognitionDir — '
      'GET /api/catalogue will 503 "config unavailable".',
    );
    return null;
  }
  try {
    return CognitionConfigLoader.loadFromDir(cognitionDir);
  } on CognitionConfigException catch (e) {
    stderr.writeln(
      'observatory: cognition config at $cognitionDir failed to parse '
      '(${e.message}) — GET /api/catalogue will 503 "config unavailable".',
    );
    return null;
  }
}

/// Parse `--key=value` flags from [args] (positional args are ignored here).
Map<String, String> _flags(List<String> args) => <String, String>{
      for (final a in args)
        if (a.startsWith('--') && a.contains('='))
          a.substring(2, a.indexOf('=')): a.substring(a.indexOf('=') + 1),
    };

/// The sibling web app's build output, relative to this script's package root.
String _defaultWebRoot() => p.normalize(p.join(
      p.dirname(Platform.script.toFilePath()),
      '..',
      '..',
      'tom_brain_observatory_web',
      'build',
      'web',
    ));

/// The sibling procedure package's script directory (`scripts/system`),
/// relative to this script's package root (§ 4.6).
String _defaultScriptRoot() => p.normalize(p.join(
      p.dirname(Platform.script.toFilePath()),
      '..',
      '..',
      'tom_brain_procedure',
      'scripts',
      'system',
    ));
