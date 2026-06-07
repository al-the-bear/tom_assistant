// D4rt Bridge - Generated file, do not edit
// Sources: 4 files
// Generated: 2026-06-07T14:11:26.040992

// ignore_for_file: unused_import, deprecated_member_use, prefer_function_declarations_over_variables, implementation_imports, sort_child_properties_last, non_constant_identifier_names, avoid_function_literals_in_foreach_calls, invalid_use_of_protected_member, unnecessary_non_null_assertion, invalid_use_of_visible_for_testing_member

import 'package:tom_d4rt/d4rt.dart';
import 'package:tom_d4rt/tom_d4rt.dart';
import 'dart:async';

import 'package:tom_brain_procedure_prototype/src/bridges/bridge_call_recorder.dart' as $tom_brain_procedure_prototype_1;
import 'package:tom_brain_procedure_prototype/src/bridges/mcp_bridge.dart' as $tom_brain_procedure_prototype_2;
import 'package:tom_brain_procedure_prototype/src/bridges/memory_bridge.dart' as $tom_brain_procedure_prototype_3;
import 'package:tom_brain_procedure_prototype/src/bridges/substrate_bridge.dart' as $tom_brain_procedure_prototype_4;
import 'package:tom_brain_procedure_prototype/src/bridges/tool_bridge.dart' as $tom_brain_procedure_prototype_5;
import 'package:tom_brain_procedure_prototype/src/budget/budget_ledger.dart' as $tom_brain_procedure_prototype_6;
import 'package:tom_brain_procedure_prototype/src/mcp/mcp_client.dart' as $tom_brain_procedure_prototype_7;
import 'package:tom_brain_procedure_prototype/src/tools/tool_context.dart' as $tom_brain_procedure_prototype_8;
import 'package:tom_brain_procedure_prototype/src/tools/tool_policy.dart' as $tom_brain_procedure_prototype_9;
import 'package:tom_brain_procedure_prototype/src/tools/tool_registry.dart' as $tom_brain_procedure_prototype_10;
import 'package:tom_brain_shared/src/budget/budget.dart' as $tom_brain_shared_1;
import 'package:tom_brain_shared/src/memory/api/tom_brain_memory_client.dart' as $tom_brain_shared_2;
import 'package:tom_brain_substrate/src/api/tom_brain_substrate_client.dart' as $tom_brain_substrate_1;

/// Bridge class for package_tom_brain_procedure_prototype module.
class PackageTomBrainProcedurePrototypeBridge {
  /// Returns all bridge class definitions.
  static List<BridgedClass> bridgeClasses() {
    return [
      _createMemoryBridgeBridge(),
      _createSubstrateBridgeBridge(),
      _createLlmCompletionFailureBridge(),
      _createToolBridgeBridge(),
      _createMcpBridgeBridge(),
    ];
  }

  /// Returns a map of class names to their canonical source URIs.
  ///
  /// Used for deduplication when the same class is exported through
  /// multiple barrels (e.g., tom_core_kernel and tom_core_server).
  static Map<String, String> classSourceUris() {
    return {
      'MemoryBridge': 'package:tom_brain_procedure_prototype/src/bridges/memory_bridge.dart',
      'SubstrateBridge': 'package:tom_brain_procedure_prototype/src/bridges/substrate_bridge.dart',
      'LlmCompletionFailure': 'package:tom_brain_procedure_prototype/src/bridges/substrate_bridge.dart',
      'ToolBridge': 'package:tom_brain_procedure_prototype/src/bridges/tool_bridge.dart',
      'McpBridge': 'package:tom_brain_procedure_prototype/src/bridges/mcp_bridge.dart',
    };
  }

  /// Returns a map of type alias names to their target class names.
  ///
  /// Type aliases like `typedef MaterialStateProperty<T> = WidgetStateProperty<T>`
  /// are registered so that code using the alias name can resolve to the
  /// bridged class under its canonical name.
  static Map<String, String> classAliases() {
    return {
    };
  }

  /// Returns the list of function typedef names declared in this library.
  ///
  /// Function typedefs like `typedef VoidCallback = void Function()` are
  /// registered so that they can be used as type arguments in D4rt scripts.
  static List<String> functionTypedefs() {
    return [
      'BridgeCallRecorder',
      'SubstrateTokenSink',
    ];
  }

