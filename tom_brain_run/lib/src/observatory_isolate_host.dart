// spawnObservatoryIsolate — hosts the Trail Observatory backend in a second
// isolate inside the running brain process, so the operator no longer launches a
// separate `dart run bin/observatory.dart`. The observatory is the official
// configuration + control surface, so the run assembly owns its lifecycle: it is
// brought up after the brain is serving and torn down on shutdown.
//
// Why a second isolate (not just a call): the observatory is a `shelf` server
// like the brain's own gateways, so it would run fine in the main isolate. A
// dedicated isolate buys *fault isolation* — a defect in the read-only mirror
// (a parser blowing the stack on a malformed trail file, say) cannot take the
// brain's foreground answer path down with it. The brain owns the process; the
// observatory is a guest with its own event loop.
//
// Why `Isolate.spawn` over `Isolate.spawnUri`: now that `tom_brain_run` depends
// on `tom_brain_observatory` (it is the control surface), the assembly is a
// directly-callable library function (`startObservatoryServer`). `Isolate.spawn`
// over a top-level entry that calls it is far simpler than resolving the sibling
// package's entrypoint + `package_config.json` by hand — and it shares the exact
// same backend code the standalone `bin/observatory.dart` runs.
//
// Signal discipline: the spawned entry must NEVER touch `ProcessSignal` or
// `exit` — those are process-wide and belong to the parent brain isolate
// (`brain_serve`). The entry stops only on an explicit control message from the
// host; the parent's SIGINT/SIGTERM handler calls [ObservatoryIsolateHost.stop].

import 'dart:async';
import 'dart:isolate';

import 'package:tom_brain_observatory/tom_brain_observatory.dart'
    show ObservatoryOptions, ObservatoryServer, startObservatoryServer;

/// A narration sink for a single host line (a started / warning message). The
/// run layer routes it to `tomLog` / the console.
typedef ObservatoryHostLog = void Function(String message);

/// A running in-process Observatory — the spawned isolate plus the live URL and
/// a graceful [stop]. Returned by [spawnObservatoryIsolate] (or `null` when the
/// backend failed to come up, which is non-fatal: the brain serves without it).
final class ObservatoryIsolateHost {
  final Isolate _isolate;
  final SendPort _control;
  final ReceivePort _events;
  final ReceivePort _exit;
  final StreamSubscription<dynamic> _sub;

  /// The loopback URL the Observatory bound — the address the operator opens.
  final Uri url;

  bool _stopped = false;

  ObservatoryIsolateHost._(
    this._isolate,
    this._control,
    this._events,
    this._exit,
    this._sub,
    this.url,
  );

  /// Asks the spawned isolate to close its socket and exit, then reaps it.
  /// Idempotent. If the isolate does not exit within [grace] it is killed, so a
  /// wedged observatory can never block the brain's shutdown.
  Future<void> stop({Duration grace = const Duration(seconds: 5)}) async {
    if (_stopped) return;
    _stopped = true;
    _control.send('stop');
    try {
      await _exit.first.timeout(grace);
    } on TimeoutException {
      _isolate.kill(priority: Isolate.immediate);
    }
    await _sub.cancel();
    _events.close();
    _exit.close();
  }
}

/// Spawns the Observatory backend in a second isolate from [options] and returns
/// a live [ObservatoryIsolateHost], or `null` when it could not be brought up
/// within [readyTimeout] (the brain then serves without the observatory — a
/// missing mirror is never fatal). Narration emitted during assembly (which
/// roots were found, whether memory connected) is forwarded to [onInfo] /
/// [onWarning] so the run layer can log it from the main isolate.
Future<ObservatoryIsolateHost?> spawnObservatoryIsolate(
  ObservatoryOptions options, {
  ObservatoryHostLog? onInfo,
  ObservatoryHostLog? onWarning,
  Duration readyTimeout = const Duration(seconds: 30),
}) async {
  final info = onInfo ?? (_) {};
  final warn = onWarning ?? (_) {};

  final events = ReceivePort();
  final exitPort = ReceivePort();

  final Isolate isolate;
  try {
    isolate = await Isolate.spawn<_ObservatoryBoot>(
      _observatoryIsolateEntry,
      (options: options, events: events.sendPort),
      onExit: exitPort.sendPort,
      debugName: 'tom_brain_observatory',
      errorsAreFatal: false,
    );
  } catch (e) {
    warn('could not spawn the observatory isolate ($e) — serving without it.');
    events.close();
    exitPort.close();
    return null;
  }

  final ready = Completer<ObservatoryIsolateHost?>();
  late final StreamSubscription<dynamic> sub;
  sub = events.listen((dynamic msg) {
    if (msg is! Map) return;
    switch (msg['status']) {
      case 'ready':
        if (ready.isCompleted) return;
        ready.complete(ObservatoryIsolateHost._(
          isolate,
          msg['control'] as SendPort,
          events,
          exitPort,
          sub,
          Uri.parse(msg['url'] as String),
        ));
      case 'error':
        warn('observatory backend failed to start (${msg['message']}) — '
            'serving without it.');
        if (!ready.isCompleted) ready.complete(null);
      default:
        // Forwarded assembly narration (`{'log': 'info'|'warn', 'message': …}`).
        final message = msg['message'];
        if (message is! String) return;
        if (msg['log'] == 'warn') {
          warn(message);
        } else {
          info(message);
        }
    }
  });

  final host = await ready.future.timeout(readyTimeout, onTimeout: () {
    warn('observatory backend did not report ready within '
        '${readyTimeout.inSeconds}s — serving without it.');
    return null;
  });

  if (host == null) {
    // Either error / timeout: tear the half-started isolate down so it never
    // lingers holding a half-bound socket.
    isolate.kill(priority: Isolate.immediate);
    await sub.cancel();
    events.close();
    exitPort.close();
  }
  return host;
}

/// The message [Isolate.spawn] hands [_observatoryIsolateEntry]: the parsed
/// [ObservatoryOptions] plus the [SendPort] the entry reports lifecycle and
/// narration back on. A record of sendable fields, so it copies across the
/// isolate boundary cleanly.
typedef _ObservatoryBoot = ({ObservatoryOptions options, SendPort events});

/// The second-isolate entrypoint: assemble and serve the Observatory backend,
/// report `ready` (with the bound URL + a control port) or `error`, then block on
/// the control port until told to `stop`. Touches no `ProcessSignal` and never
/// `exit`s — the parent brain isolate owns the process lifecycle.
Future<void> _observatoryIsolateEntry(_ObservatoryBoot boot) async {
  final events = boot.events;
  final ObservatoryServer server;
  try {
    server = await startObservatoryServer(
      boot.options,
      onInfo: (m) => events.send(<String, Object?>{'log': 'info', 'message': m}),
      onWarning: (m) =>
          events.send(<String, Object?>{'log': 'warn', 'message': m}),
    );
  } catch (e) {
    events.send(<String, Object?>{'status': 'error', 'message': '$e'});
    return;
  }

  final control = ReceivePort();
  events.send(<String, Object?>{
    'status': 'ready',
    'url': server.url.toString(),
    'control': control.sendPort,
  });

  await for (final msg in control) {
    if (msg == 'stop') break;
  }
  await server.close();
  control.close();
}
