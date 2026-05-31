// B.8 — Stdio transport for the outbound MCP client.
//
// Two construction modes:
//
//   1. [StdioMcpTransport.process] — spawns a child process and wires
//      its stdin / stdout into the newline-framed `StreamChannel<String>`
//      that `dart_mcp` consumes. Process exit before handshake
//      completion surfaces as [McpTransportUnreachable].
//   2. [StdioMcpTransport.streams] — wraps a pre-existing pair of
//      byte streams (typically when the caller has already spawned
//      the process or wants to test against a subprocess fixture
//      that produces its own streams). Ownership of those streams
//      stays with the caller; this transport will not close the
//      caller-supplied sink unless [closeOnDispose] is set.
//
// Framing matches the rules `mcp_transports.dart` in `tom_brain_memory`
// uses for its server side (UTF-8 decode + LineSplitter inbound,
// UTF-8 encode + '\n' append outbound). The framing is intentionally
// duplicated rather than imported — the two packages must not depend
// on each other (Substrate Spec § 11 cycle prevention).
//
// No auth surface (policy override 2 on
// `prototype_implementation_plan.md`: stdio is never authenticated).

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:async/async.dart' show StreamSinkTransformer;
import 'package:stream_channel/stream_channel.dart';

import 'mcp_errors.dart';
import 'mcp_transport.dart';

/// Transport that talks to an MCP server over stdio framing.
///
/// Use the [StdioMcpTransport.process] factory to spawn a child
/// process; use [StdioMcpTransport.streams] when wrapping pre-built
/// byte streams (test fixtures, hand-spawned processes, …).
final class StdioMcpTransport implements McpTransport {
  @override
  final String id;

  final _Spawner _spawner;
  final bool _closeOnDispose;

  io.Process? _process;
  StreamChannel<String>? _channel;
  final _doneCompleter = Completer<void>();
  bool _closed = false;
  bool _connected = false;

  StdioMcpTransport._(
    this._spawner, {
    required this.id,
    required bool closeOnDispose,
  }) : _closeOnDispose = closeOnDispose;

  /// Spawns [command] (with [arguments]) and wires its stdin / stdout.
  ///
  /// The child process is owned by this transport — [close] will
  /// terminate it.
  factory StdioMcpTransport.process({
    required String id,
    required String command,
    List<String> arguments = const <String>[],
    Map<String, String>? environment,
    String? workingDirectory,
  }) {
    return StdioMcpTransport._(
      _ProcessSpawner(
        command: command,
        arguments: arguments,
        environment: environment,
        workingDirectory: workingDirectory,
      ),
      id: id,
      closeOnDispose: true,
    );
  }

  /// Wraps the supplied [stdin] / [stdout] byte streams.
  ///
  /// The caller owns the streams. Setting [closeOnDispose] to `true`
  /// causes [close] to also close [stdin]; the default is `false` so
  /// re-using the same stdin across multiple sessions stays possible.
  factory StdioMcpTransport.streams({
    required String id,
    required StreamSink<List<int>> stdin,
    required Stream<List<int>> stdout,
    bool closeOnDispose = false,
  }) {
    return StdioMcpTransport._(
      _StreamSpawner(stdin: stdin, stdout: stdout),
      id: id,
      closeOnDispose: closeOnDispose,
    );
  }

  @override
  Future<StreamChannel<String>> connect() async {
    if (_connected) {
      throw StateError(
        'StdioMcpTransport($id) has already been connected. '
        'Transports are single-use; construct a new one to re-connect.',
      );
    }
    _connected = true;

    final io.Process? process;
    final StreamSink<List<int>> stdinSink;
    final Stream<List<int>> stdoutStream;
    try {
      final spawned = await _spawner.spawn();
      process = spawned.process;
      stdinSink = spawned.stdin;
      stdoutStream = spawned.stdout;
    } on Object catch (error) {
      throw McpTransportUnreachable(
        id,
        'Failed to spawn stdio transport for $id: $error',
      );
    }

    _process = process;

    // Wire child-process exit (when applicable) into our done future
    // so `McpClient` can race transport failure against handshake.
    if (process != null) {
      unawaited(
        process.exitCode.then((code) {
          if (_closed) {
            if (!_doneCompleter.isCompleted) _doneCompleter.complete();
            return;
          }
          if (!_doneCompleter.isCompleted) {
            _doneCompleter.completeError(
              McpTransportUnreachable(
                id,
                'Stdio child process exited unexpectedly with code $code '
                'before close() was called.',
              ),
            );
          }
        }),
      );
    }

    final channel = StreamChannel<List<int>>.withCloseGuarantee(
      stdoutStream,
      stdinSink,
    ).transform(StreamChannelTransformer.fromCodec(utf8))
        .transformStream(const LineSplitter())
        .transformSink(
          StreamSinkTransformer.fromHandlers(
            handleData: (data, sink) {
              sink.add('$data\n');
            },
          ),
        );
    _channel = channel;

    // When the sink closes for any reason (consumer close, server EOF),
    // complete the done future cleanly if it hasn't already errored.
    unawaited(
      channel.sink.done.then((_) {
        if (!_doneCompleter.isCompleted) _doneCompleter.complete();
      }, onError: (Object error, StackTrace stack) {
        if (!_doneCompleter.isCompleted) {
          _doneCompleter.completeError(error, stack);
        }
      }),
    );

    return channel;
  }

  @override
  Future<void> get done => _doneCompleter.future;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    final channel = _channel;
    if (channel != null && _closeOnDispose) {
      try {
        await channel.sink.close();
      } catch (_) {
        // Already closed — ignore.
      }
    }
    final process = _process;
    if (process != null) {
      // Best-effort termination of a still-running child process. We
      // do not wait for exitCode here; the listener wired in connect()
      // will complete `done`.
      process.kill();
    }
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
  }
}

abstract class _Spawner {
  Future<_SpawnedStreams> spawn();
}

class _SpawnedStreams {
  final io.Process? process;
  final StreamSink<List<int>> stdin;
  final Stream<List<int>> stdout;

  _SpawnedStreams({this.process, required this.stdin, required this.stdout});
}

class _ProcessSpawner implements _Spawner {
  final String command;
  final List<String> arguments;
  final Map<String, String>? environment;
  final String? workingDirectory;

  _ProcessSpawner({
    required this.command,
    required this.arguments,
    this.environment,
    this.workingDirectory,
  });

  @override
  Future<_SpawnedStreams> spawn() async {
    final process = await io.Process.start(
      command,
      arguments,
      environment: environment,
      workingDirectory: workingDirectory,
      mode: io.ProcessStartMode.normal,
    );
    return _SpawnedStreams(
      process: process,
      stdin: process.stdin,
      stdout: process.stdout,
    );
  }
}

class _StreamSpawner implements _Spawner {
  final StreamSink<List<int>> stdin;
  final Stream<List<int>> stdout;

  _StreamSpawner({required this.stdin, required this.stdout});

  @override
  Future<_SpawnedStreams> spawn() async {
    return _SpawnedStreams(stdin: stdin, stdout: stdout);
  }
}
