// B.21 — `RoleBudgetDefaults`.
//
// `substrate_specification.md` § 6.1 lists "budgetDefaults — Token /
// wall-clock defaults if the caller does not override" as a field of
// `RoleTemplate`. The B.21 plan text names this same field as one of
// the four `RoleTemplate` shipped this step ("persona text, objective,
// allowed-action set, budget defaults").
//
// The B.18 / B.19 router work already cross-references this field —
// `lib/src/api/llm_call.dart` § `LlmOptions.model` doc says the
// resolution order is:
//
//   1. `LlmOptions.model` (per-call override),
//   2. `budgetDefaults.modelPreference` (role-level preferences),
//   3. provider default.
//
// So `RoleBudgetDefaults` must, at minimum, carry `modelPreference`.
// The other knobs (temperature, max output tokens, default wall-clock,
// default token spend) are the natural-fit fields that round out the
// "defaults if the caller does not override" semantic without expanding
// scope.
//
// Why a dedicated type rather than re-using `LlmOptions`:
//
//   * `LlmOptions.model` is a *single* override (`String?`); the role
//     defaults need a *prioritised list* (the router walks first-
//     route-available wins). Forcing both shapes onto one field would
//     change `LlmOptions.model` from `String?` to `List<String>`, which
//     would break every existing consumer of `LlmOptions` for a benefit
//     that lives only inside the role registry.
//
//   * `LlmOptions` carries call-only knobs (`stopSequences`,
//     `toolCatalogue`, `responseFormat`) that are call-level, not
//     role-level — bundling them onto the role defaults would suggest
//     a role can pin a `toolCatalogue`, which is the dispatcher's job
//     via `allowedActions` (separate field).
//
//   * The router-side merge (B.18+) reads two different shapes (the
//     per-call `LlmOptions` and the role's `RoleBudgetDefaults`) and
//     produces a third shape (the wire knobs handed to the provider).
//     Two distinct types make the merge sites grep-able and the
//     direction-of-information explicit.
//
// What this file deliberately does NOT own:
//
//   * The merge algorithm. Lives at the router (B.18+) — specifically
//     in the dispatch path that resolves an `LlmCall` against the
//     route chain. The merge order is documented on `LlmOptions.model`.
//
//   * The procedure-runtime `Budget` envelope (wall-clock / token /
//     tool-call / memory-write caps the procedure spends against).
//     That is a *per-run* concept owned by `tom_brain_shared.Budget`
//     and supplied by the procedure dispatcher (Phase D). The
//     `RoleBudgetDefaults` shipped here are the per-LLM-call defaults
//     for fields the caller can leave unset on `LlmOptions`; they do
//     not feed into the procedure's `Budget`.
//
//   * The "ceiling" semantic. Future "per-role caps" (e.g. "evaluator
//     may never spend more than 4k tokens") would be a separate
//     `RoleBudgetCaps` value; defaults *are not* caps and the two
//     concepts have different enforcement points.

/// Defaults the router applies to an `LlmCall` whose `LlmOptions`
/// leaves the corresponding field unset.
///
/// Sourced from a role's `RoleTemplate.budgetDefaults`. Resolution
/// at the router (B.18+) follows the order documented on
/// `LlmOptions.model`:
///
///   1. `LlmOptions.<field>` if non-null (per-call override).
///   2. `RoleBudgetDefaults.<field>` if non-null (role-level default).
///   3. Provider default (e.g. Ollama's environment-configured model).
///
/// Every field is optional except [modelPreference], which is a
/// list-typed field with `const <String>[]` as its default (i.e. "no
/// role-level preference; fall through to provider default").
///
/// Value-class semantics: `final`, immutable, `==` / `hashCode` defined,
/// `toString` for diagnostics.
final class RoleBudgetDefaults {
  /// Preferred model ids, in priority order.
  ///
  /// The router walks the list and selects the first model id that
  /// any route in the role's chain exposes. An empty list means "no
  /// role-level preference; defer to the per-call `LlmOptions.model`
  /// or the provider default."
  ///
  /// Stored as `List<String>` (not a `Set`) because order is
  /// load-bearing — `['gemma3:27b', 'gemma2:9b']` prefers the larger
  /// model first; reversing the list would change the routing
  /// decision. The list is treated as immutable; future builds that
  /// take a `Set` would lose the ordering invariant silently.
  final List<String> modelPreference;

  /// Default sampling temperature in `[0.0, 2.0]`, or `null` when
  /// the role has no preference.
  ///
  /// Mirrors `LlmOptions.temperature`; the field name matches so a
  /// reader of the role config does not have to translate
  /// "samplingTemperature" / "temp" / etc.
  final double? temperature;

