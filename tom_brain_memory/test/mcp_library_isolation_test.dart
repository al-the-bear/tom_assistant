// todo #5 — MCP-library isolation contract (server side).
//
// The underlying MCP wire library (`package:dart_mcp`) and the
// JSON-RPC error surface it leans on (`package:json_rpc_2`) must be
// reachable from exactly ONE file in `lib/`: the adapter. Every other
// server-side file imports MCP protocol types through that adapter, so
// swapping the library later is a localized change.
//
// This test is the enforcement mechanism for that invariant. It scans
// `lib/` for `import`/`export` directives that name either package and
// asserts the only file containing one is the adapter. It replaces the
// placeholder import-audit foreshadowed by the dependency-surface test.

import 'dart:io';

import 'package:test/test.dart';

void main() {
  group('MCP library isolation (todo #5)', () {
    // The single adapter file permitted to touch the MCP wire library.
    const adapterPath = 'lib/src/mcp_server/mcp_library_adapter.dart';

    // Matches an `import`/`export` directive (not a comment) whose URI
    // points at the MCP wire library or its JSON-RPC error surface.
    final directivePattern = RegExp(
      r'''^\s*(?:import|export)\s+['"]package:(?:dart_mcp|json_rpc_2)/''',
    );

    List<String> filesTouchingMcpLibrary() {
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final touches =
            entity.readAsLinesSync().any(directivePattern.hasMatch);
        if (touches) offenders.add(entity.path.replaceAll(r'\', '/'));
      }
      return offenders..sort();
    }

    test('the MCP-library adapter file exists', () {
      expect(
        File(adapterPath).existsSync(),
        isTrue,
        reason: 'the single MCP-library adapter must exist at $adapterPath',
      );
    });

    test('only the adapter imports dart_mcp / json_rpc_2', () {
      expect(
        filesTouchingMcpLibrary(),
        equals([adapterPath]),
        reason: 'dart_mcp / json_rpc_2 must be confined to the adapter so a '
            'library swap stays localized',
      );
    });
  });
}
