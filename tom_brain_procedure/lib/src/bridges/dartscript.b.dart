// D4rt Bridge - Generated file, do not edit
// Dartscript registration for tom_brain_procedure
// Generated: 2026-06-16T15:49:49.819095

/// D4rt Bridge Registration for tom_brain_procedure
library;

import 'package:tom_d4rt/d4rt.dart';
import 'brain_bridges.b.dart' as all_bridges;
import 'relaxers.b.dart' as relaxer_factories;

/// Combined bridge registration for tom_brain_procedure.
class BrainBridges {
  /// Register all bridges with D4rt interpreter.
  static void register([D4rt? interpreter]) {
    final d4rt = interpreter ?? D4rt();

    all_bridges.AllBridge.registerBridges(
      d4rt,
      'package:tom_brain_procedure/src/bridges/memory_bridge.dart',
    );
    all_bridges.AllBridge.registerBridges(
      d4rt,
      'package:tom_brain_procedure/src/bridges/substrate_bridge.dart',
    );
    all_bridges.AllBridge.registerBridges(
      d4rt,
      'package:tom_brain_procedure/src/bridges/tool_bridge.dart',
    );
    all_bridges.AllBridge.registerBridges(
      d4rt,
      'package:tom_brain_procedure/src/bridges/mcp_bridge.dart',
    );
    all_bridges.AllBridge.registerBridges(
      d4rt,
      'package:tom_brain_procedure/src/bridges/vscode_scripting_bridge.dart',
    );
    all_bridges.AllBridge.registerBridges(
      d4rt,
      'package:tom_brain_procedure/src/budget/budget_view.dart',
    );
    // Register under sub-package barrels for direct imports
    for (final barrel in all_bridges.AllBridge.subPackageBarrels()) {
      all_bridges.AllBridge.registerBridges(d4rt, barrel);
    }

    // RC-2: Register generic constructor factories
    relaxer_factories.registerGenericConstructors();
    // GEN-079: Register relaxer wrapper factories
    relaxer_factories.registerRelaxers();
  }

  /// Get import block for all modules.
  static String getImportBlock() {
    final buffer = StringBuffer();
    buffer.writeln(all_bridges.AllBridge.getImportBlock());
    return buffer.toString();
  }
}
