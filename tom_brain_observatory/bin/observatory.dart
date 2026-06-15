// The Tom Brain Observatory backend — one process serving the read-only Trail
// Read API under `/api` and the embedded Flutter-web build under `/`, from a
// single loopback origin (`prompt_tracing.md` § 8.5, § 7.1; plan PT-2.0). This
// is the "launch the backend, open the loopback URL" entrypoint: it binds
// 127.0.0.1 by default so the observatory is never exposed off-host.
//
// Usage:
//   dart run bin/observatory.dart <trail-host-root> [--web=<dir>] [--scripts=<dir>] [--cognition=<dir>] [--port=N] [--host=ADDR]
//
//   <trail-host-root>   the trail tree to read, e.g. _ai/tom_brain_trail/<host>
//   --web=<dir>         the `flutter build web` output to serve at `/`
//                       (default: ../tom_brain_observatory_web/build/web)
//   --scripts=<dir>     the running brain's procedure scripts served read-only
//                       by GET /api/procedures/<id> (§ 4.6; default:
//                       ../tom_brain_procedure/scripts/system) and written by
//                       PUT /api/procedures/<id> under the authoring guards
//                       (§ 6.3, AUTH-1…AUTH-3)
//   --cognition=<dir>   the running brain's cognition root (registry.yaml +
//                       per-procedure configs + templates + roles). Served
//                       read-only by GET /api/catalogue (§ 8.3, step 14), and
//                       it is also the root GET/PUT /api/templates?id=&part=
//                       reads and writes registered template files against,
//                       under the authoring guards (§ 6.3, AUTH-2/AUTH-3,
//                       step 15). No default — the catalogue route 503s "config
//                       unavailable" and the template routes 503 likewise until
//                       it points at the brain's cognition root
//   --run-config=<dir>  the run-config root the substrate config file
//                       (brain_run.yaml) resolves against for GET/PUT
//                       /api/config?kind=substrate (§ 6.4, step 16). Defaults to
//                       the --cognition root (the common single-tree layout);
//                       the registry/procedure/llm_route config kinds always
//                       resolve against --cognition
//   --memory-mcp-url=<url>
//                       the running memory MCP server's Streamable-HTTP endpoint
//                       (e.g. http://127.0.0.1:8765/mcp), served by the
//                       standalone tom_brain_memory/bin/memory_mcp_server.dart.
//                       When given, GET /api/memory/* is served read-only over an
//                       MCP client to it (§ 8.4). The store handle stays in that
//                       separate process, so OBS-3 ("never opens a DB file")
//                       holds. Omitted, or unreachable ⇒ /api/memory/* 503s
//                       "memory unavailable" and the UI degrades cleanly
//   --memory-mcp-token=<token>
//                       optional bearer forwarded as Authorization: Bearer to the
//                       memory MCP endpoint (omit for the anonymous loopback
//                       posture)
//   --port=N            loopback port (default 8787)
//   --host=ADDR         bind address (default 127.0.0.1; loopback-only by design)
//
// Read-only is load-bearing (OBS-1..OBS-5): this process never opens a trail
// file, the memory store, or any brain control surface for writing.

import 'dart:io';

import 'package:tom_brain_observatory/tom_brain_observatory.dart';

Future<void> main(List<String> args) async {
  final ObservatoryOptions options;
  try {
    options = ObservatoryOptions.fromArgs(args);
  } on ArgumentError {
    stderr.writeln(
      'usage: dart run bin/observatory.dart <trail-host-root> '
      '[--web=<dir>] [--scripts=<dir>] '
      '[--cognition=<dir>] [--run-config=<dir>] '
      '[--memory-mcp-url=<url>] [--memory-mcp-token=<token>] '
      '[--port=N] [--host=ADDR]',
    );
    exitCode = 64; // EX_USAGE
    return;
  }

  if (!Directory(options.trailRoot).existsSync()) {
    stderr.writeln('observatory: trail-host root not found: ${options.trailRoot}');
    exitCode = 66; // EX_NOINPUT
    return;
  }

  // The whole assembly (web / scripts / cognition / run-config / memory MCP) is
  // owned by `startObservatoryServer`; this bin only routes its narration to the
  // console and owns the process-wide signal lifecycle. The in-process variant
  // the brain spawns (`tom_brain_run`'s `observatory_isolate_host.dart`) calls the
  // same function but must NOT touch signals / `exit` — those are process-wide.
  final server = await startObservatoryServer(
    options,
    onInfo: (m) => stdout.writeln('observatory: $m'),
    onWarning: (m) => stderr.writeln('observatory: $m'),
  );

  stdout.writeln(
    'tom_brain_observatory serving on ${server.url} (trail: ${options.trailRoot}).',
  );
  stdout.writeln('Press Ctrl-C to stop.');
  await stdout.flush();

  Future<void> shutdown(ProcessSignal signal) async {
    stdout.writeln('observatory: $signal — stopping…');
    await server.close();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen(shutdown);
  }
}