  /// Returns all bridged enum definitions.
  static List<BridgedEnumDefinition> bridgedEnums() {
    return [
    ];
  }

  /// Returns a map of enum names to their canonical source URIs.
  ///
  /// Used for deduplication when the same enum is exported through
  /// multiple barrels (e.g., tom_core_kernel and tom_core_server).
  static Map<String, String> enumSourceUris() {
    return {
    };
  }

  /// Returns all bridged extension definitions.
  static List<BridgedExtensionDefinition> bridgedExtensions() {
    return [
    ];
  }

  /// Returns a map of extension identifiers to their canonical source URIs.
  static Map<String, String> extensionSourceUris() {
    return {
    };
  }

  /// GEN-107: Library re-exports declared by the bridged source
  /// libraries. Each tuple mirrors a Dart `export '…'` directive.
  /// Consumed by `registerBridges` via `D4rt.registerLibraryReExport`
  /// (mirrored on `D4rtRunner` in tom_d4rt_ast).
  static List<({String source, String target, Set<String>? show, Set<String>? hide})>
  bridgeReExports() {
    return [
    ];
  }

  /// Registers all bridges with an interpreter.
  ///
  /// [importPath] is the package import path that D4rt scripts will use
  /// to access these classes (e.g., 'package:tom_build/tom.dart').
  static void registerBridges(D4rt interpreter, String importPath) {
    // Register bridged classes with source URIs for deduplication
    final classes = bridgeClasses();
    final classSources = classSourceUris();
    for (final bridge in classes) {
      interpreter.registerBridgedClass(bridge, importPath, sourceUri: classSources[bridge.name]);
    }

    // Register function typedefs for type resolution
    final typedefs = functionTypedefs();
    for (final name in typedefs) {
      interpreter.registerFunctionTypedef(name, importPath);
    }
  }

  /// Returns a map of global function names to their native implementations.
  static Map<String, NativeFunctionImpl> globalFunctions() {
    return {};
  }

  /// Returns a map of global function names to their canonical source URIs.
  static Map<String, String> globalFunctionSourceUris() {
    return {};
  }

  /// Returns a map of global function names to their display signatures.
  static Map<String, String> globalFunctionSignatures() {
    return {};
  }

  /// Returns the list of canonical source library URIs.
  ///
  /// These are the actual source locations of all elements in this bridge,
  /// used for deduplication when the same libraries are exported through
  /// multiple barrels.
  static List<String> sourceLibraries() {
    return [
      'package:tom_brain_procedure_prototype/src/bridges/mcp_bridge.dart',
      'package:tom_brain_procedure_prototype/src/bridges/memory_bridge.dart',
      'package:tom_brain_procedure_prototype/src/bridges/substrate_bridge.dart',
      'package:tom_brain_procedure_prototype/src/bridges/tool_bridge.dart',
    ];
  }

}

// =============================================================================
// MemoryBridge Bridge
// =============================================================================

