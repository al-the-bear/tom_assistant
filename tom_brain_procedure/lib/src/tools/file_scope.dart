// FileScope — the two-tier file sandbox a `BrainTool` resolves paths against
// (`tom_brain_procedure_specification.md` § 21.4; PE-1).
//
// The file sandbox is a *value*, not a capability (PE-1). Earlier it was a
// single priority-ordered list of roots: every root was readable and the first
// was the lone write target. A deployment needs a finer grant than that — some
// directories a brain may read but must never modify (a colocated workspace it
// inspects for context), others it may freely write and delete in (its own
// scratch tree). [FileScope] splits the one list into two:
//
//   - [writeRoots] — directories a write/edit/delete tool may target, in
//     priority order; the first is the primary `file.write` target.
//   - [readRoots]  — directories that are readable but NOT writeable.
//
// A writeable directory is implicitly readable (you cannot meaningfully write a
// file you may not read back), so [readableRoots] is the union — every write
// root followed by the read-only roots. A read tool (`file.read`, `file.diff`,
// `grep.search`, `file.search`, `analyze.*`, `file.list`) resolves against
// [readableRoots]; a write tool (`file.write`, `file.edit`, `file.delete`,
// `test.*`) resolves against [writeableRoots]. A path that escapes the relevant
// set raises `FileScopeViolation` before any byte moves — exactly as the
// single-list sandbox did, now against the tool's own tier.
//
// Immutable: both lists are unmodifiable, and [readableRoots] is computed once.

/// The two-tier file-scope sandbox the `file.*` tools resolve against (§ 21.4).
///
/// A read tool resolves against [readableRoots] (the union of write + read-only
/// roots); a write/delete tool resolves against [writeableRoots] (the write
/// roots verbatim). At least one root — readable or writeable — must be present.
final class FileScope {
  /// Builds a scope from explicit write and read-only root lists.
  ///
  /// [writeRoots] are the directories a write/edit/delete tool may target, in
  /// priority order (the first is the primary write target). [readRoots] are
  /// directories that are readable but not writeable. At least one of the two
  /// must be non-empty (an empty sandbox admits nothing).
  FileScope({
    required List<String> writeRoots,
    List<String> readRoots = const <String>[],
  })  : assert(writeRoots.isNotEmpty || readRoots.isNotEmpty,
            'a FileScope must carry at least one writeable or readable root'),
        writeRoots = List<String>.unmodifiable(writeRoots),
        readRoots = List<String>.unmodifiable(readRoots);

  /// Builds a scope from a single priority-ordered list under the legacy
  /// single-`fileScope` interpretation: the first root is the lone write target
  /// and every remaining root is read-only. Retained for the engine's neutral
  /// default and for callers that still carry one undifferentiated list.
  factory FileScope.fromPriorityList(List<String> roots) {
    if (roots.isEmpty) {
      throw ArgumentError.value(
          roots, 'roots', 'a FileScope needs at least one root');
    }
    return FileScope(
      writeRoots: <String>[roots.first],
      readRoots: roots.sublist(1),
    );
  }

  /// Directories a write/edit/delete tool may target, in priority order. The
  /// first is the primary `file.write` target. Unmodifiable.
  final List<String> writeRoots;

  /// Directories that are readable but NOT writeable, in priority order.
  /// Unmodifiable.
  final List<String> readRoots;

  /// Roots a write/delete tool may target — [writeRoots] verbatim.
  List<String> get writeableRoots => writeRoots;

  /// Roots a read tool may reach: every write root (writeable ⇒ readable)
  /// followed by the read-only roots, de-duplicated with write roots kept
  /// first. Computed once on first access. Unmodifiable.
  late final List<String> readableRoots = List<String>.unmodifiable(<String>[
    ...writeRoots,
    for (final root in readRoots)
      if (!writeRoots.contains(root)) root,
  ]);
}
