// McpServerConfig + McpServersConfig — the `mcpServers:` configuration block
// (Extension F step 8; `tom_brain_procedure_specification.md`
// § 21.3, § 21.6).
//
// The MCP client (`mcp_client.dart`) calls *out* to MCP servers — the memory
// one and any external one an operator configures. The set of reachable
// servers is data, not code: each is named by an `id`, a `transport`, and an
// optional `description`, plus the transport-specific coordinates the
// connector needs to open a channel (`command` / `args` for stdio,
// `url` / `headers` for HTTP).
//
// Loading goes through the canonical plain-map loader (`loadYamlAsMap`), so
// no `YamlMap` / `YamlList` node leaks into a config value — the same idiom
// `ModelConfig` (§ 21.6) follows. A configured-but-unreachable server is an
// *environmental* failure surfaced at connect time (PE-6), not a config
// error: the loader validates shape only.

library;

import 'dart:io';

import 'package:tom_core_agentic/tom_core_agentic.dart';

import 'mcp_config_errors.dart';

/// How the MCP client reaches a server.
///
/// A closed enum (not a free `String`): the connector branches on exactly
/// these members, so an unrecognised transport is a config error, not a
/// silent passthrough. Each member's `.name` is its wire token (`stdio`,
/// `http`).
enum McpTransport {
  /// A child process speaking line-delimited JSON-RPC over stdio.
  stdio,

  /// A Streamable-HTTP endpoint (the memory server's network surface).
  http,
}

/// One configured MCP server — an immutable value object.
///
/// `id`, `transport`, and (optional) `description` are what `mcp.servers()`
/// advertises. The transport-specific coordinates (`command` / `args` for
/// [McpTransport.stdio]; `url` / `headers` for [McpTransport.http]) are what a
/// real connector opens a channel from; a stub/in-process connector ignores
/// them. They are validated for shape but never dereferenced by this layer.
final class McpServerConfig {
  /// Builds a server config. Only [id] and [transport] are required; the
  /// rest are optional and transport-dependent.
  const McpServerConfig({
    required this.id,
    required this.transport,
    this.description,
    this.command,
    this.args = const <String>[],
    this.url,
    this.headers = const <String, String>{},
    this.exposeToLlms = false,
  });

  /// The server id — the handle `mcp.list(server)` / `mcp.call(server, …)`
  /// name and the pool key.
  final String id;

  /// How the client reaches this server.
  final McpTransport transport;

  /// A human-readable description, surfaced by `mcp.servers()`.
  final String? description;

  /// The child-process executable for a [McpTransport.stdio] server.
  final String? command;

  /// Arguments for [command].
  final List<String> args;

  /// The endpoint URL for a [McpTransport.http] server.
  final String? url;

  /// Extra request headers for a [McpTransport.http] server (e.g. a bearer
  /// token).
  final Map<String, String> headers;

  /// Whether this server's tools are offered to procedures / LLMs.
  ///
  /// Closed by default (`false`): a configured-but-unexposed server is
  /// reachable by inspection tooling but never auto-offered to a model. A
  /// server's tools become available only when this is `true` **and** the
  /// liveness monitor reports it live (`offered = exposeToLlms && isLive`;
  /// `agent_sdk_provider_and_mcp_liveness.md` § 3.1, § 3.3).
  final bool exposeToLlms;

  /// The `{id, transport, description}` view `mcp.servers()` returns.
  Map<String, Object?> toAdvertisement() => <String, Object?>{
        'id': id,
        'transport': transport.name,
        'description': description,
      };

  @override
  bool operator ==(Object other) =>
      other is McpServerConfig &&
      other.id == id &&
      other.transport == transport &&
      other.description == description &&
      other.command == command &&
      _sameList(other.args, args) &&
      other.url == url &&
      _sameMap(other.headers, headers) &&
      other.exposeToLlms == exposeToLlms;

  @override
  int get hashCode => Object.hash(
        id,
        transport,
        description,
        command,
        Object.hashAll(args),
        url,
        Object.hashAllUnordered(
          headers.entries.map((e) => Object.hash(e.key, e.value)),
        ),
        exposeToLlms,
      );

  @override
  String toString() =>
      'McpServerConfig(id: $id, transport: ${transport.name}, '
      'description: $description)';

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameMap(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }
}

/// The configured MCP server registry — the parsed `mcpServers:` block.
///
/// An ordered, immutable list of [McpServerConfig]s with id lookup. The
/// memory MCP server is one entry; external servers are the rest.
final class McpServersConfig {
  /// Wraps an ordered [servers] list.
  McpServersConfig(List<McpServerConfig> servers)
      : servers = List.unmodifiable(servers);

  /// The configured servers, in declaration order.
  final List<McpServerConfig> servers;

  /// The server with [id], or `null` when none is configured.
  McpServerConfig? byId(String id) {
    for (final server in servers) {
      if (server.id == id) return server;
    }
    return null;
  }