BridgedClass _createMemoryBridgeBridge() {
  return BridgedClass(
    nativeType: $tom_brain_procedure_prototype_3.MemoryBridge,
    name: 'MemoryBridge',
    isAssignable: (v) => v is $tom_brain_procedure_prototype_3.MemoryBridge,
    constructors: {
      '': (visitor, positional, named) {
        D4.requireMinArgs(positional, 1, 'MemoryBridge');
        final client = D4.getRequiredArg<$tom_brain_shared_2.TomBrainMemoryClient>(positional, 0, 'client', 'MemoryBridge');
        final onCallRaw = named['onCall'];
        final budget = D4.getOptionalNamedArg<$tom_brain_procedure_prototype_6.BudgetLedger?>(named, 'budget');
        final agentName = D4.getOptionalNamedArg<String?>(named, 'agentName');
        return $tom_brain_procedure_prototype_3.MemoryBridge(client, onCall: onCallRaw == null ? null : (String p0, Map<String, Object?> p1, Map<String, Object?> p2, {int? elapsedMs}) { return Future.value(D4.callInterpreterCallback(visitor!, onCallRaw, [p0, p1, p2], {'elapsedMs': elapsedMs})); }, budget: budget, agentName: agentName);
      },
    },
    getters: {
      'client': (visitor, target) => D4.validateTarget<$tom_brain_procedure_prototype_3.MemoryBridge>(target, 'MemoryBridge').client,
      'agentName': (visitor, target) => D4.validateTarget<$tom_brain_procedure_prototype_3.MemoryBridge>(target, 'MemoryBridge').agentName,
    },
    methods: {
      'recall': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_3.MemoryBridge>(target, 'MemoryBridge');
        D4.requireMinArgs(positional, 1, 'recall');
        final text = D4.getRequiredArg<String>(positional, 0, 'text', 'recall');
        final k = D4.getNamedArgWithDefault<int>(named, 'k', 8);
        if (!named.containsKey('modes')) {
          return t.recall(text, k: k);
        }
        if (named.containsKey('modes')) {
          final modes = D4.coerceList<String>(named['modes'], 'modes');
          return t.recall(text, k: k, modes: modes);
        }
        throw StateError('Unreachable: all named parameter combinations should be covered');
      },
      'classify': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_3.MemoryBridge>(target, 'MemoryBridge');
        D4.requireMinArgs(positional, 1, 'classify');
        if (positional.isEmpty) {
          throw ArgumentError('classify: Missing required argument "embedding" at position 0');
        }
        final embedding = D4.coerceList<double>(positional[0], 'embedding');
        final target_ = D4.getNamedArgWithDefault<String>(named, 'target', 'nodeType');
        return t.classify(embedding, target: target_);
      },
      'persist': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_3.MemoryBridge>(target, 'MemoryBridge');
        D4.requireMinArgs(positional, 2, 'persist');
        final typeName = D4.getRequiredArg<String>(positional, 0, 'typeName', 'persist');
        if (positional.length <= 1) {
          throw ArgumentError('persist: Missing required argument "values" at position 1');
        }
        final values = D4.coerceMap<String, Object?>(positional[1], 'values');
        final producer = D4.getRequiredNamedArg<String>(named, 'producer', 'persist');
        final idempotencyKey = D4.getOptionalNamedArg<String?>(named, 'idempotencyKey');
        final causedBy = D4.getOptionalNamedArg<String?>(named, 'causedBy');
        final runId = D4.getOptionalNamedArg<String?>(named, 'runId');
        final embedding = D4.coerceListOrNull<double>(named['embedding'], 'embedding');
        return t.persist(typeName, values, producer: producer, idempotencyKey: idempotencyKey, causedBy: causedBy, runId: runId, embedding: embedding);
      },
      'edge': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_3.MemoryBridge>(target, 'MemoryBridge');
        D4.requireMinArgs(positional, 3, 'edge');
        final from = D4.getRequiredArg<String>(positional, 0, 'from', 'edge');
        final type = D4.getRequiredArg<String>(positional, 1, 'type', 'edge');
        final to = D4.getRequiredArg<String>(positional, 2, 'to', 'edge');
        final producer = D4.getRequiredNamedArg<String>(named, 'producer', 'edge');
        final weight = D4.getNamedArgWithDefault<double>(named, 'weight', 1.0);
        final idempotencyKey = D4.getOptionalNamedArg<String?>(named, 'idempotencyKey');
        final causedBy = D4.getOptionalNamedArg<String?>(named, 'causedBy');
        final runId = D4.getOptionalNamedArg<String?>(named, 'runId');
        final attrs = D4.coerceMapOrNull<String, Object?>(named['attrs'], 'attrs');
        return t.edge(from, type, to, producer: producer, weight: weight, idempotencyKey: idempotencyKey, causedBy: causedBy, runId: runId, attrs: attrs);
      },
      'proposeNodeType': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_3.MemoryBridge>(target, 'MemoryBridge');
        D4.requireMinArgs(positional, 1, 'proposeNodeType');
        if (positional.isEmpty) {
          throw ArgumentError('proposeNodeType: Missing required argument "decl" at position 0');
        }
        final decl = D4.coerceMap<String, Object?>(positional[0], 'decl');
        return t.proposeNodeType(decl);
      },
      'stackList': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_3.MemoryBridge>(target, 'MemoryBridge');
        return t.stackList();
      },
      'stackCreate': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_3.MemoryBridge>(target, 'MemoryBridge');
        D4.requireMinArgs(positional, 1, 'stackCreate');
        if (positional.isEmpty) {
          throw ArgumentError('stackCreate: Missing required argument "decl" at position 0');
        }
        final decl = D4.coerceMap<String, Object?>(positional[0], 'decl');
        return t.stackCreate(decl);
      },
      'stackPush': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_3.MemoryBridge>(target, 'MemoryBridge');
        D4.requireMinArgs(positional, 2, 'stackPush');
        final name = D4.getRequiredArg<String>(positional, 0, 'name', 'stackPush');
        final nodeId = D4.getRequiredArg<String>(positional, 1, 'nodeId', 'stackPush');
        final priority = D4.getNamedArgWithDefault<double>(named, 'priority', 0.0);
        final attrs = D4.coerceMapOrNull<String, Object?>(named['attrs'], 'attrs');
        final producer = D4.getOptionalNamedArg<String?>(named, 'producer');
        final runId = D4.getOptionalNamedArg<String?>(named, 'runId');
        return t.stackPush(name, nodeId, priority: priority, attrs: attrs, producer: producer, runId: runId);
      },
      'stackPeek': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_3.MemoryBridge>(target, 'MemoryBridge');
        D4.requireMinArgs(positional, 1, 'stackPeek');
        final name = D4.getRequiredArg<String>(positional, 0, 'name', 'stackPeek');
        final k = D4.getNamedArgWithDefault<int>(named, 'k', 16);
        return t.stackPeek(name, k: k);
      },
      'stackPop': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_3.MemoryBridge>(target, 'MemoryBridge');
        D4.requireMinArgs(positional, 1, 'stackPop');
        final name = D4.getRequiredArg<String>(positional, 0, 'name', 'stackPop');
        return t.stackPop(name);
      },
      'stackUpdate': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_3.MemoryBridge>(target, 'MemoryBridge');
        D4.requireMinArgs(positional, 2, 'stackUpdate');
        final name = D4.getRequiredArg<String>(positional, 0, 'name', 'stackUpdate');
        final nodeId = D4.getRequiredArg<String>(positional, 1, 'nodeId', 'stackUpdate');
        final priority = D4.getOptionalNamedArg<double?>(named, 'priority');
        final status = D4.getOptionalNamedArg<String?>(named, 'status');
        final attrs = D4.coerceMapOrNull<String, Object?>(named['attrs'], 'attrs');
        return t.stackUpdate(name, nodeId, priority: priority, status: status, attrs: attrs);
      },
      'stackRemove': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_3.MemoryBridge>(target, 'MemoryBridge');
        D4.requireMinArgs(positional, 2, 'stackRemove');
        final name = D4.getRequiredArg<String>(positional, 0, 'name', 'stackRemove');
        final nodeId = D4.getRequiredArg<String>(positional, 1, 'nodeId', 'stackRemove');
        return t.stackRemove(name, nodeId);
      },
      'demote': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_3.MemoryBridge>(target, 'MemoryBridge');
        D4.requireMinArgs(positional, 2, 'demote');
        final nodeId = D4.getRequiredArg<String>(positional, 0, 'nodeId', 'demote');
        final reason = D4.getRequiredArg<String>(positional, 1, 'reason', 'demote');
        return t.demote(nodeId, reason);
      },
      'updateCentroid': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_3.MemoryBridge>(target, 'MemoryBridge');
        D4.requireMinArgs(positional, 2, 'updateCentroid');
        final forKey = D4.getRequiredArg<String>(positional, 0, 'forKey', 'updateCentroid');
        if (positional.length <= 1) {
          throw ArgumentError('updateCentroid: Missing required argument "centroid" at position 1');
        }
        final centroid = D4.coerceList<double>(positional[1], 'centroid');
        return t.updateCentroid(forKey, centroid);
      },
      'findUncertain': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_3.MemoryBridge>(target, 'MemoryBridge');
        D4.requireMinArgs(positional, 1, 'findUncertain');
        final forKey = D4.getRequiredArg<String>(positional, 0, 'forKey', 'findUncertain');
        final low = D4.getRequiredNamedArg<double>(named, 'low', 'findUncertain');
        final high = D4.getRequiredNamedArg<double>(named, 'high', 'findUncertain');
        final limit = D4.getNamedArgWithDefault<int>(named, 'limit', 200);
        return t.findUncertain(forKey, low: low, high: high, limit: limit);
      },
    },
    constructorSignatures: {
      '': 'MemoryBridge(TomBrainMemoryClient client, {BridgeCallRecorder? onCall, BudgetLedger? budget, String? agentName})',
    },
    methodSignatures: {
      'recall': 'Future<Map<String, Object?>> recall(String text, {List<String> modes = const <String>[\'bm25\', \'vector\'], int k = 8})',
      'classify': 'Future<Map<String, Object?>> classify(List<double> embedding, {String target = \'nodeType\'})',
      'persist': 'Future<String> persist(String typeName, Map<String, Object?> values, {required String producer, String? idempotencyKey, String? causedBy, String? runId, List<double>? embedding})',
      'edge': 'Future<String> edge(String from, String type, String to, {required String producer, double weight = 1.0, String? idempotencyKey, String? causedBy, String? runId, Map<String, Object?>? attrs})',
      'proposeNodeType': 'Future<void> proposeNodeType(Map<String, Object?> decl)',
      'stackList': 'Future<List<Map<String, Object?>>> stackList()',
      'stackCreate': 'Future<void> stackCreate(Map<String, Object?> decl)',
      'stackPush': 'Future<String> stackPush(String name, String nodeId, {double priority = 0.0, Map<String, Object?>? attrs, String? producer, String? runId})',
      'stackPeek': 'Future<List<Map<String, Object?>>> stackPeek(String name, {int k = 16})',
      'stackPop': 'Future<Map<String, Object?>?> stackPop(String name)',
      'stackUpdate': 'Future<void> stackUpdate(String name, String nodeId, {double? priority, String? status, Map<String, Object?>? attrs})',
      'stackRemove': 'Future<void> stackRemove(String name, String nodeId)',
      'demote': 'Future<void> demote(String nodeId, String reason)',
      'updateCentroid': 'Future<void> updateCentroid(String forKey, List<double> centroid)',
      'findUncertain': 'Future<List<String>> findUncertain(String forKey, {required double low, required double high, int limit = 200})',
    },
    getterSignatures: {
      'client': 'TomBrainMemoryClient get client',
      'agentName': 'String? get agentName',
    },
  );
}

