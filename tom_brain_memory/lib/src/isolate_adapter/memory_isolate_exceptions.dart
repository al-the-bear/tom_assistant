// MemoryIsolateExceptions — the closed-taxonomy codec that lets the
// memory layer's typed exceptions survive an isolate-boundary round trip
// (completion-plan item 11 / CS-003 E).
//
// The in-isolate executor catches an exception, flattens it to the
// sendable wire form (`IsolateErrorResponse` / `StreamErrorEnvelope`:
// a type tag + message + a sendable `details` map) and sends it to the
// host. The host rebuilds the *same* typed instance via the generic
// `IsolateExceptionRegistry`, so a procedure or dreaming agent that ran
// behind the isolate boundary catches `EdgeNotPermitted` / `StackNotFound`
// / `WriteBudgetExceeded` exactly as it would in-process — no prose
// parsing, no untyped `IsolateBoundaryException` wrapper.
//
// Why a codec table (pack + reconstruct in one place) rather than sending
// the live exception object: Dart's `SendPort` cannot carry an arbitrary
// object (it may capture non-sendable state — closures, open resources,
// a `StackTrace`). The boundary's contract is to ship only sendable
// primitives. Co-locating pack and the reconstruction factory per type
// keeps the round trip obvious and makes the per-class round-trip test
// the single source of truth that the two halves agree.
//
// The taxonomy is *closed*: it is exactly the typed exception families
// the memory API declares (`memory_specification.md` §§ 4–10). Adding a
// new leaf to one of these sealed families is a deliberate breaking
// change in its own layer; the matching codec entry + round-trip test
// land in the same change. Anything outside the taxonomy (e.g. a core
// `StateError` from `_requireOpenMemory`) is not packed — `pack` returns
// `null` and the host falls back to `IsolateBoundaryException`.

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeType, NodeId, WriteBudget;
import 'package:tom_core_agentic/tom_core_agentic.dart'
    show IsolateExceptionRegistry;

import '../budget/write_budget_exceeded.dart';
import '../edges/edge_write_exception.dart';
import '../nodes/node_persist_exception.dart';
import '../nodes/node_type_registration.dart';
import '../stacks/stack_exception.dart';
import '../store/vector_table_exception.dart';

/// The flat wire form of a packed taxonomy exception: its runtime type
/// tag, its own `message`, and a sendable map of its structured fields.
typedef PackedMemoryException = ({
  String type,
  String message,
  Map<String, Object?> details,
});

