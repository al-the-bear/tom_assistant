// ProcedureRef — a backend-local handle to one procedure's source
// (Plan step C.23; `tom_brain_procedure_specification.md`
// § 9).
//
// `ProcedureRef` is the *address* of a procedure inside a backend, not
// its identity. C.23 deliberately stops short of reading the structured
// header — the procedure's real id and version live inside the source
// and are parsed by the loader (C.24), then indexed by the resolver
// (C.25). Until then a procedure is addressed by where it physically
// lives: a file path for the disk backend, a node-id string for the
// memory backend. Keeping the store keyed on physical location (not on
// header identity) is what lets the store stay a pure I/O layer with no
// knowledge of the header grammar.

import 'procedure_origin.dart';

/// A backend-local handle to one procedure's source.
///
/// The pair ([origin], [locator]) uniquely identifies a procedure within
/// the store: no two backends mint the same `(origin, locator)` because
/// the disk backend only ever produces [ProcedureOrigin.system] /
/// [ProcedureOrigin.user] refs and the memory backend only ever produces
/// [ProcedureOrigin.brain] refs.
///
/// For the disk backend, [locator] is the absolute file path. For the
/// memory backend, [locator] is the `Procedure` node-id string.
final class ProcedureRef {
  /// Provenance + backend discriminator.
  final ProcedureOrigin origin;

  /// Backend-local locator: a file path (disk) or a node-id string
  /// (memory).
  final String locator;

  const ProcedureRef({required this.origin, required this.locator});

  /// Convenience constructor for a disk-backed system procedure.
  const ProcedureRef.system(String path)
      : origin = ProcedureOrigin.system,
        locator = path;

  /// Convenience constructor for a disk-backed user procedure.
  const ProcedureRef.user(String path)
      : origin = ProcedureOrigin.user,
        locator = path;

  /// Convenience constructor for a memory-backed brain procedure.
  const ProcedureRef.brain(String nodeId)
      : origin = ProcedureOrigin.brain,
        locator = nodeId;

  @override
  bool operator ==(Object other) =>
      other is ProcedureRef &&
      other.origin == origin &&
      other.locator == locator;

  @override
  int get hashCode => Object.hash(origin, locator);

  @override
  String toString() => 'ProcedureRef(${origin.name}: $locator)';
}
