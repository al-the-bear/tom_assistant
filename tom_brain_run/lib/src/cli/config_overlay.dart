// config_overlay.dart — the shared deep-merge + block-YAML emit the config
// resolution layer uses (CLI plan step #8; `tom_brain_cli.md` § 6 / § 9).
//
// Two callers need the *same* merge-and-re-emit discipline so each section
// loader stays the single authority over its own slice:
//
//   * `ProjectHome.buildConfig` (step 6) — deep-merges the `<home>/agent`
//     convention under the user's base config, then the CLI-flag overrides over
//     it, then re-emits the merged document for `BrainRunConfigLoader.parse`.
//   * `assembleServeConfig` (step 8) — in single-file mode, deep-merges the CLI
//     channel/`--set` overlay over the parsed `--config` file, then re-emits.
//
// Extracting the merge + emitter here keeps that one discipline in one place
// (DRY): a value that is a map recurses, any other value (list / scalar)
// replaces; the emitter renders a plain Map / List / scalar tree back to
// block-style YAML so each loader re-parses its own block.

/// Deep-merges [overlay] onto [base]; [overlay] wins. Two maps recurse; any
/// other value (list / scalar) replaces. Mirrors the merge discipline the
/// procedure config loaders use.
Map<Object?, Object?> deepMergeMaps(
  Map<Object?, Object?> base,
  Map<Object?, Object?> overlay,
) {
  final out = <Object?, Object?>{...base};
  for (final entry in overlay.entries) {
    final existing = out[entry.key];
    final incoming = entry.value;
    if (existing is Map<Object?, Object?> &&
        incoming is Map<Object?, Object?>) {
      out[entry.key] = deepMergeMaps(existing, incoming);
    } else {
      out[entry.key] = incoming;
    }
  }
  return out;
}

/// Sets [value] at the dotted [dottedKey] (e.g. `access.openai.port`) inside
/// [root], creating intermediate maps as needed — the `--set key=value` overlay
/// shape (CLI plan § 5.2). An intermediate that is not a map is replaced.
void setDottedKey(
  Map<Object?, Object?> root,
  String dottedKey,
  Object? value,
) {
  final parts = dottedKey.split('.');
  Map<Object?, Object?> node = root;
  for (var i = 0; i < parts.length - 1; i++) {
    final existing = node[parts[i]];
    if (existing is Map<Object?, Object?>) {
      node = existing;
    } else {
      final created = <Object?, Object?>{};
      node[parts[i]] = created;
      node = created;
    }
  }
  node[parts.last] = value;
}

// ── Minimal block-style YAML emitter ────────────────────────────────────────
//
// The merged document is a plain tree of Map / List / String / num / bool /
// null (the canonical `loadYamlAsMap` shape plus overlay scalars). The emitter
// renders it back to block-style YAML so each section loader can re-parse its
// own slice. It handles exactly those node kinds — anything else is a
// programming error in the overlay construction upstream.

/// Renders [doc] back to block-style YAML.
String emitYamlDoc(Map<Object?, Object?> doc) {
  final buf = StringBuffer();
  _emitMap(buf, doc, 0);
  return buf.toString();
}

void _emitMap(StringBuffer buf, Map<Object?, Object?> map, int indent) {
  final pad = '  ' * indent;
  for (final entry in map.entries) {
    final key = entry.key.toString();
    final value = entry.value;
    if (value is Map<Object?, Object?>) {
      if (value.isEmpty) {
        buf.writeln('$pad$key: {}');
      } else {
        buf.writeln('$pad$key:');
        _emitMap(buf, value, indent + 1);
      }
    } else if (value is List) {
      if (value.isEmpty) {
        buf.writeln('$pad$key: []');
      } else {
        buf.writeln('$pad$key:');
        _emitList(buf, value, indent + 1);
      }
    } else {
      buf.writeln('$pad$key: ${_scalar(value)}');
    }
  }
}

void _emitList(StringBuffer buf, List<Object?> list, int indent) {
  final pad = '  ' * indent;
  for (final item in list) {
    if (item is Map<Object?, Object?>) {
      if (item.isEmpty) {
        buf.writeln('$pad- {}');
      } else {
        buf.writeln('$pad-');
        _emitMap(buf, item, indent + 1);
      }
    } else if (item is List) {
      if (item.isEmpty) {
        buf.writeln('$pad- []');
      } else {
        buf.writeln('$pad-');
        _emitList(buf, item, indent + 1);
      }
    } else {
      buf.writeln('$pad- ${_scalar(item)}');
    }
  }
}

/// Renders a scalar for YAML emission, quoting strings that could be misread as
/// another type or that carry YAML-significant characters.
String _scalar(Object? value) {
  if (value == null) return 'null';
  if (value is bool || value is num) return value.toString();
  final s = value.toString();
  final needsQuote = s.isEmpty ||
      s != s.trim() ||
      const {'true', 'false', 'null', 'yes', 'no', '~'}
          .contains(s.toLowerCase()) ||
      RegExp(r'''^[\[\]{}#&*!|>%@`"']''').hasMatch(s) ||
      s.contains(': ') ||
      s.contains(' #') ||
      s.endsWith(':');
  if (!needsQuote) return s;
  return '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
}
