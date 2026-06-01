// MemoryProcedureStore — the memory backend of the procedure store
// (Plan step C.23; `tom_brain_procedure_prototype_specification.md`
// § 9; `procedure_specification.md` § 7.1).
//
// Serves brain-authored procedures, which live as `Procedure` nodes in
// the property-graph memory. The node carries the verbatim d4rt source
// in its `source` field (`procedure_specification.md` § 7.1). The
// backend enumerates those nodes through the memory client's `stream`
// (a type-filtered scan) and reads one back through `get` — both at the
// `TomBrainMemoryClient` interface boundary (PE-10), never a concrete
// memory class.
//
// Like the disk backend, this is pure I/O: it returns the raw `source`
// string verbatim. Parsing the header (C.24) and resolving versions
// (C.25) sit on top. The `Procedure` node already has its own
// `revision` field, but reading it is the loader's job, not the store's.

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show NodeId;

import 'procedure_ref.dart';
import 'procedure_source.dart';
import 'procedure_store_base.dart';

/// Memory-backed [ProcedureStore] over the brain's `Procedure` nodes.
///
/// `list` streams every node of [procedureTypeName] from the memory
/// client and returns one [ProcedureRef] per node (the node id as the
/// locator). `read` fetches the node and extracts [sourceField]. A node
/// that has been removed, is of the wrong type, or carries no string
/// source field reads back as `null`.
final class MemoryProcedureStore implements ProcedureStore {
  /// The interface-boundary memory client (PE-10). Injected by the host.
  final TomBrainMemoryClient client;

  /// The node-type name brain-authored procedures are stored under.
  /// Defaults to `Procedure` (`procedure_specification.md` § 7.1).
  final String procedureTypeName;

  /// The node field that holds the verbatim d4rt source. Defaults to
  /// `source` (`procedure_specification.md` § 7.1).
  final String sourceField;

  MemoryProcedureStore(
    this.client, {
    this.procedureTypeName = 'Procedure',
    this.sourceField = 'source',
  });

  @override
  bool handles(ProcedureRef ref) => ref.origin.isMemory;

  @override
  Future<List<ProcedureRef>> list() async {
    final refs = <ProcedureRef>[];
    final stream = client.stream(
      StreamQuery(
        filter: SymbolicFilter(typeNames: <String>{procedureTypeName}),
      ),
    );
    await for (final node in stream) {
      refs.add(ProcedureRef.brain(node.id.value));
    }
    refs.sort((a, b) => a.locator.compareTo(b.locator));
    return refs;
  }

  @override
  Future<ProcedureSource?> read(ProcedureRef ref) async {
    if (!handles(ref)) {
      throw ArgumentError.value(
        ref,
        'ref',
        'MemoryProcedureStore only handles the brain origin; '
            'got ${ref.origin.name}.',
      );
    }
    final node = await client.get(NodeId.fromString(ref.locator));
    if (node == null || node.typeName != procedureTypeName) return null;
    final source = node.values[sourceField];
    if (source is! String) return null;
    return ProcedureSource(ref: ref, source: source);
  }
}
