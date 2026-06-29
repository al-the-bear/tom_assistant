// ProfileRegistry — the `profiles:` parser + boot resolver/validator
// (session_configuration.md § 3, plan step 3).
//
// One registry per process, built once at boot from the whole-process config's
// `profiles:` block. It owns three jobs:
//
//   * parse (`fromYamlString`) — turn `profiles.<id>:` maps into immutable
//     `Profile`s, synthesise the built-in `default` when none is configured
//     (SC-5), and catch the pure `mode`/`entryProcedure` conflict at parse time
//     (SCP-13);
//   * resolve (`resolve`) — turn a selected `Profile` + the boot context
//     (the global-exposed MCP id set, the budget/rate-limit ceilings) into the
//     `ResolvedProfile` the edge stamps on `Access`. This computes the offered
//     MCP set (§ 3.6 / SCP-15) and clamps budget/rate-limits to the ceiling
//     (SC-8 / SCP-12);
//   * validate (`validateAtBoot`) — the environmental checks that need injected
//     boot dependencies: unknown `role` (`profile.unknown_role`), missing
//     `templateOverlay` dir (`profile.overlay_missing`), and a clamp warning.
//
// Per-profile `defineMcpServers` are exposed as `namespacedDefinedServers` —
// each rewritten to `<profileId>/<serverName>` — for the boot wiring to merge
// into the global `McpClient` registry (§ 3.6).
//
// The `defineMcpServers` items are parsed with a faithful local helper that
// reads the *canonical* `McpServerConfig` shape (`id` + `transport` + …),
// reconciling the § 3.8 example's friendlier form onto the realised shape
// (SCP-3) rather than cross-package-refactoring a public factory out of
// `tom_brain_procedure`.
//
// ── Runtime authoring (I-6, Phase 1) ────────────────────────────────────
//
// The registry is built once at boot but is *runtime-authorable*: `author`
// upserts a profile and `remove` deletes one, each running the **same**
// environmental validation as boot (extracted into `_validateProfile`, shared
// with `validateAtBoot`) against a captured `ProfileAuthoringContext`. `default`
// may be redefined but never removed (SC-5: it must always exist). This is the
// load-bearing engine; the *persisted* write surface that would drive it — the
// Observatory `PUT` route + on-disk `yaml_edit` (procedure § 24.8 /
// `prompt_tracing.md` § 6.3) — is the deferred Phase 2, so today no inbound
// channel mutates the registry and an operator still edits config + reboots.

import 'dart:io' show Directory, File, FileSystemException;

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show McpServerConfig, McpTransport;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show ProfileBudget, ProfileMode, ProfileRateLimits, ResolvedProfile;
import 'package:tom_core_agentic/tom_core_agentic.dart'
    show YamlConfigReader, loadYamlAsMap;

import 'profile.dart';
import 'profile_config_errors.dart';

/// The parsed `profiles:` registry — the single source of profiles for a
/// process. Always contains the built-in `default` (SC-5).
final class ProfileRegistry {
  final Map<String, Profile> _profiles;

  /// Wraps an ordered set of [profiles], synthesising the built-in `default`
  /// (today's behaviour, SC-5) when none is provided. A profile named `default`
  /// in [profiles] replaces the built-in (SC-Q18 / SC-Q20).
  ProfileRegistry(Iterable<Profile> profiles)
      : _profiles = _index(profiles);

  static Map<String, Profile> _index(Iterable<Profile> profiles) {
    final map = <String, Profile>{};
    for (final p in profiles) {
      map[p.id] = p;
    }
    map.putIfAbsent('default', () => Profile(id: 'default'));
    return map;
  }

