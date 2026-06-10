// DreamConfigLoader — parses the `dream:` section of the whole-process config
// into a `DreamConfig?` (item b).
//
// Loading goes through the canonical plain-map loader (`loadYamlAsMap`) so no
// `YamlMap`/`YamlList` node ever leaks into a `DreamConfig`. The loader is pure
// and deterministic, mirroring `ToolsConfigLoader` / `TrailConfigLoader`:
//
//   * No `dream:` block at all → returns `null`. The run assembly stands up no
//     dream loop.
//   * A `dream:` block present  → `enabled` defaults to `false`, `windows`
//     defaults to the empty (always-active) schedule, `heartbeatSeconds` is an
//     optional positive override.
//
// Each window slot is a `{start, end}` `HH:MM` map. The bound parsing lives in
// `DreamWindow.parse` (a `FormatException` on a malformed bound); the loader
// rewraps that into a located `DreamConfigException` naming the offending slot
// so the error points at `dream.windows[i]` rather than a bare format failure.

import 'package:tom_core_agentic/tom_core_agentic.dart'
    show MapFieldReader, loadYamlAsMap;

import 'dream_config.dart';
import 'dream_window_schedule.dart';

/// Parses the `dream:` section of the whole-process YAML into a [DreamConfig],
/// or `null` when no `dream:` block is present.
///
/// Namespace-only class (all members static): the loader has no per-instance
/// state, mirroring the sibling section loaders.
abstract final class DreamConfigLoader {
  DreamConfigLoader._();

  /// The keys a `dream:` block may carry. Any other key is a located error.
  static const Set<String> _allowedDreamKeys = <String>{
    'enabled',
    'windows',
    'heartbeatSeconds',
  };

  /// The keys a single `dream.windows[i]` slot may carry.
  static const Set<String> _allowedSlotKeys = <String>{'start', 'end'};

  static const MapFieldReader _reader = MapFieldReader(DreamConfigException.new);

  /// Parses the `dream:` section out of the whole-process [content].
  ///
  /// Reads only `doc['dream']`, tolerating sibling sections — the same
  /// re-parse-the-whole-document contract every section loader uses.
  ///
  /// Returns `null` when there is no `dream:` block. Pure: no I/O, no clock.
  ///
  /// Throws [DreamConfigException] (located) on a malformed block. [envVars] is
  /// accepted for signature parity with the sibling loaders; the `dream:`
  /// section carries no `${ENV}`-expandable values today.
  static DreamConfig? parse(
    String content, {
    Map<String, String> envVars = const {},
  }) {
    final Map<String, Object?> doc = loadYamlAsMap(
      content,
      rootPath: 'root',
      errorFactory: DreamConfigException.new,
    );
    if (doc['dream'] == null) return null;

    final Map<Object?, Object?> dream = _reader.mapValue(doc['dream'], 'dream')!;
    _rejectUnknownKeys(dream, _allowedDreamKeys, 'dream');

    final bool enabled =
        _reader.optionalBool(dream, 'enabled', 'dream.enabled') ?? false;

    final DreamWindowSchedule schedule = _parseWindows(dream);

    final num? heartbeatSeconds =
        _reader.optionalNum(dream, 'heartbeatSeconds', 'dream.heartbeatSeconds');
    if (heartbeatSeconds != null && heartbeatSeconds <= 0) {
      throw const DreamConfigException(
        'dream.heartbeatSeconds must be a positive number of seconds.',
      );
    }
    final Duration? heartbeat = heartbeatSeconds == null
        ? null
        : Duration(milliseconds: (heartbeatSeconds * 1000).round());

    return DreamConfig(
      enabled: enabled,
      schedule: schedule,
      heartbeat: heartbeat,
    );
  }

  /// Parses the optional `dream.windows` list into a [DreamWindowSchedule].
  ///
  /// An absent list ⇒ the empty (always-active) schedule. Each slot must hold a
  /// `start` and an `end` `HH:MM` string; a malformed bound surfaces as a
  /// located [DreamConfigException] naming the slot.
  static DreamWindowSchedule _parseWindows(Map<Object?, Object?> dream) {
    final List<Object?>? rawWindows =
        _reader.optionalList(dream, 'windows', 'dream.windows');
    if (rawWindows == null) {
      return DreamWindowSchedule(windows: const <DreamWindow>[]);
    }

    final List<DreamWindow> windows = <DreamWindow>[];
    for (var i = 0; i < rawWindows.length; i++) {
      final String slotPath = 'dream.windows[$i]';
      final Map<Object?, Object?> slot =
          _reader.mapValue(rawWindows[i], slotPath)!;
      _rejectUnknownKeys(slot, _allowedSlotKeys, slotPath);

      final String start =
          _reader.requireString(slot, 'start', '$slotPath.start');
      final String end = _reader.requireString(slot, 'end', '$slotPath.end');
      try {
        windows.add(DreamWindow.parse(start, end));
      } on FormatException catch (e) {
        throw DreamConfigException('$slotPath is malformed: ${e.message}');
      }
    }
    return DreamWindowSchedule(windows: windows);
  }

  /// Rejects any key in [map] outside [allowed], with a located error.
  static void _rejectUnknownKeys(
    Map<Object?, Object?> map,
    Set<String> allowed,
    String path,
  ) {
    for (final key in map.keys) {
      if (key is! String || !allowed.contains(key)) {
        throw DreamConfigException(
          'Unknown key "$key" under $path; allowed keys are '
          '${allowed.toList()}.',
        );
      }
    }
  }
}
