// B.34 — Bearer-token auth plumbing for the outbound MCP client.
//
// Plan step:
//   - B.34 Implement bearer-token auth plumbing.
//
// Policy override 2 on `prototype_implementation_plan.md` pins the
// shape:
//
// ```yaml
// mcpClient:
//   endpoints:
//     memory:
//       transport: stdio
//       command: 'tom_brain_memory_mcp'
//       # No `auth:` field — stdio is never authenticated.
//     memory_remote:
//       transport: http
//       url: 'https://brain.example/mcp'
//       auth:
//         mode: bearer
//         secretRef: '_ai/secrets/mcp.bearer'
// ```
//
// And the invariants:
//
//   1. `mode: none` (or no `auth:` key at all) ⇒ no Authorization
//      header on outbound POSTs. The HTTP transport gets a `null`
//      `McpBearerCredential`.
//   2. `mode: bearer` ⇒ exactly one of `token` (inline; meant for
//      tests and bootstrap) or `secretRef` (file path resolved
//      relative to the supplied secrets root) must be present. The
//      file is read once at resolve time, its contents trimmed of
//      surrounding whitespace, and held as the credential's token.
//   3. Stdio endpoints with any `auth` block other than `mode: none`
//      are rejected at resolve time as [McpAuthConfigInvalid]. This
//      keeps the failure at config-load rather than at first
//      `connect()` — observability picks it up before the dispatcher
//      ever tries to use the endpoint.
//   4. Substrate logs (Spec § 10.2) must redact the raw token. The
//      [McpBearerCredential.fingerprint] (sha-256, first 8 hex
//      characters) is the only token-identifying surface allowed in
//      logs, trail entries, and `toString` output.
//
// What this file deliberately does NOT do:
//
//   - It does not negotiate token refresh / rotation. The prototype
//     loads the token once per substrate boot. Rotation lives in a
//     later phase (logged as Q-B.34.1 in
//     `prototype_implementation_questions.md`).
//   - It does not authenticate inbound connections. That is the
//     memory MCP server's responsibility (Memory Spec § 3.6).
//   - It does not validate JWT signatures. Tokens are opaque from
//     substrate's point of view — the endpoint is the only party
//     that interprets the token.

import 'dart:convert';
import 'dart:io' as io;

import 'mcp_errors.dart';
import 'mcp_transport.dart';

/// Configured auth profile for an MCP endpoint.
///
/// Sealed so the dispatcher's `switch` over the two cases stays
/// exhaustive at compile time. Use [McpAuthConfig.none] or
/// [McpAuthConfig.bearer] — neither constructor is `const` because the
/// bearer case validates its source eagerly.
sealed class McpAuthConfig {
  const McpAuthConfig._();

  /// No authentication. Resolves to a `null` [McpBearerCredential].
  /// The HTTP transport will not attach an Authorization header.
  ///
  /// Stdio endpoints must use this case (any other case on a stdio
  /// endpoint is an [McpAuthConfigInvalid]).
  static const McpAuthConfig none = _McpAuthNone._();

  /// Bearer-token authentication. Exactly one of [token] or
  /// [secretRef] must be supplied:
  ///
  ///   - [token] — inline token. Convenient for tests, bootstrap, and
  ///     for the dispatcher's in-isolate self-MCP wiring.
  ///   - [secretRef] — workspace-relative file path holding the raw
  ///     token. The file's contents are trimmed before use; trailing
  ///     newlines do not survive into the wire header.
  ///
  /// Supplying both, or neither, throws [McpAuthConfigInvalid] at
  /// construction time — the failure mode the dispatcher needs to
  /// see is "config rejected" rather than "first POST got a
  /// half-formed header".
  factory McpAuthConfig.bearer({
    String? token,
    String? secretRef,
  }) {
    final hasInline = token != null;
    final hasRef = secretRef != null;
    if (hasInline == hasRef) {
      throw McpAuthConfigInvalid(
        endpointId: '<unknown>',
        message: 'McpAuthConfig.bearer requires exactly one of `token` or '
            '`secretRef`; got '
            '${hasInline && hasRef ? "both" : "neither"}.',
      );
    }
    if (hasInline && token.isEmpty) {
      throw McpAuthConfigInvalid(
        endpointId: '<unknown>',
        message: 'McpAuthConfig.bearer.token must be a non-empty string.',
      );
    }
    if (hasRef && secretRef.isEmpty) {
      throw McpAuthConfigInvalid(
        endpointId: '<unknown>',
        message: 'McpAuthConfig.bearer.secretRef must be a non-empty path.',
      );
    }
    return _McpAuthBearer._(token: token, secretRef: secretRef);
  }
}

final class _McpAuthNone extends McpAuthConfig {
  const _McpAuthNone._() : super._();