  /// Reads and parses an `mcpServers:` block from [file].
  ///
  /// An absent file yields an empty registry (the brain simply has no MCP
  /// servers — not an error). Structural problems throw [McpConfigInvalid].
  ///
  /// [envVars] expands `${env:NAME}` tokens in server coordinates; a relative
  /// `mcpServersDir` resolves against [file]'s directory (CLI plan step #3).
  static Future<McpServersConfig> loadFromFile(
    File file, {
    Map<String, String> envVars = const <String, String>{},
  }) async {
    if (!await file.exists()) {
      return McpServersConfig(const <McpServerConfig>[]);
    }
    return fromYamlString(
      await file.readAsString(),
      envVars: envVars,
      basePath: file.absolute.parent.path,
    );
  }

  /// Parses an `mcpServers:` block from [yamlText].
  ///
  /// Shape: a top-level `mcpServers:` list of maps, each with a required
  /// `id` + `transport` and optional `description` / `command` / `args` /
  /// `url` / `headers`. A missing `mcpServers:` key yields an empty registry.
  /// An unknown `transport`, a missing `id`, or a wrong-typed field throws
  /// [McpConfigInvalid].
  ///
  /// The block may be sourced from a directory instead of inline: a top-level
  /// `mcpServersDir:` names a directory of `*.yaml` / `*.yml` files, each
  /// carrying its own `mcpServers:` list; the lists are unioned in filename
  /// order with cross-file duplicate-id detection (mirrors the substrate
  /// `providersDir` / profiles `profilesDir` aspects, CLI plan step #3).
  /// Declaring both `mcpServers:` (inline) and `mcpServersDir:` is a config
  /// error. A relative `mcpServersDir` resolves against [basePath] (the config
  /// file's directory); [envVars] expands `${env:NAME}` tokens in server
  /// coordinates (`command` / `args` / `url` / `headers`).
  static McpServersConfig fromYamlString(
    String yamlText, {
    Map<String, String> envVars = const <String, String>{},
    String? basePath,
  }) {
    final doc = loadYamlAsMap(
      yamlText,
      rootPath: 'mcp',
      errorFactory: McpConfigInvalid.new,
    );
    final reader = YamlConfigReader(
      env: envVars,
      errorFactory: McpConfigInvalid.new,
    );

    final servers = <McpServerConfig>[];
    final seenIds = <String>{};

    final mcpServersDir =
        reader.optionalString(doc, 'mcpServersDir', 'mcpServersDir');
    if (mcpServersDir != null) {
      if (doc.containsKey('mcpServers')) {
        throw const McpConfigInvalid(
          'declare `mcpServers:` (inline) or `mcpServersDir:` (a directory of '
          'MCP server files), not both.',
          path: 'mcpServersDir',
        );
      }
      for (final file in _mcpYamlFiles(mcpServersDir, basePath)) {
        final fileDoc = _loadMcpFile(file);
        final rawServers =
            reader.optionalList(fileDoc, 'mcpServers', 'mcpServers');
        if (rawServers != null) {
          _accumulate(
            rawServers,
            reader,
            servers,
            seenIds,
            source: _fileLabel(file),
          );
        }
      }
      return McpServersConfig(servers);
    }

    final rawServers = reader.optionalList(doc, 'mcpServers', 'mcp.mcpServers');
    if (rawServers == null) {
      return McpServersConfig(const <McpServerConfig>[]);
    }
    _accumulate(rawServers, reader, servers, seenIds, source: 'mcp.mcpServers');
    return McpServersConfig(servers);
  }

  /// Parses each entry of an `mcpServers:` [rawServers] list into [servers],
  /// expanding `${env:NAME}` coordinates and detecting a duplicate id across
  /// the accumulated set ([seenIds]). [source] names the error-path prefix
  /// (`mcp.mcpServers` inline, or the filename when directory-sourced).
  static void _accumulate(
    List<Object?> rawServers,
    YamlConfigReader reader,
    List<McpServerConfig> servers,
    Set<String> seenIds, {
    required String source,
  }) {
    for (var i = 0; i < rawServers.length; i++) {
      final entry = rawServers[i];
      final path = '$source[$i]';
      if (entry is! Map<String, Object?>) {
        throw McpConfigInvalid(
          'server entry must be a map (got ${entry.runtimeType})',
          path: path,
        );
      }
      final id = reader.requireString(entry, 'id', '$path.id');
      if (!seenIds.add(id)) {
        throw McpConfigInvalid(
          'duplicate server id "$id"',
          path: '$path.id',
        );
      }
      final transport = _parseTransport(
        reader.requireString(entry, 'transport', '$path.transport'),
        '$path.transport',
      );
      final description =
          reader.optionalString(entry, 'description', '$path.description');
      final rawCommand =
          reader.optionalString(entry, 'command', '$path.command');
      final command = rawCommand == null
          ? null
          : reader.expandEnv(rawCommand, '$path.command');
      final args = _stringList(reader, entry, 'args', '$path.args')
          .map((a) => reader.expandEnv(a, '$path.args'))
          .toList(growable: false);
      final rawUrl = reader.optionalString(entry, 'url', '$path.url');
      final url = rawUrl == null ? null : reader.expandEnv(rawUrl, '$path.url');
      final headers = _stringMap(reader, entry, 'headers', '$path.headers').map(
        (key, value) =>
            MapEntry(key, reader.expandEnv(value, '$path.headers.$key')),
      );
      final exposeToLlms = reader.optionalBool(
            entry,
            'exposeToLlms',
            '$path.exposeToLlms',
          ) ??
          false;

      servers.add(McpServerConfig(
        id: id,
        transport: transport,
        description: description,
        command: command,
        args: args,
        url: url,
        headers: headers,
        exposeToLlms: exposeToLlms,
      ));
    }
  }

