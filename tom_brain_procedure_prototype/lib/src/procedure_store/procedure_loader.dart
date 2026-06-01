// ProcedureLoader — parses a procedure's structured header (§ 4.4) out of
// its verbatim source (Plan step C.24;
// `tom_brain_procedure_prototype_specification.md` § 4.4, § 6).
//
// The loader sits directly above the store (C.23): the store hands back a
// `ProcedureSource` (raw bytes at a ref), the loader turns that source's
// `/// @procedure` doc-comment block into a typed [ProcedureHeader]. It
// does **not** parse or run the body, resolve versions (C.25), or run the
// deeper validator checks (C.27–C.29 — version monotonicity, sandbox,
// requires-vs-actual-calls). Its single job is: extract the header block,
// parse it as YAML, enforce the five required fields, and build the typed
// header. A header that is absent, unparseable, or missing a required
// field is rejected with [ProcedureHeaderInvalid] (`procedure.header.
// invalid`).
//
// Header grammar (§ 4.4): the block is a contiguous run of `///` lines
// beginning with a `@procedure` marker line; the remaining lines (after
// stripping the `/// ` prefix) are YAML:
//
//   /// @procedure
//   /// id: answer_with_memory_v1
//   /// version: 1
//   /// summary: ...
//   /// successCriterion: ...
//   /// inputs:
//   ///   - { name: text, type: String, required: true }
//   /// outputs:
//   ///   - { name: answer, type: String }
//   /// budget: { wallClockMs: 60000, tokenSpend: 8000, toolCalls: 12 }
//   /// requires: [ recall, llm, persist ]

import 'package:yaml/yaml.dart';

import 'procedure_header.dart';
import 'procedure_header_invalid.dart';
import 'procedure_ref.dart';
import 'procedure_source.dart';

/// A procedure's parsed header bundled with the ref it was loaded from and
/// its verbatim body source.
///
/// The loader's `load` produces this so callers (the resolver C.25, the
/// engine C.38) get the header *and* keep the link back to the physical
/// location and the source they will hand to the host. The header is the
/// contract; [source] is the same verbatim text the store returned (header
/// doc-comment + body), unchanged.
final class LoadedProcedure {
  /// Where the procedure was read from (origin + locator).
  final ProcedureRef ref;

  /// The parsed structured header.
  final ProcedureHeader header;

  /// The verbatim d4rt source (header doc-comment + body), exactly as the
  /// store returned it.
  final String source;

  const LoadedProcedure({
    required this.ref,
    required this.header,
    required this.source,
  });

  @override
  String toString() => 'LoadedProcedure(${header.id} v${header.version})';
}

/// Parses the structured header (§ 4.4) out of a procedure's source.
///
/// Stateless: every method is a pure function of its input. Construct once
/// and reuse, or use the [shared] instance.
final class ProcedureLoader {
  const ProcedureLoader();

  /// A shared, reusable loader (the loader holds no state).
  static const ProcedureLoader shared = ProcedureLoader();

  /// Parses [source]'s structured header into a [ProcedureHeader].
  ///
  /// Throws [ProcedureHeaderInvalid] when the source has no `@procedure`
  /// header block, the block is not valid YAML, or a required field (`id`,
  /// `version`, `summary`, `successCriterion`, `budget`) is missing or
  /// ill-typed.
  ProcedureHeader parse(String source) {
    final yamlText = _extractHeaderYaml(source);
    final node = _parseYaml(yamlText);
    return _buildHeader(node);
  }

  /// Parses [src]'s header and bundles it with the ref + verbatim source.
  ///
  /// Throws [ProcedureHeaderInvalid] under the same conditions as [parse].
  LoadedProcedure load(ProcedureSource src) => LoadedProcedure(
        ref: src.ref,
        header: parse(src.source),
        source: src.source,
      );

  // --- header extraction -------------------------------------------------

  /// Pulls the `///`-prefixed header block (starting at the `@procedure`
  /// marker) out of [source] and returns it as plain YAML text.
  ///
  /// The block is the contiguous run of doc-comment (`///`) lines that
  /// begins with the marker line and ends at the first line that is not a
  /// `///` doc-comment. The marker line itself is dropped; every other
  /// line has its `///` prefix (and one optional following space) removed.
  String _extractHeaderYaml(String source) {
    final lines = source.split('\n');
    var markerIndex = -1;
    for (var i = 0; i < lines.length; i++) {
      if (_isDocComment(lines[i]) &&
          _stripDocPrefix(lines[i]).trim() == '@procedure') {
        markerIndex = i;
        break;
      }
    }
    if (markerIndex == -1) {
      throw const ProcedureHeaderInvalid(
        'no `@procedure` header block found in source',
      );
    }

    final body = <String>[];
    for (var i = markerIndex + 1; i < lines.length; i++) {
      if (!_isDocComment(lines[i])) break;
      body.add(_stripDocPrefix(lines[i]));
    }
    return body.join('\n');
  }

  /// Whether [line] is a `///` doc-comment line (ignoring leading space).
  bool _isDocComment(String line) => line.trimLeft().startsWith('///');

  /// Removes the leading `///` (and one optional following space) from a
  /// doc-comment line, preserving the YAML indentation that follows.
  String _stripDocPrefix(String line) {
    final trimmed = line.trimLeft();
    var rest = trimmed.substring(3); // drop '///'
    if (rest.startsWith(' ')) rest = rest.substring(1);
    return rest;
  }

  // --- yaml parsing + field extraction -----------------------------------

