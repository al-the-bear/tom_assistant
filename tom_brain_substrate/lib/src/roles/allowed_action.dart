// B.21 — `AllowedAction` and `ForbiddenAction` enumeration.
//
// `substrate_specification.md` § 6.1 lists "allowedActions — What stages
// may do (tool calls allowed? sub-thinking allowed? user-facing answer
// allowed?)" and "forbiddenActions — Hard prohibitions" as fields of
// `RoleTemplate`. Both are *closed sets of well-known action tokens*
// the dispatcher (Phase D) consults to gate operations a role attempts
// during a procedure run.
//
// Why a closed enum rather than a free-form `Set<String>`:
//
//   * The dispatcher's gate (`actionGate.check(roleId, action)`, Phase D)
//     compares tokens by equality. A typo in a role definition ("toolcal"
//     vs `tool_call`) would silently *allow* the action — the gate would
//     fail to find a match in either allowed or forbidden, and the
//     default-deny / default-allow policy of the gate would decide. A
//     closed enum makes the typo a compile error in role-definition
//     code instead of a silent permission leak at runtime.
//
//   * The roster of actions is small (six tokens for the prototype) and
//     adding a new one is a deliberate spec change, not an ad-hoc role
//     edit. Closed-set discipline matches that cadence.
//
//   * Persistence (when actions ship to / from disk in role config files
//     at B.22) round-trips through the canonical [token]; the YAML loader
//     resolves a string to an enum via [AllowedAction.fromToken] and
//     fails the load with a descriptive error if the token is unknown.
//     Free-form strings would defer that check to dispatch time.
//
// What this file deliberately does NOT own:
//
//   * The gate logic. Lives at the dispatcher layer (Phase D). The roles
//     surface only *declares* what is allowed / forbidden; checking that
//     a specific procedure call honours the declaration is the
//     dispatcher's job.
//
//   * Per-procedure overrides. A role's `allowedActions` is the *ceiling*
//     for a procedure that runs in that role; a procedure can declare a
//     subset in its header (`procedure_specification.md` § 4) but cannot
//     widen past the role's allow-list. The "narrow further" mechanism
//     lives in the procedure header parser, not here.
//
//   * The action's runtime mechanics. `tool_call` does not name a
//     specific tool; it names the *category* of operation. A role with
//     `tool_call` in its allow-list may invoke any tool in its
//     `LlmCall.options.toolCatalogue`; a role without it cannot call
//     any tool, regardless of catalogue.

/// The closed set of action tokens a role may declare in its
/// `allowedActions` or `forbiddenActions`.
///
/// Tokens map 1:1 to dispatch-time operations the procedure runtime
/// gates on. Each enum value carries a stable [token] string used in
/// YAML serialisation and trail records; the token is the canonical
/// identity (renaming an enum value preserves the token).
///
/// Six tokens at B.21:
///
///   * [toolCall]            — `tool_call` — the role may invoke any
///     tool listed in `LlmCall.options.toolCatalogue`. A role without
///     this token cannot invoke any tool regardless of catalogue.
///   * [subThinking]         — `sub_thinking` — the role may spawn
///     sub-question dispatches (procedure runtime's `sub_thinker`
///     entry point). The thinking loop's `analyser` and `sub_thinker`
///     roles carry it; user-facing `assistant_to_user` does not.
///   * [userFacingAnswer]    — `user_facing_answer` — the role's
///     output is shown to the user verbatim. Only `assistant_to_user`
///     carries this in the prototype roster. Internal roles
///     (`analyser`, `evaluator`, etc.) emit text that is consumed by
///     other procedures, not the user.
///   * [memoryRead]          — `memory_read` — the role may issue
///     memory recall / search / graph-walk operations. Every prototype
///     role carries it; declared explicitly so a future "isolated
///     thinker" role can drop it.
///   * [memoryWrite]         — `memory_write` — the role may issue
///     memory write operations (event ingest, claim mint, etc.).
///     The dispatcher's `memoryWrites` budget cap is separate; this
///     token gates whether writes are *attempted at all*.
///   * [llmCall]             — `llm_call` — the role may issue
///     further LLM dispatches via the substrate (i.e. recursive
///     thinking). Every prototype role carries it; declared
///     explicitly so a "pure-tool" or "pure-memory" role variant can
///     drop it.
///
/// New tokens are added by extending this enum and bumping the
/// substrate's role-config schema (the YAML loader at B.22 will fail
/// loading config that references an unknown token, so adding the
/// token to the enum and to the loader's allow-list is one
/// coordinated change).
enum AllowedAction {
  /// `tool_call` — the role may invoke any tool listed in
  /// `LlmCall.options.toolCatalogue`.
  toolCall._('tool_call'),

  /// `sub_thinking` — the role may spawn sub-question dispatches.
  subThinking._('sub_thinking'),

  /// `user_facing_answer` — the role's output is shown to the user
  /// verbatim. Reserved for `assistant_to_user`.
  userFacingAnswer._('user_facing_answer'),

  /// `memory_read` — the role may issue memory recall, search, or
  /// graph-walk operations.
  memoryRead._('memory_read'),

  /// `memory_write` — the role may issue memory write operations.
  /// The `memoryWrites` budget cap on `Budget` is separate; this
  /// token gates whether writes are attempted at all.
  memoryWrite._('memory_write'),

  /// `llm_call` — the role may issue further LLM dispatches via the
  /// substrate (recursive thinking).
  llmCall._('llm_call');

  /// Stable serialisation token. Round-trips through YAML / trail
  /// records. Never rename a token without a coordinated migration.
  final String token;

  const AllowedAction._(this.token);

  /// Resolves a serialised token back to an enum value.
  ///
  /// Throws [ArgumentError] when [token] is not recognised — the
  /// failure mode the YAML loader (B.22) surfaces to the caller as a
  /// `RoleConfigInvalid` so an unknown action token cannot silently
  /// be ignored.
  ///
  /// O(n) over the six enum values — the roster is small enough that
  /// a static map would be premature.
  static AllowedAction fromToken(String token) {
    for (final v in values) {
      if (v.token == token) return v;
    }
    throw ArgumentError.value(
      token,
      'token',
      'unknown allowed-action token; '
          'expected one of ${values.map((v) => v.token).toList()}',
    );
  }

  /// Returns the [token]. Identity short-cut for code that wants the
  /// stable string without remembering whether the field is `name` or
  /// `token`.
  @override
  String toString() => token;
}
