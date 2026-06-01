// ProcedureSource — the raw, unparsed source of one procedure plus the
// reference it was read from (Plan step C.23;
// `tom_brain_procedure_prototype_specification.md` § 9).
//
// This is the unit the store hands back from `read`. It carries the
// verbatim d4rt source — header doc-comment and body together — and the
// [ProcedureRef] it came from. C.23 does not interpret the source at
// all: parsing the header into a `ProcedureHeader` is the loader's job
// (C.24), and picking among versions is the resolver's job (C.25). The
// store's only promise is "these bytes are what is stored at this ref".

import 'procedure_ref.dart';

/// The verbatim source of one procedure, tagged with its origin ref.
///
/// Immutable. [source] is the exact text the backend holds (disk file
/// contents or the `Procedure` node's `source` field); it is **not**
/// parsed or validated by the store.
final class ProcedureSource {
  /// Where this source was read from.
  final ProcedureRef ref;

  /// The verbatim d4rt source (header doc-comment + body).
  final String source;

  const ProcedureSource({required this.ref, required this.source});

  @override
  bool operator ==(Object other) =>
      other is ProcedureSource &&
      other.ref == ref &&
      other.source == source;

  @override
  int get hashCode => Object.hash(ref, source);

  @override
  String toString() =>
      'ProcedureSource($ref, ${source.length} chars)';
}
