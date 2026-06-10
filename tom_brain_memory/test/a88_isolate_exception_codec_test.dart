// Round-trip tests for the closed memory exception taxonomy across the
// isolate boundary (completion-plan item 11).
//
// The contract: every leaf exception the memory API declares survives a
// `pack → IsolateErrorResponse (wire form) → registry.reconstruct` round
// trip as the *same* type, with its structured fields intact. Anything
// outside the taxonomy is not packed (`pack` returns `null`) so the host
// falls back to `IsolateBoundaryException`.
//
// One test per leaf type asserts both the rebuilt runtime type and the
// fields the codec carries. The two-stage `_roundTrip` helper threads the
// exception through the exact same `IsolateErrorResponse` wire shape the
// executor builds and the host consumes, so the test is the single source
// of truth that `pack` and `registerInto` agree.

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeType, NodeId, WriteBudget;
import 'package:tom_core_agentic/tom_core_agentic.dart'
    show IsolateExceptionRegistry;
import 'package:test/test.dart';

/// Threads [error] through the full wire round trip and returns the
/// reconstructed instance, or `null` when the error is outside the closed
/// taxonomy (`pack` declined it).
Object? _roundTrip(IsolateExceptionRegistry registry, Object error) {
  final packed = MemoryIsolateExceptions.pack(error);
  if (packed == null) return null;
  // Mirror the executor's catch: flatten to the sendable wire form.
  final wire = IsolateErrorResponse(
    exceptionType: packed.type,
    message: packed.message,
    details: packed.details,
  );
  // Mirror the host's reconstruct on receipt.
  return registry.reconstruct(wire.exceptionType, wire.message, wire.details);
}

