// ProcedureHeader — the parsed structured header of one procedure
// (Plan step C.24; `tom_brain_procedure_prototype_specification.md`
// § 4.4).
//
// Every procedure begins with a `/// @procedure` doc-comment block the
// loader parses into this value type. The header is the procedure's
// contract: id + version identify it, summary + successCriterion describe
// it, inputs + outputs declare its signature, budget caps its effort, and
// `requires` lists the bridged primitives it is allowed to call. The
// loader (C.24) produces a `ProcedureHeader`; the resolver (C.25) indexes
// procedures by `(id → version)` off it; the validator (C.27–C.29) checks
// it more deeply (version monotonicity, requires-matches-actual-calls).
//
// These are pure value types — immutable, with value equality — so a
// parsed header can be compared, cached, and carried through a trail
// without surprise.

/// One declared input of a procedure's `run` signature (§ 4.4).
///
/// `{ name: text, type: String, required: true }` in the header YAML.
/// [required] defaults to `false` when the header omits it.
final class ProcedureInputDecl {
  /// The input's name, the key under which the runtime binds its value.
  final String name;

  /// The declared Dart type name (e.g. `String`). Free text at the loader
  /// layer; the engine coerces against it.
  final String type;

  /// Whether the input must be supplied. Defaults to `false`.
  final bool required;

  const ProcedureInputDecl({
    required this.name,
    required this.type,
    this.required = false,
  });

  @override
  bool operator ==(Object other) =>
      other is ProcedureInputDecl &&
      other.name == name &&
      other.type == type &&
      other.required == required;

  @override
  int get hashCode => Object.hash(name, type, required);

  @override
  String toString() =>
      'ProcedureInputDecl($name: $type${required ? ', required' : ''})';
}

/// One declared output of a procedure's `ProcedureResult` (§ 4.4).
///
/// `{ name: answer, type: String }` in the header YAML.
final class ProcedureOutputDecl {
  /// The output's name, the key under which the result carries its value.
  final String name;

  /// The declared Dart type name.
  final String type;

  const ProcedureOutputDecl({required this.name, required this.type});

  @override
  bool operator ==(Object other) =>
      other is ProcedureOutputDecl &&
      other.name == name &&
      other.type == type;

  @override
  int get hashCode => Object.hash(name, type);

  @override
  String toString() => 'ProcedureOutputDecl($name: $type)';
}

/// The procedure-level budget caps declared in the header (§ 4.4, § 5.4).
///
/// `budget: { wallClockMs: 60000, tokenSpend: 8000, toolCalls: 12,
/// memoryWrites: 6 }`. Each cap is optional — a header may set only the
/// dimensions it cares about — but the `budget` block as a whole is a
/// required header field (an empty block is rejected by the loader). The
/// four named accessors cover the dimensions the prototype enforces; any
/// further keys are preserved in [raw] so a forward header can carry caps
/// the prototype does not yet read without losing them.
final class ProcedureBudget {
  /// Wall-clock ceiling for the whole procedure run, in milliseconds.
  final int? wallClockMs;

  /// Combined input+output token ceiling across all `llm` calls.
  final int? tokenSpend;

  /// Maximum number of tool (bridged primitive) calls.
  final int? toolCalls;

  /// Maximum number of memory writes (`persist` / `edge` / stack writes).
  final int? memoryWrites;

  /// The verbatim parsed budget map, including any keys beyond the four
  /// named caps. Immutable.
  final Map<String, int> raw;

  ProcedureBudget(Map<String, int> raw)
      : raw = Map<String, int>.unmodifiable(raw),
        wallClockMs = raw['wallClockMs'],
        tokenSpend = raw['tokenSpend'],
        toolCalls = raw['toolCalls'],
        memoryWrites = raw['memoryWrites'];

  /// Whether this budget declares no caps at all.
  bool get isEmpty => raw.isEmpty;

  @override
  bool operator ==(Object other) {
    if (other is! ProcedureBudget) return false;
    if (other.raw.length != raw.length) return false;
    for (final entry in raw.entries) {
      if (other.raw[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAllUnordered(
        raw.entries.map((e) => Object.hash(e.key, e.value)),
      );

  @override
  String toString() {
    final parts = raw.entries.map((e) => '${e.key}: ${e.value}').join(', ');
    return 'ProcedureBudget($parts)';
  }
}

/// The fully parsed structured header of a procedure (§ 4.4).
///
/// Produced by the C.24 loader. Required fields ([id], [version],
/// [summary], [successCriterion], [budget]) are guaranteed non-null /
/// non-empty by construction — the loader rejects a header missing any of
/// them with [ProcedureHeaderInvalid] before ever building this object.
/// [inputs], [outputs], and [requires] default to empty when the header
/// omits them.
final class ProcedureHeader {
  /// The procedure's stable id (e.g. `answer_with_memory_v1`).
  final String id;

  /// The procedure's integer version (e.g. `1`).
  final int version;

  /// A one-line description of what the procedure does.
  final String summary;

  /// The condition under which a run counts as successful.
  final String successCriterion;

  /// Declared inputs of the `run` signature. Empty when none declared.
  final List<ProcedureInputDecl> inputs;

  /// Declared outputs of the `ProcedureResult`. Empty when none declared.
  final List<ProcedureOutputDecl> outputs;

  /// Procedure-level budget caps.
  final ProcedureBudget budget;

  /// The bridged primitives the procedure declares it will use. Empty when
  /// none declared. The validator (C.29) cross-checks this against the
  /// primitives the body actually calls.
  final List<String> requires;

  ProcedureHeader({
    required this.id,
    required this.version,
    required this.summary,
    required this.successCriterion,
    required this.budget,
    List<ProcedureInputDecl> inputs = const <ProcedureInputDecl>[],
    List<ProcedureOutputDecl> outputs = const <ProcedureOutputDecl>[],
    List<String> requires = const <String>[],
  })  : inputs = List<ProcedureInputDecl>.unmodifiable(inputs),
        outputs = List<ProcedureOutputDecl>.unmodifiable(outputs),
        requires = List<String>.unmodifiable(requires);

  @override
  bool operator ==(Object other) =>
      other is ProcedureHeader &&
      other.id == id &&
      other.version == version &&
      other.summary == summary &&
      other.successCriterion == successCriterion &&
      other.budget == budget &&
      _listEq(other.inputs, inputs) &&
      _listEq(other.outputs, outputs) &&
      _listEq(other.requires, requires);

  @override
  int get hashCode => Object.hash(
        id,
        version,
        summary,
        successCriterion,
        budget,
        Object.hashAll(inputs),
        Object.hashAll(outputs),
        Object.hashAll(requires),
      );

  @override
  String toString() => 'ProcedureHeader($id v$version)';

  static bool _listEq<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
