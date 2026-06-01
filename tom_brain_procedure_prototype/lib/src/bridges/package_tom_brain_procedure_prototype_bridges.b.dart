// D4rt Bridge - Generated file, do not edit
// Sources: 2 files
// Generated: 2026-06-01T20:42:26.756160

// ignore_for_file: unused_import, deprecated_member_use, prefer_function_declarations_over_variables, implementation_imports, sort_child_properties_last, non_constant_identifier_names, avoid_function_literals_in_foreach_calls, invalid_use_of_protected_member, unnecessary_non_null_assertion, invalid_use_of_visible_for_testing_member

import 'package:tom_d4rt/d4rt.dart';
import 'package:tom_d4rt/tom_d4rt.dart';
import 'dart:async';

import 'package:tom_brain_memory/src/api/tom_brain_memory_client.dart' as $tom_brain_memory_1;
import 'package:tom_brain_procedure_prototype/src/bridges/memory_bridge.dart' as $tom_brain_procedure_prototype_1;
import 'package:tom_brain_procedure_prototype/src/bridges/substrate_bridge.dart' as $tom_brain_procedure_prototype_2;
import 'package:tom_brain_shared/src/budget/budget.dart' as $tom_brain_shared_1;
import 'package:tom_brain_substrate/src/api/tom_brain_substrate_client.dart' as $tom_brain_substrate_1;

/// Bridge class for package_tom_brain_procedure_prototype module.
class PackageTomBrainProcedurePrototypeBridge {
  /// Returns all bridge class definitions.
  static List<BridgedClass> bridgeClasses() {
    return [
      _createMemoryBridgeBridge(),
      _createSubstrateBridgeBridge(),
      _createLlmCompletionFailureBridge(),
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
      'package:tom_brain_procedure_prototype/src/bridges/memory_bridge.dart',
      'package:tom_brain_procedure_prototype/src/bridges/substrate_bridge.dart',
    ];
  }

}

// =============================================================================
// MemoryBridge Bridge
// =============================================================================

BridgedClass _createMemoryBridgeBridge() {
  return BridgedClass(
    nativeType: $tom_brain_procedure_prototype_1.MemoryBridge,
    name: 'MemoryBridge',
    isAssignable: (v) => v is $tom_brain_procedure_prototype_1.MemoryBridge,
    constructors: {
      '': (visitor, positional, named) {
        D4.requireMinArgs(positional, 1, 'MemoryBridge');
        final client = D4.getRequiredArg<$tom_brain_memory_1.TomBrainMemoryClient>(positional, 0, 'client', 'MemoryBridge');
        return $tom_brain_procedure_prototype_1.MemoryBridge(client);
      },
    },
    getters: {
      'client': (visitor, target) => D4.validateTarget<$tom_brain_procedure_prototype_1.MemoryBridge>(target, 'MemoryBridge').client,
    },
    methods: {
      'recall': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_1.MemoryBridge>(target, 'MemoryBridge');
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
      'persist': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_1.MemoryBridge>(target, 'MemoryBridge');
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
        final t = D4.validateTarget<$tom_brain_procedure_prototype_1.MemoryBridge>(target, 'MemoryBridge');
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
        final t = D4.validateTarget<$tom_brain_procedure_prototype_1.MemoryBridge>(target, 'MemoryBridge');
        D4.requireMinArgs(positional, 1, 'proposeNodeType');
        if (positional.isEmpty) {
          throw ArgumentError('proposeNodeType: Missing required argument "decl" at position 0');
        }
        final decl = D4.coerceMap<String, Object?>(positional[0], 'decl');
        return t.proposeNodeType(decl);
      },
      'stackList': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_1.MemoryBridge>(target, 'MemoryBridge');
        return t.stackList();
      },
      'stackCreate': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_1.MemoryBridge>(target, 'MemoryBridge');
        D4.requireMinArgs(positional, 1, 'stackCreate');
        if (positional.isEmpty) {
          throw ArgumentError('stackCreate: Missing required argument "decl" at position 0');
        }
        final decl = D4.coerceMap<String, Object?>(positional[0], 'decl');
        return t.stackCreate(decl);
      },
      'stackPush': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_1.MemoryBridge>(target, 'MemoryBridge');
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
        final t = D4.validateTarget<$tom_brain_procedure_prototype_1.MemoryBridge>(target, 'MemoryBridge');
        D4.requireMinArgs(positional, 1, 'stackPeek');
        final name = D4.getRequiredArg<String>(positional, 0, 'name', 'stackPeek');
        final k = D4.getNamedArgWithDefault<int>(named, 'k', 16);
        return t.stackPeek(name, k: k);
      },
      'stackPop': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_1.MemoryBridge>(target, 'MemoryBridge');
        D4.requireMinArgs(positional, 1, 'stackPop');
        final name = D4.getRequiredArg<String>(positional, 0, 'name', 'stackPop');
        return t.stackPop(name);
      },
      'stackUpdate': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_1.MemoryBridge>(target, 'MemoryBridge');
        D4.requireMinArgs(positional, 2, 'stackUpdate');
        final name = D4.getRequiredArg<String>(positional, 0, 'name', 'stackUpdate');
        final nodeId = D4.getRequiredArg<String>(positional, 1, 'nodeId', 'stackUpdate');
        final priority = D4.getOptionalNamedArg<double?>(named, 'priority');
        final status = D4.getOptionalNamedArg<String?>(named, 'status');
        final attrs = D4.coerceMapOrNull<String, Object?>(named['attrs'], 'attrs');
        return t.stackUpdate(name, nodeId, priority: priority, status: status, attrs: attrs);
      },
      'stackRemove': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_1.MemoryBridge>(target, 'MemoryBridge');
        D4.requireMinArgs(positional, 2, 'stackRemove');
        final name = D4.getRequiredArg<String>(positional, 0, 'name', 'stackRemove');
        final nodeId = D4.getRequiredArg<String>(positional, 1, 'nodeId', 'stackRemove');
        return t.stackRemove(name, nodeId);
      },
    },
    constructorSignatures: {
      '': 'MemoryBridge(TomBrainMemoryClient client)',
    },
    methodSignatures: {
      'recall': 'Future<Map<String, Object?>> recall(String text, {List<String> modes = const <String>[\'bm25\', \'vector\'], int k = 8})',
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
    },
    getterSignatures: {
      'client': 'TomBrainMemoryClient get client',
    },
  );
}