// =============================================================================
// SubstrateBridge Bridge
// =============================================================================

BridgedClass _createSubstrateBridgeBridge() {
  return BridgedClass(
    nativeType: $tom_brain_procedure_prototype_4.SubstrateBridge,
    name: 'SubstrateBridge',
    isAssignable: (v) => v is $tom_brain_procedure_prototype_4.SubstrateBridge,
    constructors: {
      '': (visitor, positional, named) {
        D4.requireMinArgs(positional, 1, 'SubstrateBridge');
        final client = D4.getRequiredArg<$tom_brain_substrate_1.TomBrainSubstrateClient>(positional, 0, 'client', 'SubstrateBridge');
        final onCallRaw = named['onCall'];
        final onTokenRaw = named['onToken'];
        final budget = D4.getOptionalNamedArg<$tom_brain_procedure_prototype_6.BudgetLedger?>(named, 'budget');
        return $tom_brain_procedure_prototype_4.SubstrateBridge(client, onCall: onCallRaw == null ? null : (String p0, Map<String, Object?> p1, Map<String, Object?> p2, {int? elapsedMs}) { return Future.value(D4.callInterpreterCallback(visitor!, onCallRaw, [p0, p1, p2], {'elapsedMs': elapsedMs})); }, onToken: onTokenRaw == null ? null : ((String p0) { return Future.value(D4.callInterpreterCallback(visitor!, onTokenRaw, [p0])); }) as Future<void> Function(String), budget: budget);
      },
    },
    getters: {
      'client': (visitor, target) => D4.validateTarget<$tom_brain_procedure_prototype_4.SubstrateBridge>(target, 'SubstrateBridge').client,
    },
    methods: {
      'llm': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_4.SubstrateBridge>(target, 'SubstrateBridge');
        D4.requireMinArgs(positional, 1, 'llm');
        final prompt = D4.getRequiredArg<String>(positional, 0, 'prompt', 'llm');
        final budget = D4.coerceMapOrNull<String, Object?>(named['budget'], 'budget');
        if (!named.containsKey('role')) {
          return t.llm(prompt, budget: budget);
        }
        if (named.containsKey('role')) {
          final role = D4.getRequiredNamedArg<String>(named, 'role', 'llm');
          return t.llm(prompt, budget: budget, role: role);
        }
        throw StateError('Unreachable: all named parameter combinations should be covered');
      },
      'embed': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_4.SubstrateBridge>(target, 'SubstrateBridge');
        D4.requireMinArgs(positional, 1, 'embed');
        final text = D4.getRequiredArg<String>(positional, 0, 'text', 'embed');
        return t.embed(text);
      },
      'search': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_4.SubstrateBridge>(target, 'SubstrateBridge');
        D4.requireMinArgs(positional, 1, 'search');
        final query = D4.getRequiredArg<String>(positional, 0, 'query', 'search');
        final provider = D4.getOptionalNamedArg<String?>(named, 'provider');
        final k = D4.getNamedArgWithDefault<int>(named, 'k', 10);
        return t.search(query, provider: provider, k: k);
      },
      'fetch': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_4.SubstrateBridge>(target, 'SubstrateBridge');
        D4.requireMinArgs(positional, 1, 'fetch');
        final url = D4.getRequiredArg<String>(positional, 0, 'url', 'fetch');
        final budgetBytes = D4.getOptionalNamedArg<int?>(named, 'budgetBytes');
        return t.fetch(url, budgetBytes: budgetBytes);
      },
    },
    staticGetters: {
      'defaultRole': (visitor) => $tom_brain_procedure_prototype_4.SubstrateBridge.defaultRole,
      'defaultBudget': (visitor) => $tom_brain_procedure_prototype_4.SubstrateBridge.defaultBudget,
    },
    constructorSignatures: {
      '': 'SubstrateBridge(TomBrainSubstrateClient client, {BridgeCallRecorder? onCall, SubstrateTokenSink? onToken, BudgetLedger? budget})',
    },
    methodSignatures: {
      'llm': 'Future<Map<String, Object?>> llm(String prompt, {String role = defaultRole, Map<String, Object?>? budget})',
      'embed': 'Future<Map<String, Object?>> embed(String text)',
      'search': 'Future<Map<String, Object?>> search(String query, {String? provider, int k = 10})',
      'fetch': 'Future<Map<String, Object?>> fetch(String url, {int? budgetBytes})',
    },
    getterSignatures: {
      'client': 'TomBrainSubstrateClient get client',
    },
    staticGetterSignatures: {
      'defaultRole': 'String get defaultRole',
      'defaultBudget': 'Budget get defaultBudget',
    },
  );
}