/// Codec for the closed memory exception taxonomy across the isolate
/// boundary. Pure static surface — no instance state.
abstract final class MemoryIsolateExceptions {
  /// Flattens [error] into its wire form when it belongs to the closed
  /// taxonomy, or returns `null` when it does not (the boundary then
  /// falls back to the generic `IsolateBoundaryException`).
  ///
  /// The returned `message` is the exception's own `message` field — not
  /// its `toString()` — so the host's factory rebuilds the instance with
  /// the original message and regenerates `toString()` itself.
  static PackedMemoryException? pack(Object error) {
    switch (error) {
      // ─── StackException family ──────────────────────────────────
      case StackNotFound():
        return (
          type: 'StackNotFound',
          message: error.message,
          details: <String, Object?>{'stackName': error.stackName},
        );
      case StackAlreadyExists():
        return (
          type: 'StackAlreadyExists',
          message: error.message,
          details: <String, Object?>{'stackName': error.stackName},
        );
      case BootstrapStackImmutable():
        return (
          type: 'BootstrapStackImmutable',
          message: error.message,
          details: <String, Object?>{'stackName': error.stackName},
        );
      case StackEntryNotFound():
        return (
          type: 'StackEntryNotFound',
          message: error.message,
          details: <String, Object?>{
            'stackName': error.stackName,
            'nodeIdString': error.nodeIdString,
          },
        );
      case StackPolicyConfigInvalid():
        return (
          type: 'StackPolicyConfigInvalid',
          message: error.message,
          details: <String, Object?>{
            'stackName': error.stackName,
            'reason': error.reason.name,
          },
        );

      // ─── EdgeWriteException family ──────────────────────────────
      case EdgeEndpointMissing():
        return (
          type: 'EdgeEndpointMissing',
          message: error.message,
          details: <String, Object?>{
            ..._packEdge(error),
            'side': error.side.name,
          },
        );
      case EdgeNotPermitted():
        return (
          type: 'EdgeNotPermitted',
          message: error.message,
          details: <String, Object?>{
            ..._packEdge(error),
            'side': error.side.name,
            'rejectingTypeName': error.rejectingTypeName,
          },
        );
      case UnknownNodeTypeForEdge():
        return (
          type: 'UnknownNodeTypeForEdge',
          message: error.message,
          details: <String, Object?>{
            ..._packEdge(error),
            'side': error.side.name,
            'unknownTypeName': error.unknownTypeName,
          },
        );

      // ─── WriteBudgetExceeded ────────────────────────────────────
      case WriteBudgetExceeded():
        return (
          type: 'WriteBudgetExceeded',
          message: error.message,
          details: <String, Object?>{
            'dimension': error.dimension.name,
            'runId': error.runId,
            'producer': error.producer,
            'maxNodes': error.budget.maxNodes,
            'maxEdges': error.budget.maxEdges,
            'maxStackEntries': error.budget.maxStackEntries,
          },
        );

      // ─── NodePersistException family ────────────────────────────
      case UnknownNodeType():
        return (
          type: 'UnknownNodeType',
          message: error.message,
          details: <String, Object?>{'typeName': error.typeName},
        );
      case InvalidNodeDraft():
        return (
          type: 'InvalidNodeDraft',
          message: error.message,
          details: <String, Object?>{
            'typeName': error.typeName,
            'reason': error.reason.name,
            'fieldName': error.fieldName,
          },
        );
      case EmbeddingPolicyViolation():
        return (
          type: 'EmbeddingPolicyViolation',
          message: error.message,
          details: <String, Object?>{
            'typeName': error.typeName,
            'reason': error.reason.name,
            'expectedDimensions': error.expectedDimensions,
            'actualDimensions': error.actualDimensions,
          },
        );

      // ─── NodeTypeRegistrationException family ───────────────────
      case InvalidNodeTypeDecl():
        return (
          type: 'InvalidNodeTypeDecl',
          message: error.message,
          details: <String, Object?>{
            'typeName': error.typeName,
            'fieldPath': error.fieldPath,
          },
        );
      case NodeTypeAlreadyExists():
        return (
          type: 'NodeTypeAlreadyExists',
          message: error.message,
          details: <String, Object?>{'typeName': error.typeName},
        );
      case NodeTypeNotFound():
        return (
          type: 'NodeTypeNotFound',
          message: error.message,
          details: <String, Object?>{
            'typeName': error.typeName,
            'supersedesDeclNodeId': error.supersedesDeclNodeId,
            'registeredDeclNodeId': error.registeredDeclNodeId,
          },
        );
      case NodeTypeVersionNotMonotonic():
        return (
          type: 'NodeTypeVersionNotMonotonic',
          message: error.message,
          details: <String, Object?>{
            'typeName': error.typeName,
            'existingVersion': error.existingVersion,
            'proposedVersion': error.proposedVersion,
          },
        );
      case NodeTypeRejected():
        return (
          type: 'NodeTypeRejected',
          message: error.message,
          details: <String, Object?>{
            'typeName': error.typeName,
            'reason': error.reason,
            'conflictingTypeNames': error.conflictingTypeNames,
          },
        );

      // ─── VectorTableException family ────────────────────────────
      case EmbeddingModelMismatch():
        return (
          type: 'EmbeddingModelMismatch',
          message: error.message,
          details: <String, Object?>{'modelId': error.modelId},
        );
      case EmbeddingDimsMismatch():
        return (
          type: 'EmbeddingDimsMismatch',
          message: error.message,
          details: <String, Object?>{
            'modelId': error.modelId,
            'expectedDims': error.expectedDims,
            'actualDims': error.actualDims,
          },
        );
      case IndexInstallationConflict():
        return (
          type: 'IndexInstallationConflict',
          message: error.message,
          details: <String, Object?>{
            'modelId': error.modelId,
            'existingDims': error.existingDims,
            'proposedDims': error.proposedDims,
          },
        );

      default:
        return null;
    }
  }

