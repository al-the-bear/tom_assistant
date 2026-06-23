// appendApiKeyToRunConfig — the run-layer durable half of `/create_api_key`
// (memory_session_profiles.md § 7 / § 13, MSP-7, MSPP-42…47).
//
// The access layer mints the key and admits it live (its `AccessAssembler` is
// the registrar); only the run layer knows the run-config path on disk, so it
// supplies this closure as the durable half. It appends one `access.apiKeys[]`
// entry — `key` + `sessionPrefix` + `memoryPrefix`, the three fields the creator
// sets — through comment-preserving `yaml_edit`, exactly the `/switch_model` /
// `/cli_server_port` persistence precedent (`cli_server_port_switch.dart`).
//
// It **throws on any failure** (a missing/unparseable file, a non-map `access:`
// / non-list `apiKeys:`). That is the contract `ApiKeyPersist` relies on: the
// thrown exception is what triggers the access-side §13 rollback, so a key that
// cannot be written to disk is never left authenticating in the live process.

import 'dart:io';

import 'package:tom_brain_access/tom_brain_access.dart' show ApiKeyConfig;
import 'package:yaml/yaml.dart' show YamlNode;
import 'package:yaml_edit/yaml_edit.dart';

/// Thrown when a `/create_api_key` entry cannot be appended to the run config —
/// a missing file, an unparseable one, or one whose `access:` / `access.apiKeys`
/// shape is not the expected map / list.
class ApiKeyPersistException implements Exception {
  /// Human-readable, located explanation.
  final String message;

  /// Builds the exception with a [message].
  const ApiKeyPersistException(this.message);

  @override
  String toString() => 'ApiKeyPersistException: $message';
}

/// Appends [config] as a new `access.apiKeys[]` entry in the run-config [file],
/// preserving comments and formatting via `yaml_edit`'s surgical node update.
///
/// Creates the `access:` map and/or the `apiKeys:` list when either is absent,
/// and appends to an existing list otherwise — never rewriting sibling config.
/// Only the `key` / `sessionPrefix` / `memoryPrefix` the creator sets are
/// written (no `principal` / `displayName`), so the re-parsed entry resolves to
/// exactly the scope that was admitted live.
///
/// Throws [ApiKeyPersistException] when the file is missing, unparseable, or has
/// an `access:` / `access.apiKeys` of the wrong shape.
void appendApiKeyToRunConfig(File file, ApiKeyConfig config) {
  if (!file.existsSync()) {
    throw ApiKeyPersistException(
      'Run-config file "${file.path}" not found, so the API key cannot be '
      'persisted.',
    );
  }

  final String source = file.readAsStringSync();
  final YamlEditor editor;
  try {
    editor = YamlEditor(source);
  } on Object catch (e) {
    throw ApiKeyPersistException(
      'Could not parse run-config "${file.path}" to add the API key: $e',
    );
  }

  final Map<String, String> entry = <String, String>{
    'key': config.key,
    'sessionPrefix': config.sessionPrefix,
    'memoryPrefix': config.memoryPrefix,
  };

  final Object? accessValue =
      editor.parseAt(<Object>['access'], orElse: _nullNode).value;
  if (accessValue == null) {
    // No `access:` map at all — create it carrying just the apiKeys list.
    editor.update(<Object>['access'], <String, Object>{
      'apiKeys': <Object>[entry],
    });
  } else {
    if (accessValue is! Map) {
      throw ApiKeyPersistException(
        'Run-config "${file.path}" has an "access:" that is not a map '
        '(${accessValue.runtimeType}), so the API key cannot be added.',
      );
    }
    final Object? apiKeysValue =
        editor.parseAt(<Object>['access', 'apiKeys'], orElse: _nullNode).value;
    if (apiKeysValue == null) {
      // `access:` exists but no `apiKeys:` list — add the list (siblings kept).
      editor.update(<Object>['access', 'apiKeys'], <Object>[entry]);
    } else if (apiKeysValue is List) {
      editor.appendToList(<Object>['access', 'apiKeys'], entry);
    } else {
      throw ApiKeyPersistException(
        'Run-config "${file.path}" has an "access.apiKeys" that is not a list '
        '(${apiKeysValue.runtimeType}), so the API key cannot be added.',
      );
    }
  }

  file.writeAsStringSync(editor.toString());
}

/// The `orElse` for [YamlEditor.parseAt]: a wrapped `null` node, so an absent
/// path reads as `value == null` rather than throwing.
YamlNode _nullNode() => wrapAsYamlNode(null);
