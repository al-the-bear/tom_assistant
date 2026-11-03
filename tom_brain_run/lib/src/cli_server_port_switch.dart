// The `/cli_server_port <port>` command: change the VS Code bridge / agent-SDK
// CLI-server port the running brain connects to, persisted to the run config.
//
// All the `agent_sdk` providers drive Claude Code through the *same* VS Code
// Scripting-API CLI server (the bridge), so they all carry the same
// `options.bridgePort` (19900 by default). When the bridge is restarted on a
// different port, every one of those providers must follow it. So a switch
// touches two surfaces:
//
//   1. The run config on disk — every `agent_sdk` provider row's
//      `options.bridgePort` is rewritten via comment-preserving `yaml_edit`, so
//      the new port survives a restart. ([CliServerPortConfigWriter].)
//   2. The live providers — each [AgentSdkSessionProvider]'s selector gets a
//      transport on the new port in place of the old one, which is closed; the
//      provider reaches the new port on its next call, and a session still on
//      the old transport restarts there. ([rebindAgentSdkProvider].)
//
// This file holds the two pieces that seam needs:
//
//   * [CliServerPortConfigWriter] — rewrites every `agent_sdk` provider's
//     `options.bridgePort` in the run-config file.
//   * [TomBrainCliServerPortController] — the run-layer
//     `TelegramCliServerPortController` impl: it validates the port range,
//     persists through the writer (when one is wired), rebinds the live
//     providers, and renders the outcome.

import 'dart:io';

import 'package:tom_brain_access/tom_brain_access.dart'
    show TelegramCliServerPortController;
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import 'package:tom_core_agentic/agent_sdk.dart'
    show AgentSdkSessionProvider, HostedCliServerAiTransport;

import 'brain_substrate_builder.dart' show brainCliServerTransport;

/// Moves [provider] to the CLI server on [port]: its selector's transport is
/// replaced by one on the new port (same host), and the old one closed.
///
/// Returns `true` when the port changed, `false` when the provider already
/// targets [port] (a no-op).
Future<bool> rebindAgentSdkProvider(
  AgentSdkSessionProvider provider,
  int port,
) async {
  final current = provider.selector.candidates
      .whereType<HostedCliServerAiTransport>()
      .first;
  if (current.minPort == port && current.maxPort == port) return false;
  await provider.selector.replaceCandidates([
    brainCliServerTransport(current.host, port),
  ]);
  return true;
}

/// Thrown when a `/cli_server_port` change cannot be written to the run config
/// on disk — a missing file, an unparseable one, or one with no `agent_sdk`
/// providers to re-point.
class CliServerPortWriteException implements Exception {
  /// Human-readable, located explanation.
  final String message;

  /// Builds the exception with a [message].
  const CliServerPortWriteException(this.message);

  @override
  String toString() => 'CliServerPortWriteException: $message';
}

/// Rewrites every `agent_sdk` provider's `options.bridgePort` in the run-config
/// YAML, preserving comments and formatting via `yaml_edit`'s surgical node
/// update.
///
/// Bound to the run-config [file] the process booted from. The writer owns the
/// on-disk encoding; [TomBrainCliServerPortController] owns the validation that
/// precedes it.
final class CliServerPortConfigWriter {
  /// The run-config file (the `brain_run.yaml` the process was started with).
  final File file;

  /// Binds the writer to the run-config [file].
  const CliServerPortConfigWriter(this.file);

  /// Rewrites every `substrate.providers[*]` of `kind: agent_sdk` so its
  /// `options.bridgePort` is [port], and writes the file back. Returns the
  /// number of provider rows changed.
  ///
  /// Throws [CliServerPortWriteException] when the file is missing, unparseable,
  /// has no `substrate.providers` list, or holds no `agent_sdk` provider.
  int apply(int port) {
    if (!file.existsSync()) {
      throw CliServerPortWriteException(
        'Run-config file "${file.path}" not found, so the port cannot be '
        'persisted.',
      );
    }
    final String source = file.readAsStringSync();
    final YamlEditor editor;
    final dynamic parsed;
    try {
      editor = YamlEditor(source);
      parsed = loadYaml(source);
    } on Object catch (e) {
      throw CliServerPortWriteException(
        'Could not parse run-config "${file.path}" to set the bridge port: $e',
      );
    }

    final providers = (parsed is YamlMap ? parsed['substrate'] : null);
    final list = (providers is YamlMap ? providers['providers'] : null);
    if (list is! YamlList) {
      throw CliServerPortWriteException(
        'Run-config "${file.path}" has no substrate.providers list to update.',
      );
    }

    var changed = 0;
    for (var i = 0; i < list.length; i++) {
      final row = list[i];
      if (row is! YamlMap) continue;
      if (row['kind'] != 'agent_sdk') continue;
      if (row['options'] is! YamlMap) continue;
      editor.update(
        ['substrate', 'providers', i, 'options', 'bridgePort'],
        port,
      );
      changed++;
    }

    if (changed == 0) {
      throw CliServerPortWriteException(
        'Run-config "${file.path}" holds no agent_sdk provider with an options '
        'map, so there is no bridge port to change.',
      );
    }

    file.writeAsStringSync(editor.toString());
    return changed;
  }
}

/// The run-layer `TelegramCliServerPortController` implementation behind
/// `/cli_server_port <port>`.
///
/// Validates the port range first, so an invalid switch is a rendered notice
/// rather than a corrupting write. On a valid port it persists through [writer]
/// (when one is wired) and then rebinds every live agent-SDK [providers] entry —
/// each closes its transport on the old port and reaches the new one at its
/// next call. The outcome string reports how many providers were
/// rebound and whether the change was persisted.
final class TomBrainCliServerPortController
    implements TelegramCliServerPortController {
  /// The live agent-SDK providers to rebind (the `agent_sdk` rows of the running
  /// substrate). May be empty when the deployment has no agent-SDK providers.
  final List<AgentSdkSessionProvider> providers;

  /// Persists the port to the run config, or `null` when the deployment has no
  /// run-config path to write into (the port then changes for this process only,
  /// not across a restart).
  final CliServerPortConfigWriter? configWriter;

  /// Builds the controller over the live [providers] and the optional config
  /// [configWriter].
  const TomBrainCliServerPortController({
    required this.providers,
    this.configWriter,
  });

  @override
  Future<String> setCliServerPort({required int port}) async {
    if (port < 1 || port > 65535) {
      return 'Port $port is out of range — give a TCP port between 1 and 65535 '
          '(the VS Code bridge default is 19900).';
    }

    // Persist first so a rebind failure does not leave the running process on a
    // port the config no longer names. A write failure is a rendered notice; the
    // live rebind still proceeds so the operator at least reconnects this run.
    String? persistNote;
    final writer = configWriter;
    if (writer == null) {
      persistNote = 'not persisted (this deployment has no run-config path), so '
          'this change lasts only until the next restart';
    } else {
      try {
        final int rows = writer.apply(port);
        persistNote = 'persisted to $rows provider entr'
            '${rows == 1 ? 'y' : 'ies'} in the run config (survives a restart)';
      } on CliServerPortWriteException catch (e) {
        persistNote = 'NOT persisted (${e.message})';
      }
    }

    var rebound = 0;
    for (final provider in providers) {
      if (await rebindAgentSdkProvider(provider, port)) rebound++;
    }

    final providerNote = providers.isEmpty
        ? 'no live agent-SDK providers to reconnect'
        : '$rebound of ${providers.length} agent-SDK provider'
            '${providers.length == 1 ? '' : 's'} reconnected on the new port';

    return 'CLI-server port set to $port — $providerNote; $persistNote.';
  }
}
