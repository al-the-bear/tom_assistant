// A.75 — MCP server transports.
//
// The barrel comment in `mcp_server.dart` names the v1 supported
// transports: **stdio** and **UNIX-domain socket**. No HTTP transport
// in v1 scope.
//
//   - **stdio** — re-exported from `package:dart_mcp/stdio.dart` so
//     deployment code consumes a single transport surface. The dart_mcp
//     helper does newline-delimited UTF-8 framing exactly the way
//     MCP requires; there is no reason to rewrap it.
//   - **UNIX-domain socket** — adapted from a `dart:io` [Socket] by
//     [socketChannel]. The function mirrors `stdioChannel`'s framing
//     (UTF-8 codec + [LineSplitter] on the inbound side; '\n'-appending
//     on the outbound side). `Socket` already implements both
//     `Stream<List<int>>` and `StreamSink<List<int>>`, so the adapter
//     is a thin StreamChannel transform.
//
// Why a transports file separate from the server class:
//
//   - The server class (`tom_brain_memory_mcp_server.dart`) is purely
//     about the MCP protocol surface: identity, capability
//     advertisement, tool registration. Transports are about how bytes
//     arrive — they belong to deployment, not protocol.
//   - Future deployment shapes (e.g. an in-process channel for
//     embedded callers, a TCP/TLS transport once a brain-to-brain
//     network arrives) plug in here without touching the server class.

import 'dart:convert';
import 'dart:io' as io;

import 'package:async/async.dart' show StreamSinkTransformer;
import 'package:stream_channel/stream_channel.dart';

// Re-export `stdioChannel` so callers depend on a single transport
// surface (`mcp_server` barrel) rather than reaching directly into the
// `dart_mcp` sub-library. The re-export also documents that stdio is
// one of the two A.75 supported transports.
export 'package:dart_mcp/stdio.dart' show stdioChannel;

/// Adapts a `dart:io` [io.Socket] (typically a UNIX-domain socket) to the
/// newline-delimited UTF-8 [StreamChannel] of `String` that `dart_mcp`'s
/// [MCPServer] consumes.
///
/// Mirrors the framing rules of `stdioChannel`:
///
///   - Incoming bytes are UTF-8-decoded and split on newlines.
///   - Outgoing strings are UTF-8-encoded with a trailing `\n` appended
///     by an output transformer.
///
/// The [io.Socket] is used in both directions: it implements
/// `Stream<Uint8List>` (which satisfies `Stream<List<int>>`) and
/// `IOSink` (which implements `StreamSink<List<int>>`). The caller owns
/// the socket's lifecycle — closing the returned channel will not
/// destroy the underlying socket on its own, and connecting / accepting
/// the socket is a deployment concern outside the scope of this helper.
///
/// Typical deployment pattern:
///
/// ```dart
/// final listener = await io.ServerSocket.bind(
///   io.InternetAddress(path, type: io.InternetAddressType.unix),
///   0,
/// );
/// await for (final socket in listener) {
///   final channel = socketChannel(socket);
///   TomBrainMemoryMcpServer(channel);
/// }
/// ```
StreamChannel<String> socketChannel(io.Socket socket) =>
    StreamChannel<List<int>>.withCloseGuarantee(socket, socket)
        .transform(StreamChannelTransformer.fromCodec(utf8))
        .transformStream(const LineSplitter())
        .transformSink(
          StreamSinkTransformer.fromHandlers(
            handleData: (data, sink) {
              sink.add('$data\n');
            },
          ),
        );