// =============================================================================
// LlmCompletionFailure Bridge
// =============================================================================

BridgedClass _createLlmCompletionFailureBridge() {
  return BridgedClass(
    nativeType: $tom_brain_procedure_prototype_4.LlmCompletionFailure,
    name: 'LlmCompletionFailure',
    isAssignable: (v) => v is $tom_brain_procedure_prototype_4.LlmCompletionFailure,
    hierarchyDepth: 1,
    constructors: {
      '': (visitor, positional, named) {
        final classCode = D4.getRequiredNamedArg<String>(named, 'classCode', 'LlmCompletionFailure');
        final message = D4.getRequiredNamedArg<String>(named, 'message', 'LlmCompletionFailure');
        if (!named.containsKey('report') || named['report'] == null) {
          throw ArgumentError('LlmCompletionFailure: Missing required named argument "report"');
        }
        final report = D4.coerceMap<String, Object?>(named['report'], 'report');
        return $tom_brain_procedure_prototype_4.LlmCompletionFailure(classCode: classCode, message: message, report: report);
      },
    },
    getters: {
      'classCode': (visitor, target) => D4.validateTarget<$tom_brain_procedure_prototype_4.LlmCompletionFailure>(target, 'LlmCompletionFailure').classCode,
      'message': (visitor, target) => D4.validateTarget<$tom_brain_procedure_prototype_4.LlmCompletionFailure>(target, 'LlmCompletionFailure').message,
      'report': (visitor, target) => D4.validateTarget<$tom_brain_procedure_prototype_4.LlmCompletionFailure>(target, 'LlmCompletionFailure').report,
    },
    methods: {
      'toString': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_4.LlmCompletionFailure>(target, 'LlmCompletionFailure');
        return t.toString();
      },
    },
    constructorSignatures: {
      '': 'LlmCompletionFailure({required String classCode, required String message, required Map<String, Object?> report})',
    },
    methodSignatures: {
      'toString': 'String toString()',
    },
    getterSignatures: {
      'classCode': 'String get classCode',
      'message': 'String get message',
      'report': 'Map<String, Object?> get report',
    },
  );
}

