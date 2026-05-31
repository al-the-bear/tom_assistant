// B.8 — Pre-built `StreamChannel<String>` transport.
//
// Use cases:
//
//   1. Tests — pair this transport with a `StreamChannelController`
//      to wire `MCPClient` directly to a `MCPServer` running in the
//      same isolate. This is what `b08_mcp_client_test.dart` uses
//      for tool-discovery and roundtrip coverage.
//   2. In-process colocation — when memory and substrate live in the
//      same process (the prototype's default deployment shape,
//      pre-dispatcher), `ChannelMcpTransport` is the path through
//      which substrate's `McpClient` talks to a locally-instantiated
//      `TomBrainMemoryMcpServer` without going through stdio framing.
//
// No auth surface (policy override 2 on
// `prototype_implementation_plan.md`: stdio / channel transports are
// never authenticated). The transport ignores any bearer credential
// it might be handed.

import 'package:stream_channel/stream_channel.dart';

import 'mcp_transport.dart';

/// Transport that wraps a pre-existing duplex `StreamChannel<String>`.
///
/// Ownership: this class does **not** close the underlying channel on
/// [close] unless [closeChannelOnClose] is `true`. The default is
/// `true` because the most common path — `MCPClient` → transport →
/// closed when the session ends — expects the channel to be torn
/// down. Tests that want to drive the channel from both sides set
/// it to `false` so the test can keep using the channel after the
/// client has closed.
final class ChannelMcpTransport implements McpTransport {
  @override
  final String id;

  final StreamChannel<String> _channel;
  final bool _closeChannelOnClose;

  bool _connected = false;
  bool _closed = false;

  ChannelMcpTransport(
    this._channel, {
    required this.id,
    bool closeChannelOnClose = true,
  }) : _closeChannelOnClose = closeChannelOnClose;

  @override
  Future<StreamChannel<String>> connect() async {
    if (_connected) {
      throw StateError(
        'ChannelMcpTransport($id) has already been connected. '
        'Transports are single-use; construct a new one to re-connect.',
      );
    }
    _connected = true;
    return _channel;
  }

  @override
  Future<void> get done => _channel.sink.done.then((_) {});

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_closeChannelOnClose) {
      await _channel.sink.close();
    }
  }
}