  @override
  String toString() => 'McpAuthConfig.none';
}

final class _McpAuthBearer extends McpAuthConfig {
  /// Inline raw token. Mutually exclusive with [secretRef].
  final String? token;

  /// File path (workspace-relative or absolute) the resolver loads
  /// the token from. Mutually exclusive with [token].
  final String? secretRef;

  const _McpAuthBearer._({this.token, this.secretRef}) : super._();

  @override
  String toString() {
    if (token != null) {
      // Never include the token; the inline-token path is mostly used
      // by tests, but the redaction invariant still holds.
      return 'McpAuthConfig.bearer(inline)';
    }
    return 'McpAuthConfig.bearer(secretRef: $secretRef)';
  }
}

/// Resolves an [McpAuthConfig] (in the context of an endpoint) into a
/// concrete [McpBearerCredential], or `null` when the config is
/// `McpAuthConfig.none`.
///
/// The resolver is the single seam where token material crosses from
/// configuration into runtime. Keep it small; keep it allocating only
/// the bytes it needs; do not log the token.
final class McpAuthResolver {
  /// Root directory secret references are resolved against.
  ///
  /// For the prototype this is the workspace root (`secretRef`s look
  /// like `_ai/secrets/mcp.bearer`). Tests inject a temp directory.
  final io.Directory secretsRoot;

  /// File-loader hook. Defaults to direct disk I/O; tests inject a
  /// closure to keep the resolver hermetic.
  final Future<String> Function(io.File file) _readFile;

  McpAuthResolver({
    required this.secretsRoot,
    Future<String> Function(io.File file)? readFile,
  }) : _readFile = readFile ?? _defaultReadFile;

  static Future<String> _defaultReadFile(io.File file) =>
      file.readAsString(encoding: utf8);

  /// Resolves [config] in the context of [endpointId] and [transport].
  ///
  /// [transport] is the configured transport label (`"stdio"`,
  /// `"http"`, `"channel"`, …). The resolver uses it to enforce
  /// invariant 3 (stdio + auth ⇒ invalid).
  ///
  /// Returns `null` for `McpAuthConfig.none`; otherwise returns a
  /// [McpBearerCredential] with the loaded token. Throws
  /// [McpAuthConfigInvalid] for any rejected configuration.
  Future<McpBearerCredential?> resolve({
    required String endpointId,
    required String transport,
    required McpAuthConfig config,
  }) async {
    switch (config) {
      case _McpAuthNone():
        return null;
      case _McpAuthBearer(:final token, :final secretRef):
        if (transport != 'http') {
          throw McpAuthConfigInvalid(
            endpointId: endpointId,
            message: 'Endpoint "$endpointId" uses transport "$transport" but '
                'declares a bearer auth profile. Auth is HTTP-only (policy '
                'override 2). Remove the `auth:` block or move the endpoint '
                'onto the HTTP transport.',
          );
        }
        if (token != null) {
          return McpBearerCredential(token);
        }
        final path = secretRef!;
        final file = _resolveSecretFile(path);
        final String raw;
        try {
          raw = await _readFile(file);
        } on io.FileSystemException catch (error) {
          throw McpAuthConfigInvalid(
            endpointId: endpointId,
            message: 'Endpoint "$endpointId" bearer secretRef "$path" could '
                'not be read: ${error.message}.',
          );
        }
        final trimmed = raw.trim();
        if (trimmed.isEmpty) {
          throw McpAuthConfigInvalid(
            endpointId: endpointId,
            message: 'Endpoint "$endpointId" bearer secretRef "$path" '
                'resolved to an empty token after trimming.',
          );
        }
        return McpBearerCredential(trimmed);
    }
  }

  io.File _resolveSecretFile(String path) {
    final uri = Uri.file(path);
    if (uri.isAbsolute) {
      return io.File(path);
    }
    return io.File('${secretsRoot.path}${io.Platform.pathSeparator}$path');
  }
}

/// Raised when an MCP endpoint's auth configuration is rejected at
/// resolve time.
///
/// Separate from [McpAuthFailed] (which is the *runtime* HTTP 401/403
/// case): config errors mean the credential could not even be
/// constructed. Callers should branch on the type — credential
/// resolution problems are operator errors; HTTP 401 is an endpoint /
/// rotation problem.
final class McpAuthConfigInvalid implements Exception {
  /// The endpoint id whose config was rejected. `'<unknown>'` when
  /// the failure happens in [McpAuthConfig.bearer]'s constructor
  /// before the endpoint is in scope.
  final String endpointId;

  /// Human-readable diagnostic. Token material is NEVER included.
  final String message;

  const McpAuthConfigInvalid({
    required this.endpointId,
    required this.message,
  });

  @override
  String toString() => 'McpAuthConfigInvalid($endpointId): $message';
}