// =============================================================================
// ToolBridge Bridge
// =============================================================================

BridgedClass _createToolBridgeBridge() {
  return BridgedClass(
    nativeType: $tom_brain_procedure_prototype_5.ToolBridge,
    name: 'ToolBridge',
    isAssignable: (v) => v is $tom_brain_procedure_prototype_5.ToolBridge,
    constructors: {
      '': (visitor, positional, named) {
        D4.requireMinArgs(positional, 3, 'ToolBridge');
        final registry = D4.getRequiredArg<$tom_brain_procedure_prototype_10.ToolRegistry>(positional, 0, '_registry', 'ToolBridge');
        final policy = D4.getRequiredArg<$tom_brain_procedure_prototype_9.ToolPolicy>(positional, 1, '_policy', 'ToolBridge');
        final context = D4.getRequiredArg<$tom_brain_procedure_prototype_8.ToolContext>(positional, 2, '_context', 'ToolBridge');
        return $tom_brain_procedure_prototype_5.ToolBridge(registry, policy, context);
      },
    },
    methods: {
      'list': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_5.ToolBridge>(target, 'ToolBridge');
        final filter = D4.getOptionalNamedArg<String?>(named, 'filter');
        return t.list(filter: filter);
      },
      'invoke': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_5.ToolBridge>(target, 'ToolBridge');
        D4.requireMinArgs(positional, 2, 'invoke');
        final name = D4.getRequiredArg<String>(positional, 0, 'name', 'invoke');
        if (positional.length <= 1) {
          throw ArgumentError('invoke: Missing required argument "args" at position 1');
        }
        final args = D4.coerceMap<String, Object?>(positional[1], 'args');
        return t.invoke(name, args);
      },
    },
    constructorSignatures: {
      '': 'ToolBridge(ToolRegistry _registry, ToolPolicy _policy, ToolContext _context)',
    },
    methodSignatures: {
      'list': 'Future<List<Map<String, Object?>>> list({String? filter})',
      'invoke': 'Future<Map<String, Object?>> invoke(String name, Map<String, Object?> args)',
    },
  );
}