// =============================================================================
// SubstrateBridge Bridge
// =============================================================================

BridgedClass _createSubstrateBridgeBridge() {
  return BridgedClass(
    nativeType: $tom_brain_procedure_prototype_2.SubstrateBridge,
    name: 'SubstrateBridge',
    isAssignable: (v) => v is $tom_brain_procedure_prototype_2.SubstrateBridge,
    constructors: {
      '': (visitor, positional, named) {
        D4.requireMinArgs(positional, 1, 'SubstrateBridge');
        final client = D4.getRequiredArg<$tom_brain_substrate_1.TomBrainSubstrateClient>(positional, 0, 'client', 'SubstrateBridge');
        return $tom_brain_procedure_prototype_2.SubstrateBridge(client);
      },
    },
    getters: {
      'client': (visitor, target) => D4.validateTarget<$tom_brain_procedure_prototype_2.SubstrateBridge>(target, 'SubstrateBridge').client,
    },
    methods: {
      'llm': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_2.SubstrateBridge>(target, 'SubstrateBridge');
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
        final t = D4.validateTarget<$tom_brain_procedure_prototype_2.SubstrateBridge>(target, 'SubstrateBridge');
        D4.requireMinArgs(positional, 1, 'embed');
        final text = D4.getRequiredArg<String>(positional, 0, 'text', 'embed');
        return t.embed(text);
      },
      'search': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_2.SubstrateBridge>(target, 'SubstrateBridge');
        D4.requireMinArgs(positional, 1, 'search');
        final query = D4.getRequiredArg<String>(positional, 0, 'query', 'search');
        final provider = D4.getOptionalNamedArg<String?>(named, 'provider');
        final k = D4.getNamedArgWithDefault<int>(named, 'k', 10);
        return t.search(query, provider: provider, k: k);
      },
      'fetch': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_2.SubstrateBridge>(target, 'SubstrateBridge');
        D4.requireMinArgs(positional, 1, 'fetch');
        final url = D4.getRequiredArg<String>(positional, 0, 'url', 'fetch');
        final budgetBytes = D4.getOptionalNamedArg<int?>(named, 'budgetBytes');
        return t.fetch(url, budgetBytes: budgetBytes);
      },
    },
    staticGetters: {
      'defaultRole': (visitor) => $tom_brain_procedure_prototype_2.SubstrateBridge.defaultRole,
      'defaultBudget': (visitor) => $tom_brain_procedure_prototype_2.SubstrateBridge.defaultBudget,
    },
    constructorSignatures: {
      '': 'SubstrateBridge(TomBrainSubstrateClient client)',
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
    nativeType: $tom_brain_procedure_prototype_2.LlmCompletionFailure,
    name: 'LlmCompletionFailure',
    isAssignable: (v) => v is $tom_brain_procedure_prototype_2.LlmCompletionFailure,
    constructors: {
      '': (visitor, positional, named) {
        final classCode = D4.getRequiredNamedArg<String>(named, 'classCode', 'LlmCompletionFailure');
        final message = D4.getRequiredNamedArg<String>(named, 'message', 'LlmCompletionFailure');
        if (!named.containsKey('report') || named['report'] == null) {
          throw ArgumentError('LlmCompletionFailure: Missing required named argument "report"');
        }
        final report = D4.coerceMap<String, Object?>(named['report'], 'report');
        return $tom_brain_procedure_prototype_2.LlmCompletionFailure(classCode: classCode, message: message, report: report);
      },
    },
    getters: {
      'classCode': (visitor, target) => D4.validateTarget<$tom_brain_procedure_prototype_2.LlmCompletionFailure>(target, 'LlmCompletionFailure').classCode,
      'message': (visitor, target) => D4.validateTarget<$tom_brain_procedure_prototype_2.LlmCompletionFailure>(target, 'LlmCompletionFailure').message,
      'report': (visitor, target) => D4.validateTarget<$tom_brain_procedure_prototype_2.LlmCompletionFailure>(target, 'LlmCompletionFailure').report,
    },
    methods: {
      'toString': (visitor, target, positional, named, typeArgs) {
        final t = D4.validateTarget<$tom_brain_procedure_prototype_2.LlmCompletionFailure>(target, 'LlmCompletionFailure');
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