  /// Parses the `profiles:` block out of the whole-process [content].
  ///
  /// The profiles are sourced either **inline** (`profiles:`) or from a
  /// **directory** (the top-level `profilesDir:`, the standalone `tom_brain`
  /// CLI's `<agent>/profiles/` convention, CLI plan step 5) — never both. When
  /// `profilesDir` is set, every `*.yaml`/`*.yml` file under it carries its own
  /// top-level `profiles:` map; those maps are unioned by id in filename order,
  /// and a profile id declared in two files is a `profile.duplicate_id` error.
  /// A relative `profilesDir` resolves against [basePath] (threaded from
  /// `BrainRunConfigLoader.loadFromFile`); a relative path with no [basePath],
  /// or a missing directory, is an error.
  ///
  /// Reads only `doc['profiles']` / `doc['profilesDir']`, tolerating sibling
  /// sections — the same re-parse-the-whole-document contract every section
  /// loader uses. An absent or empty block yields a registry with only the
  /// built-in `default`. [envVars] expands `${NAME}` tokens inside string
  /// fields.
  ///
  /// Throws [ProfileConfigException] on a malformed block, an unknown `mode`
  /// token (`profile.unknown_mode`), a `mode`/`entryProcedure` conflict
  /// (`profile.mode_entry_conflict`), both inline + directory set
  /// (`profile.dir_inline_conflict`), or a cross-file duplicate id
  /// (`profile.duplicate_id`).
  static ProfileRegistry fromYamlString(
    String content, {
    Map<String, String> envVars = const {},
    String? basePath,
  }) {
    final Map<String, Object?> doc = loadYamlAsMap(
      content,
      rootPath: 'root',
      errorFactory: ProfileConfigException.new,
    );
    final reader = YamlConfigReader(
      env: envVars,
      errorFactory: ProfileConfigException.new,
    );
    final profilesDir =
        reader.optionalString(doc, 'profilesDir', 'profilesDir');
    final byId = <String, Profile>{};
    if (profilesDir != null) {
      if (doc.containsKey('profiles')) {
        throw const ProfileConfigException(
          'declare `profiles:` (inline) or `profilesDir:` (a directory of '
          'profile files), not both.',
          code: 'profile.dir_inline_conflict',
        );
      }
      for (final file in _profileYamlFiles(profilesDir, basePath)) {
        final fileDoc = _loadProfileFile(file);
        final node = reader.optionalMap(fileDoc, 'profiles');
        if (node != null) {
          _accumulate(node, reader, byId, source: _fileLabel(file));
        }
      }
    } else {
      final Map<Object?, Object?>? profilesNode =
          reader.optionalMap(doc, 'profiles');
      if (profilesNode != null) {
        _accumulate(profilesNode, reader, byId, source: 'profiles');
      }
    }
    return ProfileRegistry(byId.values);
  }

  /// Parses every entry of a `profiles:` [node] into [byId], detecting a
  /// duplicate id ([source] names where the node came from, for the error).
  static void _accumulate(
    Map<Object?, Object?> node,
    YamlConfigReader reader,
    Map<String, Profile> byId, {
    required String source,
  }) {
    for (final entry in node.entries) {
      final key = entry.key;
      if (key is! String) {
        throw const ProfileConfigException(
          'a profile name must be a string',
          path: 'profiles',
        );
      }
      if (byId.containsKey(key)) {
        throw ProfileConfigException(
          'duplicate profile id "$key" (already declared; redeclared in '
          '$source)',
          code: 'profile.duplicate_id',
          path: 'profiles.$key',
        );
      }
      final Object? body = entry.value;
      final Map<Object?, Object?> map;
      if (body == null) {
        map = const <Object?, Object?>{};
      } else if (body is Map<Object?, Object?>) {
        map = body;
      } else {
        throw ProfileConfigException(
          'profile "$key" must be a map',
          path: 'profiles.$key',
        );
      }
      byId[key] = _parseProfile(key, map, reader);
    }
  }

  // ── directory sourcing (`profilesDir`, CLI plan step 5) ─────────────
  //
  // Mirrors the substrate loader's `providersDir`/`modelsDir` helpers
  // (step 2): resolve a relative dir against the config file's directory,
  // read its `*.yaml`/`*.yml` files in filename order, and feed each file's
  // `profiles:` map back through the inline parser. Kept off `package:path`
  // (the `_isAbsolutePath` regex) to match the substrate loader's surface.