// =============================================================================
// McpBridge Bridge
// =============================================================================

BridgedClass _createMcpBridgeBridge() {
  return BridgedClass(
    nativeType: $tom_brain_procedure_prototype_2.McpBridge,
    name: 'McpBridge',
    isAssignable: (v) => v is $tom_brain_procedure_prototype_2.McpBridge,
    constructors: {
      '': (visitor, positional, named) {
        D4.requireMinArgs(positional, 2, 'McpBridge');
        final client = D4.getRequiredArg<$tom_brain_procedure_prototype_7.McpClient>(positional, 0, '_client', 'McpBridge');
        final context = D4.getRequiredArg<$tom_brain_procedure_prototype_8.ToolContext>(positional, 1, '_context', 'McpBridge');
        return $tom_brain_procedure_prototype_2.McpBridge(client, context);
      },
    },
    methods: {
      'servers': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_2.McpBridge>(target, 'McpBridge');
        return t.servers();
      },
      'list': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_2.McpBridge>(target, 'McpBridge');
        D4.requireMinArgs(positional, 1, 'list');
        final server = D4.getRequiredArg<String>(positional, 0, 'server', 'list');
        return t.list(server);
      },
      'call': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_2.McpBridge>(target, 'McpBridge');
        D4.requireMinArgs(positional, 3, 'call');
        final server = D4.getRequiredArg<String>(positional, 0, 'server', 'call');
        final tool = D4.getRequiredArg<String>(positional, 1, 'tool', 'call');
        if (positional.length <= 2) {
          throw ArgumentError('call: Missing required argument "args" at position 2');
        }
        final args = D4.coerceMap<String, Object?>(positional[2], 'args');
        return t.call(server, tool, args);
      },
    },
    constructorSignatures: {
      '': 'McpBridge(McpClient _client, ToolContext _context)',
    },
    methodSignatures: {
      'servers': 'Future<List<Map<String, Object?>>> servers()',
      'list': 'Future<List<Map<String, Object?>>> list(String server)',
      'call': 'Future<Map<String, Object?>> call(String server, String tool, Map<String, Object?> args)',
    },
  );
}