  // ── directory sourcing (`mcpServersDir`, CLI plan step #3) ──────────
  //
  // Mirrors the substrate loader's `providersDir`/`modelsDir` helpers and the
  // profiles `profilesDir` aspect: resolve a relative dir against the config
  // file's directory, read its `*.yaml`/`*.yml` files in filename order, and
  // feed each file's `mcpServers:` list back through the inline parser. Kept
  // off `package:path` (the `_isAbsolutePath` regex) to match the sibling
  // loaders' surface.

  /// Resolves [dirPath] against [basePath] and returns its `*.yaml`/`*.yml`
  /// files sorted by path. A relative [dirPath] requires a [basePath]; a
  /// missing directory is a clear error.
  static List<File> _mcpYamlFiles(String dirPath, String? basePath) {
    final String resolved;
    if (_isAbsolutePath(dirPath)) {
      resolved = dirPath;
    } else if (basePath == null) {
      throw const McpConfigInvalid(
        'mcpServersDir is a relative path but no base directory is available; '
        'load the config via `loadFromFile` (or pass `basePath`) so a relative '
        'MCP servers directory resolves against the config file.',
        path: 'mcpServersDir',
      );
    } else {
      resolved = '$basePath/$dirPath';
    }
    final dir = Directory(resolved);
    if (!dir.existsSync()) {
      throw McpConfigInvalid(
        'mcpServersDir directory not found: $resolved',
        path: 'mcpServersDir',
      );
    }
    return dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.yaml') || f.path.endsWith('.yml'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  }

  /// Reads + parses one MCP servers [file] into a plain map. Wraps read
  /// failures as [McpConfigInvalid] naming the file.
  static Map<String, Object?> _loadMcpFile(File file) {
    final String content;
    try {
      content = file.readAsStringSync();
    } on FileSystemException catch (e) {
      throw McpConfigInvalid(
        'mcpServersDir: cannot read ${file.path}: ${e.message}',
        path: 'mcpServersDir',
      );
    }
    return loadYamlAsMap(
      content,
      rootPath: _fileLabel(file),
      errorFactory: McpConfigInvalid.new,
    );
  }

  /// The trailing filename of an MCP servers [file], for compact error labels.
  static String _fileLabel(File file) {
    final segments = file.uri.pathSegments;
    return segments.isEmpty ? file.path : segments.last;
  }

  /// Posix / Windows absolute-path test without `package:path` (matching the
  /// sibling aspect loaders' surface).
  static bool _isAbsolutePath(String pth) =>
      pth.startsWith('/') ||
      pth.startsWith(r'\\') ||
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(pth);

  static McpTransport _parseTransport(String value, String path) {
    for (final transport in McpTransport.values) {
      if (transport.name == value) return transport;
    }
    final known = McpTransport.values.map((t) => t.name).join(', ');
    throw McpConfigInvalid(
      'unknown transport "$value" (expected one of: $known)',
      path: path,
    );
  }

  static List<String> _stringList(
    YamlConfigReader reader,
    Map<String, Object?> doc,
    String key,
    String path,
  ) {
    final raw = reader.optionalList(doc, key, path);
    if (raw == null) return const <String>[];
    final result = <String>[];
    for (var i = 0; i < raw.length; i++) {
      final value = raw[i];
      if (value is! String) {
        throw McpConfigInvalid(
          'list element must be a string (got ${value.runtimeType})',
          path: '$path[$i]',
        );
      }
      result.add(value);
    }
    return result;
  }

  static Map<String, String> _stringMap(
    YamlConfigReader reader,
    Map<String, Object?> doc,
    String key,
    String path,
  ) {
    final raw = reader.optionalMap(doc, key);
    if (raw == null) return const <String, String>{};
    final result = <String, String>{};
    for (final entry in raw.entries) {
      final mapKey = entry.key;
      if (mapKey is! String) {
        throw McpConfigInvalid(
          'map key must be a string (got ${mapKey.runtimeType})',
          path: path,
        );
      }
      final value = entry.value;
      if (value is! String) {
        throw McpConfigInvalid(
          'map value must be a string (got ${value.runtimeType})',
          path: '$path.$mapKey',
        );
      }
      result[mapKey] = value;
    }
    return result;
  }
}
