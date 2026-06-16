// D4rt Bridge - Generated file, do not edit
// Delegating barrel for all
// Generated: 2026-06-16T15:49:49.818352

// ignore_for_file: unused_import, deprecated_member_use, sort_child_properties_last, invalid_use_of_protected_member, unnecessary_non_null_assertion, invalid_use_of_visible_for_testing_member

import 'package:tom_d4rt/d4rt.dart';
import 'package:tom_d4rt/tom_d4rt.dart';

import 'package_tom_brain_procedure_bridges.b.dart' as pkg_tom_brain_procedure;

/// Bridge class for all module.
class AllBridge {
  /// Returns all bridge class definitions.
  static List<BridgedClass> bridgeClasses() {
    return [
      ...pkg_tom_brain_procedure.PackageTomBrainProcedureBridge.bridgeClasses(),
    ];
  }

  /// Returns a map of class names to their canonical source URIs.
  ///
  /// Used for deduplication when the same class is exported through
  /// multiple barrels (e.g., tom_core_kernel and tom_core_server).
  static Map<String, String> classSourceUris() {
    return {
      ...pkg_tom_brain_procedure.PackageTomBrainProcedureBridge.classSourceUris(),
    };
  }

  /// Returns all bridged enum definitions.
  static List<BridgedEnumDefinition> bridgedEnums() {
    return [
      ...pkg_tom_brain_procedure.PackageTomBrainProcedureBridge.bridgedEnums(),
    ];
  }

  /// Returns all global functions.
  static Map<String, NativeFunctionImpl> globalFunctions() {
    return {
      ...pkg_tom_brain_procedure.PackageTomBrainProcedureBridge.globalFunctions(),
    };
  }

  /// Register all bridges with the interpreter.
  static void registerBridges(D4rt interpreter, String importPath) {
    pkg_tom_brain_procedure.PackageTomBrainProcedureBridge.registerBridges(interpreter, importPath);
  }

  /// Returns the import block for scripts.
  static String getImportBlock() {
    return "import 'package:tom_brain_procedure/src/bridges/memory_bridge.dart';\n";
  }

  /// Returns barrel import URIs for sub-packages with bridged content.
  static List<String> subPackageBarrels() {
    return const [];
  }
}