void main() {
  late IsolateExceptionRegistry registry;

  setUp(() {
    registry = IsolateExceptionRegistry();
    MemoryIsolateExceptions.registerInto(registry);
  });

  group('MemoryIsolateExceptions — StackException family', () {
    test('StackNotFound round-trips type + stackName', () {
      final rebuilt = _roundTrip(
        registry,
        const StackNotFound(stackName: 'questions_open', message: 'gone'),
      );
      expect(rebuilt, isA<StackNotFound>());
      final typed = rebuilt! as StackNotFound;
      expect(typed.stackName, equals('questions_open'));
      expect(typed.message, equals('gone'));
    });

    test('StackAlreadyExists round-trips type + stackName', () {
      final rebuilt = _roundTrip(
        registry,
        const StackAlreadyExists(stackName: 'interests', message: 'dup'),
      ) as StackAlreadyExists;
      expect(rebuilt.stackName, equals('interests'));
      expect(rebuilt.message, equals('dup'));
    });

    test('BootstrapStackImmutable round-trips type + stackName', () {
      final rebuilt = _roundTrip(
        registry,
        const BootstrapStackImmutable(stackName: 'inflight', message: 'no'),
      ) as BootstrapStackImmutable;
      expect(rebuilt.stackName, equals('inflight'));
      expect(rebuilt.message, equals('no'));
    });

    test('StackEntryNotFound round-trips type + stackName + nodeIdString', () {
      final rebuilt = _roundTrip(
        registry,
        const StackEntryNotFound(
          stackName: 'recent_runs',
          nodeIdString: 'node-abc',
          message: 'missing entry',
        ),
      ) as StackEntryNotFound;
      expect(rebuilt.stackName, equals('recent_runs'));
      expect(rebuilt.nodeIdString, equals('node-abc'));
      expect(rebuilt.message, equals('missing entry'));
    });

    test('StackPolicyConfigInvalid round-trips type + stackName + reason', () {
      final rebuilt = _roundTrip(
        registry,
        const StackPolicyConfigInvalid(
          stackName: 'automation_ideas',
          reason: StackPolicyConfigInvalidReason.boundedNWithoutMaxCount,
          message: 'bad policy',
        ),
      ) as StackPolicyConfigInvalid;
      expect(rebuilt.stackName, equals('automation_ideas'));
      expect(
        rebuilt.reason,
        equals(StackPolicyConfigInvalidReason.boundedNWithoutMaxCount),
      );
      expect(rebuilt.message, equals('bad policy'));
    });
  });

  group('MemoryIsolateExceptions — EdgeWriteException family', () {
    final from = NodeId.generate();
    final to = NodeId.generate();

    test('EdgeEndpointMissing round-trips endpoints + side', () {
      final rebuilt = _roundTrip(
        registry,
        EdgeEndpointMissing(
          from: from,
          type: EdgeType.derivedFrom,
          to: to,
          message: 'no such from',
          side: EdgeEndpointSide.from,
        ),
      ) as EdgeEndpointMissing;
      expect(rebuilt.from.value, equals(from.value));
      expect(rebuilt.type, equals(EdgeType.derivedFrom));
      expect(rebuilt.to.value, equals(to.value));
      expect(rebuilt.side, equals(EdgeEndpointSide.from));
      expect(rebuilt.message, equals('no such from'));
    });

    test('EdgeNotPermitted round-trips endpoints + side + rejectingTypeName',
        () {
      final rebuilt = _roundTrip(
        registry,
        EdgeNotPermitted(
          from: from,
          type: EdgeType.contradicts,
          to: to,
          message: 'forbidden',
          side: EdgeEndpointSide.to,
          rejectingTypeName: 'Conclusion',
        ),
      ) as EdgeNotPermitted;
      expect(rebuilt.from.value, equals(from.value));
      expect(rebuilt.type, equals(EdgeType.contradicts));
      expect(rebuilt.to.value, equals(to.value));
      expect(rebuilt.side, equals(EdgeEndpointSide.to));
      expect(rebuilt.rejectingTypeName, equals('Conclusion'));
      expect(rebuilt.message, equals('forbidden'));
    });

    test('UnknownNodeTypeForEdge round-trips endpoints + side + unknownTypeName',
        () {
      final rebuilt = _roundTrip(
        registry,
        UnknownNodeTypeForEdge(
          from: from,
          type: EdgeType.mentions,
          to: to,
          message: 'integrity tripwire',
          side: EdgeEndpointSide.from,
          unknownTypeName: 'GhostType',
        ),
      ) as UnknownNodeTypeForEdge;
      expect(rebuilt.type, equals(EdgeType.mentions));
      expect(rebuilt.side, equals(EdgeEndpointSide.from));
      expect(rebuilt.unknownTypeName, equals('GhostType'));
      expect(rebuilt.message, equals('integrity tripwire'));
    });
  });

  group('MemoryIsolateExceptions — WriteBudgetExceeded', () {
    test('round-trips dimension + runId + producer + budget', () {
      final rebuilt = _roundTrip(
        registry,
        WriteBudgetExceeded(
          dimension: WriteBudgetDimension.maxEdges,
          runId: 'run-42',
          producer: 'dream:consolidator',
          budget: WriteBudget(
            maxNodes: 5,
            maxEdges: 3,
            maxStackEntries: 7,
          ),
          message: 'over budget',
        ),
      ) as WriteBudgetExceeded;
      expect(rebuilt.dimension, equals(WriteBudgetDimension.maxEdges));
      expect(rebuilt.runId, equals('run-42'));
      expect(rebuilt.producer, equals('dream:consolidator'));
      expect(rebuilt.budget.maxNodes, equals(5));
      expect(rebuilt.budget.maxEdges, equals(3));
      expect(rebuilt.budget.maxStackEntries, equals(7));
      expect(rebuilt.message, equals('over budget'));
    });
  });

  group('MemoryIsolateExceptions — NodePersistException family', () {
    test('UnknownNodeType round-trips type + typeName', () {
      final rebuilt = _roundTrip(
        registry,
        const UnknownNodeType(typeName: 'Widget', message: 'unregistered'),
      ) as UnknownNodeType;
      expect(rebuilt.typeName, equals('Widget'));
      expect(rebuilt.message, equals('unregistered'));
    });

    test('InvalidNodeDraft round-trips typeName + reason + fieldName', () {
      final rebuilt = _roundTrip(
        registry,
        const InvalidNodeDraft(
          typeName: 'Claim',
          reason: InvalidNodeDraftReason.missingRequiredField,
          fieldName: 'subject',
          message: 'missing subject',
        ),
      ) as InvalidNodeDraft;
      expect(rebuilt.typeName, equals('Claim'));
      expect(rebuilt.reason,
          equals(InvalidNodeDraftReason.missingRequiredField));
      expect(rebuilt.fieldName, equals('subject'));
      expect(rebuilt.message, equals('missing subject'));
    });

    test('InvalidNodeDraft round-trips null fieldName', () {
      final rebuilt = _roundTrip(
        registry,
        const InvalidNodeDraft(
          typeName: 'Claim',
          reason: InvalidNodeDraftReason.unknownField,
          message: 'whole-draft failure',
        ),
      ) as InvalidNodeDraft;
      expect(rebuilt.fieldName, isNull);
      expect(rebuilt.reason, equals(InvalidNodeDraftReason.unknownField));
    });

    test('EmbeddingPolicyViolation round-trips reason + dimensions', () {
      final rebuilt = _roundTrip(
        registry,
        const EmbeddingPolicyViolation(
          typeName: 'Concept',
          reason: EmbeddingPolicyViolationReason.dimensionMismatch,
          expectedDimensions: 768,
          actualDimensions: 1024,
          message: 'dim mismatch',
        ),
      ) as EmbeddingPolicyViolation;
      expect(rebuilt.typeName, equals('Concept'));
      expect(rebuilt.reason,
          equals(EmbeddingPolicyViolationReason.dimensionMismatch));
      expect(rebuilt.expectedDimensions, equals(768));
      expect(rebuilt.actualDimensions, equals(1024));
    });

    test('EmbeddingPolicyViolation round-trips null dimensions', () {
      final rebuilt = _roundTrip(
        registry,
        const EmbeddingPolicyViolation(
          typeName: 'Concept',
          reason: EmbeddingPolicyViolationReason.missingEmbedding,
          message: 'no embedding',
        ),
      ) as EmbeddingPolicyViolation;
      expect(rebuilt.expectedDimensions, isNull);
      expect(rebuilt.actualDimensions, isNull);
    });
  });

  group('MemoryIsolateExceptions — NodeTypeRegistrationException family', () {
    test('InvalidNodeTypeDecl round-trips typeName + fieldPath', () {
      final rebuilt = _roundTrip(
        registry,
        const InvalidNodeTypeDecl(
          typeName: 'BadType',
          fieldPath: 'schema.fields[0]',
          message: 'bad decl',
        ),
      ) as InvalidNodeTypeDecl;
      expect(rebuilt.typeName, equals('BadType'));
      expect(rebuilt.fieldPath, equals('schema.fields[0]'));
      expect(rebuilt.message, equals('bad decl'));
    });

    test('InvalidNodeTypeDecl round-trips null fieldPath', () {
      final rebuilt = _roundTrip(
        registry,
        const InvalidNodeTypeDecl(typeName: 'BadType', message: 'bad name'),
      ) as InvalidNodeTypeDecl;
      expect(rebuilt.fieldPath, isNull);
    });

    test('NodeTypeAlreadyExists round-trips typeName', () {
      final rebuilt = _roundTrip(
        registry,
        const NodeTypeAlreadyExists(typeName: 'Concept', message: 'dup'),
      ) as NodeTypeAlreadyExists;
      expect(rebuilt.typeName, equals('Concept'));
    });

    test('NodeTypeNotFound round-trips supersedes + registered decl ids', () {
      final rebuilt = _roundTrip(
        registry,
        const NodeTypeNotFound(
          typeName: 'Concept',
          supersedesDeclNodeId: 'decl-old',
          registeredDeclNodeId: 'decl-actual',
          message: 'stale supersedes',
        ),
      ) as NodeTypeNotFound;
      expect(rebuilt.typeName, equals('Concept'));
      expect(rebuilt.supersedesDeclNodeId, equals('decl-old'));
      expect(rebuilt.registeredDeclNodeId, equals('decl-actual'));
    });

    test('NodeTypeNotFound round-trips null registeredDeclNodeId', () {
      final rebuilt = _roundTrip(
        registry,
        const NodeTypeNotFound(
          typeName: 'Concept',
          supersedesDeclNodeId: 'decl-old',
          message: 'no row at all',
        ),
      ) as NodeTypeNotFound;
      expect(rebuilt.registeredDeclNodeId, isNull);
    });

    test('NodeTypeVersionNotMonotonic round-trips versions', () {
      final rebuilt = _roundTrip(
        registry,
        const NodeTypeVersionNotMonotonic(
          typeName: 'Concept',
          existingVersion: 4,
          proposedVersion: 2,
          message: 'not monotonic',
        ),
      ) as NodeTypeVersionNotMonotonic;
      expect(rebuilt.existingVersion, equals(4));
      expect(rebuilt.proposedVersion, equals(2));
    });

    test('NodeTypeRejected round-trips reason + conflictingTypeNames', () {
      final rebuilt = _roundTrip(
        registry,
        const NodeTypeRejected(
          typeName: 'Concept',
          reason: 'overlaps existing types',
          conflictingTypeNames: <String>['Claim', 'Pattern'],
          message: 'rejected by critique',
        ),
      ) as NodeTypeRejected;
      expect(rebuilt.reason, equals('overlaps existing types'));
      expect(rebuilt.conflictingTypeNames, equals(<String>['Claim', 'Pattern']));
    });

    test('NodeTypeRejected round-trips empty conflictingTypeNames', () {
      final rebuilt = _roundTrip(
        registry,
        const NodeTypeRejected(
          typeName: 'Concept',
          reason: 'not about overlap',
          message: 'rejected',
        ),
      ) as NodeTypeRejected;
      expect(rebuilt.conflictingTypeNames, isEmpty);
    });
  });

  group('MemoryIsolateExceptions — VectorTableException family', () {
    test('EmbeddingModelMismatch round-trips modelId', () {
      final rebuilt = _roundTrip(
        registry,
        const EmbeddingModelMismatch(
          modelId: 'nomic-embed-text',
          message: 'no index',
        ),
      ) as EmbeddingModelMismatch;
      expect(rebuilt.modelId, equals('nomic-embed-text'));
      expect(rebuilt.message, equals('no index'));
    });

    test('EmbeddingDimsMismatch round-trips dims', () {
      final rebuilt = _roundTrip(
        registry,
        const EmbeddingDimsMismatch(
          modelId: 'nomic-embed-text',
          expectedDims: 768,
          actualDims: 1024,
          message: 'dim mismatch',
        ),
      ) as EmbeddingDimsMismatch;
      expect(rebuilt.modelId, equals('nomic-embed-text'));
      expect(rebuilt.expectedDims, equals(768));
      expect(rebuilt.actualDims, equals(1024));
    });

    test('IndexInstallationConflict round-trips dims', () {
      final rebuilt = _roundTrip(
        registry,
        const IndexInstallationConflict(
          modelId: 'nomic-embed-text',
          existingDims: 768,
          proposedDims: 1024,
          message: 'install conflict',
        ),
      ) as IndexInstallationConflict;
      expect(rebuilt.existingDims, equals(768));
      expect(rebuilt.proposedDims, equals(1024));
    });
  });

  group('MemoryIsolateExceptions — fallback', () {
    test('pack declines an exception outside the taxonomy', () {
      expect(MemoryIsolateExceptions.pack(StateError('boom')), isNull);
      expect(MemoryIsolateExceptions.pack(ArgumentError('bad')), isNull);
    });

    test('registry reconstruct declines an unregistered type tag', () {
      expect(registry.reconstruct('StateError', 'boom'), isNull);
    });
  });
}