  YamlMap _parseYaml(String yamlText) {
    if (yamlText.trim().isEmpty) {
      throw const ProcedureHeaderInvalid(
        '`@procedure` header block is empty',
      );
    }
    final Object? doc;
    try {
      doc = loadYaml(yamlText);
    } on YamlException catch (e) {
      throw ProcedureHeaderInvalid('header is not valid YAML: ${e.message}');
    }
    if (doc is! YamlMap) {
      throw const ProcedureHeaderInvalid(
        'header must be a mapping of fields',
      );
    }
    return doc;
  }

  ProcedureHeader _buildHeader(YamlMap node) {
    final id = _requiredString(node, 'id');
    final version = _requiredInt(node, 'version');
    final summary = _requiredString(node, 'summary');
    final successCriterion = _requiredString(node, 'successCriterion');
    final budget = _requiredBudget(node);

    return ProcedureHeader(
      id: id,
      version: version,
      summary: summary,
      successCriterion: successCriterion,
      budget: budget,
      inputs: _parseInputs(node),
      outputs: _parseOutputs(node),
      requires: _parseRequires(node),
    );
  }

  String _requiredString(YamlMap node, String field) {
    if (!node.containsKey(field)) {
      throw ProcedureHeaderInvalid('required field is missing', field: field);
    }
    final value = node[field];
    if (value is! String || value.trim().isEmpty) {
      throw ProcedureHeaderInvalid(
        'must be a non-empty string',
        field: field,
      );
    }
    return value;
  }

  int _requiredInt(YamlMap node, String field) {
    if (!node.containsKey(field)) {
      throw ProcedureHeaderInvalid('required field is missing', field: field);
    }
    final value = node[field];
    if (value is! int) {
      throw ProcedureHeaderInvalid('must be an integer', field: field);
    }
    return value;
  }

  ProcedureBudget _requiredBudget(YamlMap node) {
    const field = 'budget';
    if (!node.containsKey(field)) {
      throw const ProcedureHeaderInvalid(
        'required field is missing',
        field: field,
      );
    }
    final value = node[field];
    if (value is! YamlMap) {
      throw const ProcedureHeaderInvalid(
        'must be a mapping of caps',
        field: field,
      );
    }
    if (value.isEmpty) {
      throw const ProcedureHeaderInvalid(
        'must declare at least one cap',
        field: field,
      );
    }
    final caps = <String, int>{};
    for (final entry in value.nodes.entries) {
      final key = (entry.key as YamlNode).value;
      final capValue = entry.value.value;
      if (key is! String) {
        throw const ProcedureHeaderInvalid(
          'cap names must be strings',
          field: field,
        );
      }
      if (capValue is! int) {
        throw ProcedureHeaderInvalid(
          'cap "$key" must be an integer',
          field: field,
        );
      }
      caps[key] = capValue;
    }
    return ProcedureBudget(caps);
  }

  List<ProcedureInputDecl> _parseInputs(YamlMap node) {
    final list = _optionalList(node, 'inputs');
    return list
        .map((entry) => _asEntryMap(entry, 'inputs'))
        .map((map) => ProcedureInputDecl(
              name: _entryString(map, 'name', 'inputs'),
              type: _entryString(map, 'type', 'inputs'),
              required: _entryBool(map, 'required', 'inputs'),
            ))
        .toList(growable: false);
  }

  List<ProcedureOutputDecl> _parseOutputs(YamlMap node) {
    final list = _optionalList(node, 'outputs');
    return list
        .map((entry) => _asEntryMap(entry, 'outputs'))
        .map((map) => ProcedureOutputDecl(
              name: _entryString(map, 'name', 'outputs'),
              type: _entryString(map, 'type', 'outputs'),
            ))
        .toList(growable: false);
  }

  List<String> _parseRequires(YamlMap node) {
    final list = _optionalList(node, 'requires');
    return list.map((entry) {
      if (entry is! String || entry.trim().isEmpty) {
        throw const ProcedureHeaderInvalid(
          'entries must be non-empty primitive names',
          field: 'requires',
        );
      }
      return entry;
    }).toList(growable: false);
  }

  /// Returns the value of an optional list-valued [field] as a plain
  /// `List`, or an empty list when the field is absent. Rejects a present
  /// field whose value is not a list.
  List<Object?> _optionalList(YamlMap node, String field) {
    if (!node.containsKey(field) || node[field] == null) {
      return const <Object?>[];
    }
    final value = node[field];
    if (value is! YamlList) {
      throw ProcedureHeaderInvalid('must be a list', field: field);
    }
    return value.map((e) => e is YamlNode ? e.value : e).toList();
  }

  Map<Object?, Object?> _asEntryMap(Object? entry, String field) {
    if (entry is YamlMap) return entry.value;
    if (entry is Map) return entry;
    throw ProcedureHeaderInvalid(
      'each entry must be a mapping',
      field: field,
    );
  }

  String _entryString(Map<Object?, Object?> map, String key, String field) {
    final value = map[key];
    if (value is! String || value.trim().isEmpty) {
      throw ProcedureHeaderInvalid(
        'entry "$key" must be a non-empty string',
        field: field,
      );
    }
    return value;
  }

  bool _entryBool(Map<Object?, Object?> map, String key, String field) {
    if (!map.containsKey(key) || map[key] == null) return false;
    final value = map[key];
    if (value is! bool) {
      throw ProcedureHeaderInvalid(
        'entry "$key" must be a boolean',
        field: field,
      );
    }
    return value;
  }
}
