// CapabilitySet — the set of bridged-API `requires` names a procedure declares,
// and the overlap measure the selector re-rank scores on
// (`procedure_specification.md` § 7.3, § 10.3).
//
// A procedure's header lists the bridged primitives its body calls (`requires`).
// When the runtime ranks candidate procedures for an incoming request, one of
// the four re-rank weights is "header `requires` set overlap with the caller's
// available capabilities" — a procedure that needs primitives the current
// context cannot supply should rank lower. [coverageBy] is that measure.
//
// This lives in shared (not in `tom_brain_procedure`) because the same set is
// stored on the Procedure node (memory), fed to the domain-free scorer
// (`tom_core_agentic`), and stamped by the authoring loop (procedure) — shared
// vocabulary, owned by none of them.

/// An immutable, order-independent set of bridged-API `requires` names.
///
/// Equality and [hashCode] are set-based: two `CapabilitySet`s with the same
/// names compare equal regardless of construction order.
final class CapabilitySet {
  /// Builds a capability set over an already-deduplicated [names] set.
  const CapabilitySet(this.names);

  /// Builds a capability set from any iterable, de-duplicating into the
  /// canonical set.
  factory CapabilitySet.fromIterable(Iterable<String> names) =>
      CapabilitySet(names.toSet());

  /// The canonical `requires` names.
  final Set<String> names;

  /// Whether [name] is one of the required capabilities.
  bool contains(String name) => names.contains(name);

  /// Whether every name in [other] is present here.
  bool containsAll(CapabilitySet other) => names.containsAll(other.names);

  /// Whether this set declares no capabilities (a procedure that needs
  /// nothing from the bridged surface).
  bool get isEmpty => names.isEmpty;

  /// The fraction of *this* set's names that [available] can supply.
  ///
  /// `|this ∩ available| / |this|` — how much of what the procedure needs the
  /// caller's context provides. An empty requirement is fully covered (1.0):
  /// a procedure that needs nothing is runnable anywhere.
  double coverageBy(CapabilitySet available) {
    if (names.isEmpty) return 1.0;
    final covered = names.where(available.names.contains).length;
    return covered / names.length;
  }

  @override
  bool operator ==(Object other) =>
      other is CapabilitySet &&
      names.length == other.names.length &&
      names.containsAll(other.names);

  @override
  int get hashCode {
    // Order-independent hash: XOR the element hashes so two sets with the same
    // members (any order) hash equal, consistent with set-based `==`.
    var hash = 0;
    for (final name in names) {
      hash ^= name.hashCode;
    }
    return Object.hash(names.length, hash);
  }

  @override
  String toString() => 'CapabilitySet(${(names.toList()..sort()).join(', ')})';
}