  /// Registers a reconstruction factory for every taxonomy type into
  /// [registry]. The host calls this once at construction; the factory
  /// keys mirror the [pack] type tags exactly.
  static void registerInto(IsolateExceptionRegistry registry) {
    // ─── StackException family ──────────────────────────────────────
    registry.register(
      'StackNotFound',
      (m, d) => StackNotFound(stackName: d['stackName']! as String, message: m),
    );
    registry.register(
      'StackAlreadyExists',
      (m, d) =>
          StackAlreadyExists(stackName: d['stackName']! as String, message: m),
    );
    registry.register(
      'BootstrapStackImmutable',
      (m, d) => BootstrapStackImmutable(
        stackName: d['stackName']! as String,
        message: m,
      ),
    );
    registry.register(
      'StackEntryNotFound',
      (m, d) => StackEntryNotFound(
        stackName: d['stackName']! as String,
        nodeIdString: d['nodeIdString']! as String,
        message: m,
      ),
    );
    registry.register(
      'StackPolicyConfigInvalid',
      (m, d) => StackPolicyConfigInvalid(
        stackName: d['stackName']! as String,
        reason: StackPolicyConfigInvalidReason.values
            .byName(d['reason']! as String),
        message: m,
      ),
    );

    // ─── EdgeWriteException family ──────────────────────────────────
    registry.register(
      'EdgeEndpointMissing',
      (m, d) => EdgeEndpointMissing(
        from: _unpackNodeId(d, 'from'),
        type: _unpackEdgeType(d),
        to: _unpackNodeId(d, 'to'),
        message: m,
        side: EdgeEndpointSide.values.byName(d['side']! as String),
      ),
    );
    registry.register(
      'EdgeNotPermitted',
      (m, d) => EdgeNotPermitted(
        from: _unpackNodeId(d, 'from'),
        type: _unpackEdgeType(d),
        to: _unpackNodeId(d, 'to'),
        message: m,
        side: EdgeEndpointSide.values.byName(d['side']! as String),
        rejectingTypeName: d['rejectingTypeName']! as String,
      ),
    );
    registry.register(
      'UnknownNodeTypeForEdge',
      (m, d) => UnknownNodeTypeForEdge(
        from: _unpackNodeId(d, 'from'),
        type: _unpackEdgeType(d),
        to: _unpackNodeId(d, 'to'),
        message: m,
        side: EdgeEndpointSide.values.byName(d['side']! as String),
        unknownTypeName: d['unknownTypeName']! as String,
      ),
    );

    // ─── WriteBudgetExceeded ────────────────────────────────────────
    registry.register(
      'WriteBudgetExceeded',
      (m, d) => WriteBudgetExceeded(
        dimension:
            WriteBudgetDimension.values.byName(d['dimension']! as String),
        runId: d['runId']! as String,
        producer: d['producer']! as String,
        budget: WriteBudget(
          maxNodes: d['maxNodes']! as int,
          maxEdges: d['maxEdges']! as int,
          maxStackEntries: d['maxStackEntries']! as int,
        ),
        message: m,
      ),
    );

    // ─── NodePersistException family ────────────────────────────────
    registry.register(
      'UnknownNodeType',
      (m, d) => UnknownNodeType(typeName: d['typeName']! as String, message: m),
    );
    registry.register(
      'InvalidNodeDraft',
      (m, d) => InvalidNodeDraft(
        typeName: d['typeName']! as String,
        reason: InvalidNodeDraftReason.values.byName(d['reason']! as String),
        fieldName: d['fieldName'] as String?,
        message: m,
      ),
    );
    registry.register(
      'EmbeddingPolicyViolation',
      (m, d) => EmbeddingPolicyViolation(
        typeName: d['typeName']! as String,
        reason: EmbeddingPolicyViolationReason.values
            .byName(d['reason']! as String),
        expectedDimensions: d['expectedDimensions'] as int?,
        actualDimensions: d['actualDimensions'] as int?,
        message: m,
      ),
    );

    // ─── NodeTypeRegistrationException family ───────────────────────
    registry.register(
      'InvalidNodeTypeDecl',
      (m, d) => InvalidNodeTypeDecl(
        typeName: d['typeName']! as String,
        fieldPath: d['fieldPath'] as String?,
        message: m,
      ),
    );
    registry.register(
      'NodeTypeAlreadyExists',
      (m, d) =>
          NodeTypeAlreadyExists(typeName: d['typeName']! as String, message: m),
    );
    registry.register(
      'NodeTypeNotFound',
      (m, d) => NodeTypeNotFound(
        typeName: d['typeName']! as String,
        supersedesDeclNodeId: d['supersedesDeclNodeId']! as String,
        registeredDeclNodeId: d['registeredDeclNodeId'] as String?,
        message: m,
      ),
    );
    registry.register(
      'NodeTypeVersionNotMonotonic',
      (m, d) => NodeTypeVersionNotMonotonic(
        typeName: d['typeName']! as String,
        existingVersion: d['existingVersion']! as int,
        proposedVersion: d['proposedVersion']! as int,
        message: m,
      ),
    );
    registry.register(
      'NodeTypeRejected',
      (m, d) => NodeTypeRejected(
        typeName: d['typeName']! as String,
        reason: d['reason']! as String,
        conflictingTypeNames:
            (d['conflictingTypeNames']! as List).cast<String>(),
        message: m,
      ),
    );

    // ─── VectorTableException family ────────────────────────────────
    registry.register(
      'EmbeddingModelMismatch',
      (m, d) =>
          EmbeddingModelMismatch(modelId: d['modelId']! as String, message: m),
    );
    registry.register(
      'EmbeddingDimsMismatch',
      (m, d) => EmbeddingDimsMismatch(
        modelId: d['modelId']! as String,
        expectedDims: d['expectedDims']! as int,
        actualDims: d['actualDims']! as int,
        message: m,
      ),
    );
    registry.register(
      'IndexInstallationConflict',
      (m, d) => IndexInstallationConflict(
        modelId: d['modelId']! as String,
        existingDims: d['existingDims']! as int,
        proposedDims: d['proposedDims']! as int,
        message: m,
      ),
    );
  }

  // ─── Value-object (de)serialization helpers ───────────────────────

  /// Packs the three shared `EdgeWriteException` fields (`from` / `type`
  /// / `to`) to their wire forms.
  static Map<String, Object?> _packEdge(EdgeWriteException e) =>
      <String, Object?>{
        'from': e.from.value,
        'type': e.type.wireName,
        'to': e.to.value,
      };

  static NodeId _unpackNodeId(Map<String, Object?> d, String key) =>
      NodeId.fromString(d[key]! as String);

  static EdgeType _unpackEdgeType(Map<String, Object?> d) =>
      EdgeType.fromWireName(d['type']! as String);
}