  /// Default hard cap on the response token count, or `null` when
  /// the role has no preference.
  ///
  /// Mirrors `LlmOptions.maxOutputTokens`. As on that field, this
  /// caps output only — input-token bounding is on the procedure's
  /// `Budget.tokenSpend`, not here.
  final int? maxOutputTokens;

  /// Default wall-clock ceiling in milliseconds for a single LLM
  /// call under this role, or `null` when the role has no preference.
  ///
  /// `null` means "no role-level wall-clock guidance; the procedure
  /// runtime's `Budget.wallClockMs` is the only source of truth". A
  /// non-null value is the *advisory* default the router stamps on
  /// `LlmCallReport.notes` when used; the procedure's `Budget` is
  /// always the enforced ceiling and a role-level default can never
  /// raise it.
  final int? wallClockMsDefault;

  /// Default token-spend (input + output) for a single LLM call
  /// under this role, or `null` when the role has no preference.
  ///
  /// Same advisory semantic as [wallClockMsDefault] — the procedure
  /// runtime's `Budget.tokenSpend` is the enforced cap; this is a
  /// hint the router uses when the per-call options leave the field
  /// blank.
  final int? tokenSpendDefault;

  /// Constructs an instance with optional fields and a (possibly
  /// empty) [modelPreference] list.
  ///
  /// Validation:
  ///   * [temperature] must be in `[0.0, 2.0]` when non-null.
  ///   * [maxOutputTokens] must be `> 0` when non-null.
  ///   * [wallClockMsDefault] must be `> 0` when non-null.
  ///   * [tokenSpendDefault] must be `> 0` when non-null.
  ///
  /// Each violation throws an [ArgumentError] at construction —
  /// fail-fast on misconfigured roles so the registry refuses to
  /// `open()` rather than failing on first dispatch.
  factory RoleBudgetDefaults({
    List<String> modelPreference = const <String>[],
    double? temperature,
    int? maxOutputTokens,
    int? wallClockMsDefault,
    int? tokenSpendDefault,
  }) {
    if (temperature != null && (temperature < 0.0 || temperature > 2.0)) {
      throw ArgumentError.value(
        temperature,
        'temperature',
        'must be in [0.0, 2.0]',
      );
    }
    if (maxOutputTokens != null && maxOutputTokens <= 0) {
      throw ArgumentError.value(
        maxOutputTokens,
        'maxOutputTokens',
        'must be > 0',
      );
    }
    if (wallClockMsDefault != null && wallClockMsDefault <= 0) {
      throw ArgumentError.value(
        wallClockMsDefault,
        'wallClockMsDefault',
        'must be > 0',
      );
    }
    if (tokenSpendDefault != null && tokenSpendDefault <= 0) {
      throw ArgumentError.value(
        tokenSpendDefault,
        'tokenSpendDefault',
        'must be > 0',
      );
    }
    // Defensive copy + freeze: the registry hands instances out to
    // callers that may not respect the implicit immutability of a
    // value-class field.
    return RoleBudgetDefaults._(
      List<String>.unmodifiable(modelPreference),
      temperature,
      maxOutputTokens,
      wallClockMsDefault,
      tokenSpendDefault,
    );
  }

  const RoleBudgetDefaults._(
    this.modelPreference,
    this.temperature,
    this.maxOutputTokens,
    this.wallClockMsDefault,
    this.tokenSpendDefault,
  );

  /// The all-defaults instance: empty model preference, no
  /// temperature / max-output / wall-clock / token-spend hint. Used
  /// as the default value on [RoleBudgetDefaults]-typed fields that
  /// want "role provides no guidance" without forcing every role to
  /// construct an explicit instance.
  ///
  /// Equivalent to `const RoleBudgetDefaults._(const [], null, null,
  /// null, null)` (with the empty list typed as `List&lt;String&gt;`) —
  /// every field at its "router resolves" default.
  static const RoleBudgetDefaults empty = RoleBudgetDefaults._(
    <String>[],
    null,
    null,
    null,
    null,
  );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! RoleBudgetDefaults) return false;
    if (other.temperature != temperature) return false;
    if (other.maxOutputTokens != maxOutputTokens) return false;
    if (other.wallClockMsDefault != wallClockMsDefault) return false;
    if (other.tokenSpendDefault != tokenSpendDefault) return false;
    if (other.modelPreference.length != modelPreference.length) return false;
    for (var i = 0; i < modelPreference.length; i++) {
      if (other.modelPreference[i] != modelPreference[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        Object.hashAll(modelPreference),
        temperature,
        maxOutputTokens,
        wallClockMsDefault,
        tokenSpendDefault,
      );

  @override
  String toString() => 'RoleBudgetDefaults('
      'modelPreference: $modelPreference, '
      'temperature: $temperature, '
      'maxOutputTokens: $maxOutputTokens, '
      'wallClockMsDefault: $wallClockMsDefault, '
      'tokenSpendDefault: $tokenSpendDefault)';
}