  /// Resolves [dirPath] against [basePath] and returns its `*.yaml`/`*.yml`
  /// files sorted by path. A relative [dirPath] requires a [basePath]; a
  /// missing directory is a clear error.
  static List<File> _profileYamlFiles(String dirPath, String? basePath) {
    final String resolved;
    if (_isAbsolutePath(dirPath)) {
      resolved = dirPath;
    } else if (basePath == null) {
      throw ProfileConfigException(
        'profilesDir "$dirPath" is a relative path but no base directory is '
        'available; load the config via `loadFromFile` (or pass `basePath`) '
        'so a relative profiles directory resolves against the config file.',
        code: 'profile.dir_unresolved',
        path: 'profilesDir',
      );
    } else {
      resolved = '$basePath/$dirPath';
    }
    final dir = Directory(resolved);
    if (!dir.existsSync()) {
      throw ProfileConfigException(
        'profilesDir directory not found: $resolved',
        code: 'profile.dir_missing',
        path: 'profilesDir',
      );
    }
    return dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.yaml') || f.path.endsWith('.yml'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  }

  /// Reads + parses one profiles [file] into a plain map. Wraps read/parse
  /// failures as [ProfileConfigException] naming the file.
  static Map<String, Object?> _loadProfileFile(File file) {
    final String content;
    try {
      content = file.readAsStringSync();
    } on FileSystemException catch (e) {
      throw ProfileConfigException(
        'profilesDir: cannot read ${file.path}: ${e.message}',
        code: 'profile.dir_read_failed',
        path: 'profilesDir',
      );
    }
    return loadYamlAsMap(
      content,
      rootPath: _fileLabel(file),
      errorFactory: ProfileConfigException.new,
    );
  }

  /// The trailing filename of a profiles [file], for compact error labels.
  static String _fileLabel(File file) {
    final segments = file.uri.pathSegments;
    return segments.isEmpty ? file.path : segments.last;
  }

  /// Posix / Windows absolute-path test without `package:path` (matching the
  /// substrate loader's surface).
  static bool _isAbsolutePath(String pth) =>
      pth.startsWith('/') ||
      pth.startsWith(r'\\') ||
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(pth);

  /// The configured profile names, in declaration order (always includes
  /// `default`).
  Iterable<String> get names => _profiles.keys;

  /// Whether a profile named [name] exists.
  bool contains(String name) => _profiles.containsKey(name);

  /// The profile named [name], or `null` when absent.
  Profile? profile(String name) => _profiles[name];

  /// Resolves the profile named [name] into the [ResolvedProfile] the edge
  /// stamps on `Access`.
  ///
  /// [globalExposedIds] is the set of global MCP server ids the operator marked
  /// `exposeToLlms: true`; it drives the offered-MCP set (§ 3.6 / SCP-15).
  /// [budgetCeiling] / [rateLimitCeiling] are the global ceilings a profile may
  /// only *tighten* (SC-8); a looser profile value is clamped here.
  ///
  /// Throws [UnknownProfileException] when [name] is not configured (the edge
  /// maps this to `400 invalid_api_key` / `profile.unknown`, § 8).
  ResolvedProfile resolve(
    String name, {
    Iterable<String> globalExposedIds = const <String>[],
    ProfileBudget? budgetCeiling,
    ProfileRateLimits? rateLimitCeiling,
  }) {
    final p = _profiles[name];
    if (p == null) throw UnknownProfileException(name);
    return ResolvedProfile(
      id: p.id,
      mode: p.mode,
      entryProcedure: p.effectiveEntryProcedure,
      role: p.role,
      anchored: p.anchored,
      templateOverlay: p.templateOverlay,
      offeredMcpServers: _offeredFor(p, globalExposedIds),
      budget: _clampBudget(p.budget, budgetCeiling),
      rateLimits: _clampRateLimits(p.rateLimits, rateLimitCeiling),
      defaultSession: p.defaultSession,
      defaultMemory: p.defaultMemory,
    );
  }

  /// Runs the environmental boot checks across every profile.
  ///
  /// [knownRoles] is the shipped role-registry id set; a profile naming a role
  /// outside it is a `profile.unknown_role` error. [overlayDirExists] tests
  /// whether a `templateOverlay` directory is present; a missing one is a
  /// `profile.overlay_missing` error. When [budgetCeiling] / [rateLimitCeiling]
  /// are given, a profile that exceeds them is *clamped* (not rejected, SC-8)
  /// and a message is passed to [warn] (when provided).
  ///
  /// Throws [ProfileConfigException] on the first unknown role / missing
  /// overlay.
  void validateAtBoot({
    required Set<String> knownRoles,
    required bool Function(String overlayName) overlayDirExists,
    ProfileBudget? budgetCeiling,
    ProfileRateLimits? rateLimitCeiling,
    void Function(String message)? warn,
  }) {
    for (final p in _profiles.values) {
      _validateProfile(
        p,
        knownRoles: knownRoles,
        overlayDirExists: overlayDirExists,
        budgetCeiling: budgetCeiling,
        rateLimitCeiling: rateLimitCeiling,
        warn: warn,
      );
    }
  }

  /// The per-profile environmental check shared by [validateAtBoot] and the
  /// runtime [author] path, so an authored profile passes exactly the boot
  /// gates (I-6). Throws on the first unknown role / missing overlay; a
  /// budget/rate-limit that exceeds the ceiling is *warned*, never rejected
  /// (SC-8 — the real clamp happens at [resolve]).
  static void _validateProfile(
    Profile p, {
    required Set<String> knownRoles,
    required bool Function(String overlayName) overlayDirExists,
    ProfileBudget? budgetCeiling,
    ProfileRateLimits? rateLimitCeiling,
    void Function(String message)? warn,
  }) {
    final role = p.role;
    if (role != null && !knownRoles.contains(role)) {
      throw ProfileConfigException(
        'profile "${p.id}" names unregistered role "$role"',
        code: 'profile.unknown_role',
        path: 'profiles.${p.id}.role',
      );
    }
    final overlay = p.templateOverlay;
    if (overlay != null && !overlayDirExists(overlay)) {
      throw ProfileConfigException(
        'profile "${p.id}" templateOverlay "$overlay" directory not found',
        code: 'profile.overlay_missing',
        path: 'profiles.${p.id}.templateOverlay',
      );
    }
    if (warn != null) {
      final clampedBudget = _clampBudget(p.budget, budgetCeiling);
      if (clampedBudget != p.budget) {
        warn('profile "${p.id}" budget exceeds the global ceiling; '
            'clamped to the ceiling (SC-8)');
      }
      final clampedRate = _clampRateLimits(p.rateLimits, rateLimitCeiling);
      if (clampedRate != p.rateLimits) {
        warn('profile "${p.id}" rateLimits exceed the global ceiling; '
            'clamped to the ceiling (SC-8)');
      }
    }
  }

  /// Authors [profile] into the registry at runtime — adds it, or replaces an
  /// existing profile with the same [Profile.id] (I-6, Phase 1).
  ///
  /// Validates the single profile against the **same** environmental gates as
  /// boot using the captured [context] (unknown `role` → `profile.unknown_role`,
  /// missing `templateOverlay` dir → `profile.overlay_missing`; an over-ceiling
  /// budget/rate-limit is warned, not rejected). Validation runs **before** the
  /// upsert, so a rejected author leaves the registry unchanged. `default` may
  /// be redefined this way (SC-Q18 / SC-Q20); it may not be [remove]d.
  ///
  /// This is the in-memory engine only: it does **not** persist. The durable
  /// write surface (Observatory `PUT` + on-disk `yaml_edit`) is the deferred
  /// Phase 2 (procedure § 24.8).
  void author(Profile profile, ProfileAuthoringContext context) {
    _validateProfile(
      profile,
      knownRoles: context.knownRoles,
      overlayDirExists: context.overlayDirExists,
      budgetCeiling: context.budgetCeiling,
      rateLimitCeiling: context.rateLimitCeiling,
      warn: context.warn,
    );
    _profiles[profile.id] = profile;
  }

  /// Removes the profile named [name] at runtime, returning whether one was
  /// present (I-6, Phase 1).
  ///
  /// Refuses to remove the built-in `default` — it must always exist (SC-5) —
  /// throwing [ProfileConfigException] (`profile.default_immutable`). Like
  /// [author], this mutates only the in-memory registry; persistence is the
  /// deferred Phase 2.
  bool remove(String name) {
    if (name == 'default') {
      throw const ProfileConfigException(
        'the built-in `default` profile cannot be removed; it must always '
        'exist (SC-5). It may be redefined via `author`.',
        code: 'profile.default_immutable',
        path: 'profiles.default',
      );
    }
    return _profiles.remove(name) != null;
  }

  /// Every profile's `defineMcpServers`, each rewritten to a profile-namespaced
  /// id (`<profileId>/<serverName>`), for the boot wiring to merge into the
  /// global `McpClient` registry (§ 3.6). Includes non-exposed defines (they are
  /// still reachable by inspection); exposure is decided per-server by the
  /// server's own `exposeToLlms` flag.
  List<McpServerConfig> get namespacedDefinedServers {
    final out = <McpServerConfig>[];
    for (final p in _profiles.values) {
      for (final s in p.defineMcpServers) {
        out.add(McpServerConfig(
          id: '${p.id}/${s.id}',
          transport: s.transport,
          description: s.description,
          command: s.command,
          args: s.args,
          url: s.url,
          headers: s.headers,
          exposeToLlms: s.exposeToLlms,
        ));
      }
    }
    return out;
  }

  // ── offered-MCP set (§ 3.6 / SCP-15) ────────────────────────────────

  List<String> _offeredFor(Profile p, Iterable<String> globalExposedIds) {
    final exposed = globalExposedIds.toSet();
    final allow = p.mcpServers;
    final definedExposed = <String>[
      for (final s in p.defineMcpServers)
        if (s.exposeToLlms) '${p.id}/${s.id}',
    ];
    if (allow.isEmpty && definedExposed.isEmpty) {
      // Both empty → the "all globally-exposed servers" sentinel (byte-compat
      // with today's behaviour / the `default` profile, SC-5).
      return const <String>[];
    }
    final globalPart = allow.isEmpty
        ? globalExposedIds.toList()
        : <String>[for (final id in allow) if (exposed.contains(id)) id];
    return <String>[...globalPart, ...definedExposed];
  }

  // ── budget / rate-limit clamp (SC-8 / SCP-12) ───────────────────────

  static ProfileBudget? _clampBudget(ProfileBudget? p, ProfileBudget? ceiling) {
    if (p == null || ceiling == null) return p;
    return ProfileBudget(
      maxLlmCalls: _clampInt(p.maxLlmCalls, ceiling.maxLlmCalls),
      maxToolCalls: _clampInt(p.maxToolCalls, ceiling.maxToolCalls),
      maxTokens: _clampInt(p.maxTokens, ceiling.maxTokens),
      wallClock: _clampDuration(p.wallClock, ceiling.wallClock),
    );
  }

  static ProfileRateLimits? _clampRateLimits(
    ProfileRateLimits? p,
    ProfileRateLimits? ceiling,
  ) {
    if (p == null || ceiling == null) return p;
    return ProfileRateLimits(
      requestsPerMinute:
          _clampInt(p.requestsPerMinute, ceiling.requestsPerMinute),
      concurrentRuns: _clampInt(p.concurrentRuns, ceiling.concurrentRuns),
    );
  }

  /// Field-wise tighten: a null profile value inherits (stays null); a null
  /// ceiling is no cap; otherwise the smaller of the two.
  static int? _clampInt(int? value, int? ceiling) {
    if (value == null || ceiling == null) return value;
    return value > ceiling ? ceiling : value;
  }

  static Duration? _clampDuration(Duration? value, Duration? ceiling) {
    if (value == null || ceiling == null) return value;
    return value > ceiling ? ceiling : value;
  }

  // ── per-profile parse ───────────────────────────────────────────────

  static Profile _parseProfile(
    String id,
    Map<Object?, Object?> map,
    YamlConfigReader reader,
  ) {
    final modePresent = map.containsKey('mode');
    final modeStr = reader.optionalString(map, 'mode', 'profiles.$id.mode');
    final mode = modeStr == null
        ? ProfileMode.cognitive
        : _parseMode(modeStr, 'profiles.$id.mode');
    final entryProcedure =
        reader.optionalString(map, 'entryProcedure', 'profiles.$id.entryProcedure');
    if (modePresent &&
        entryProcedure != null &&
        entryProcedure != mode.defaultEntryProcedure) {
      throw ProfileConfigException(
        'profile "$id" sets mode "${mode.wireName}" (default entry '
        '"${mode.defaultEntryProcedure}") and a conflicting entryProcedure '
        '"$entryProcedure"',
        code: 'profile.mode_entry_conflict',
        path: 'profiles.$id',
      );
    }
    return Profile(
      id: id,
      mode: mode,
      entryProcedure: entryProcedure,
      role: reader.optionalString(map, 'role', 'profiles.$id.role'),
      anchored:
          reader.optionalBool(map, 'anchored', 'profiles.$id.anchored') ?? true,
      templateOverlay: reader.optionalString(
          map, 'templateOverlay', 'profiles.$id.templateOverlay'),
      mcpServers: _stringList(reader, map, 'mcpServers', 'profiles.$id.mcpServers'),
      defineMcpServers: _parseDefines(reader, map, id),
      budget: _parseBudget(reader, map, id),
      rateLimits: _parseRateLimits(reader, map, id),
      defaultSession: reader.optionalString(
          map, 'defaultSession', 'profiles.$id.defaultSession'),
      defaultMemory:
          reader.optionalString(map, 'defaultMemory', 'profiles.$id.defaultMemory'),
    );
  }

  static ProfileMode _parseMode(String value, String path) {
    try {
      return ProfileMode.fromWire(value);
    } on ArgumentError {
      throw ProfileConfigException(
        'unknown profile mode "$value" (expected one of '
        '${ProfileMode.values.map((m) => m.wireName).join(', ')})',
        code: 'profile.unknown_mode',
        path: path,
      );
    }
  }

  static ProfileBudget? _parseBudget(
    YamlConfigReader reader,
    Map<Object?, Object?> map,
    String id,
  ) {
    final b = reader.optionalMap(map, 'budget');
    if (b == null) return null;
    final base = 'profiles.$id.budget';
    final wallSeconds =
        reader.optionalInt(b, 'wallClockSeconds', '$base.wallClockSeconds');
    return ProfileBudget(
      maxLlmCalls: reader.optionalInt(b, 'maxLlmCalls', '$base.maxLlmCalls'),
      maxToolCalls: reader.optionalInt(b, 'maxToolCalls', '$base.maxToolCalls'),
      maxTokens: reader.optionalInt(b, 'maxTokens', '$base.maxTokens'),
      wallClock: wallSeconds == null ? null : Duration(seconds: wallSeconds),
    );
  }

  static ProfileRateLimits? _parseRateLimits(
    YamlConfigReader reader,
    Map<Object?, Object?> map,
    String id,
  ) {
    final r = reader.optionalMap(map, 'rateLimits');
    if (r == null) return null;
    final base = 'profiles.$id.rateLimits';
    return ProfileRateLimits(
      requestsPerMinute:
          reader.optionalInt(r, 'requestsPerMinute', '$base.requestsPerMinute'),
      concurrentRuns:
          reader.optionalInt(r, 'concurrentRuns', '$base.concurrentRuns'),
    );
  }

  static List<McpServerConfig> _parseDefines(
    YamlConfigReader reader,
    Map<Object?, Object?> map,
    String id,
  ) {
    final raw = reader.optionalList(
        map, 'defineMcpServers', 'profiles.$id.defineMcpServers');
    if (raw == null) return const <McpServerConfig>[];
    final out = <McpServerConfig>[];
    final seen = <String>{};
    for (var i = 0; i < raw.length; i++) {
      final entry = raw[i];
      final path = 'profiles.$id.defineMcpServers[$i]';
      if (entry is! Map<Object?, Object?>) {
        throw ProfileConfigException(
          'define-server entry must be a map (got ${entry.runtimeType})',
          path: path,
        );
      }
      final sid = reader.requireString(entry, 'id', '$path.id');
      if (!seen.add(sid)) {
        throw ProfileConfigException(
          'duplicate define-server id "$sid"',
          path: '$path.id',
        );
      }
      out.add(McpServerConfig(
        id: sid,
        transport: _parseTransport(
          reader.requireString(entry, 'transport', '$path.transport'),
          '$path.transport',
        ),
        description:
            reader.optionalString(entry, 'description', '$path.description'),
        command: reader.optionalString(entry, 'command', '$path.command'),
        args: _stringList(reader, entry, 'args', '$path.args'),
        url: reader.optionalString(entry, 'url', '$path.url'),
        headers: _stringMap(reader, entry, 'headers', '$path.headers'),
        exposeToLlms:
            reader.optionalBool(entry, 'exposeToLlms', '$path.exposeToLlms') ??
                false,
      ));
    }
    return out;
  }

  static McpTransport _parseTransport(String value, String path) {
    for (final t in McpTransport.values) {
      if (t.name == value) return t;
    }
    final known = McpTransport.values.map((t) => t.name).join(', ');
    throw ProfileConfigException(
      'unknown transport "$value" (expected one of: $known)',
      path: path,
    );
  }

  static List<String> _stringList(
    YamlConfigReader reader,
    Map<Object?, Object?> node,
    String key,
    String path,
  ) {
    final raw = reader.optionalList(node, key, path);
    if (raw == null) return const <String>[];
    final out = <String>[];
    for (var i = 0; i < raw.length; i++) {
      final v = raw[i];
      if (v is! String) {
        throw ProfileConfigException(
          'list element must be a string (got ${v.runtimeType})',
          path: '$path[$i]',
        );
      }
      out.add(v);
    }
    return out;
  }

  static Map<String, String> _stringMap(
    YamlConfigReader reader,
    Map<Object?, Object?> node,
    String key,
    String path,
  ) {
    final raw = reader.optionalMap(node, key);
    if (raw == null) return const <String, String>{};
    final out = <String, String>{};
    for (final e in raw.entries) {
      final k = e.key;
      final v = e.value;
      if (k is! String || v is! String) {
        throw ProfileConfigException(
          'header map must be string→string',
          path: path,
        );
      }
      out[k] = v;
    }
    return out;
  }
}

/// The boot context a runtime [ProfileRegistry.author] call validates a profile
/// against — the same environmental dependencies [ProfileRegistry.validateAtBoot]
/// injects (I-6).
///
/// A consumer captures it once from the live boot context (the shipped
/// role-registry ids, the overlay-dir probe, the global budget/rate-limit
/// ceilings) and reuses it for every authoring call, so an authored profile
/// passes exactly the gates a config-loaded one does. [warn] receives the same
/// over-ceiling clamp notices boot logs (a `null` [warn] suppresses them).
final class ProfileAuthoringContext {
  /// The shipped role-registry id set; a profile naming a role outside it is a
  /// `profile.unknown_role` error.
  final Set<String> knownRoles;

  /// Tests whether a `templateOverlay` directory is present; a missing one is a
  /// `profile.overlay_missing` error.
  final bool Function(String overlayName) overlayDirExists;

  /// The global budget ceiling a profile may only *tighten* (SC-8); an
  /// over-ceiling value is warned (not rejected) and clamped at resolve.
  final ProfileBudget? budgetCeiling;

  /// The global rate-limit ceiling a profile may only *tighten* (SC-8).
  final ProfileRateLimits? rateLimitCeiling;

  /// Receives the over-ceiling clamp notices; `null` suppresses them.
  final void Function(String message)? warn;

  /// Captures the boot context for runtime authoring validation.
  const ProfileAuthoringContext({
    required this.knownRoles,
    required this.overlayDirExists,
    this.budgetCeiling,
    this.rateLimitCeiling,
    this.warn,
  });
}
