// TelegramInspectors — the read-only inspection seams the Telegram edge drives
// for the `/observatory_*`, `/show_logs`, `/memory_status`, and `/check_status`
// commands.
//
// ── Why these are seams, not direct reads ────────────────────────────
//
// The inspection commands surface the brain's *operational* state — the
// recorded incoming prompts (the Observatory trail), the important log files,
// the memory overview, and the live processing status (what is running now and
// the recent runs' outcomes / errors). None of that lives in the access
// package: the trail is written by `tom_brain_run`, the memory is
// `tom_brain_memory`, the run-slot state is owned by the procedure dispatcher,
// and the access package must not depend on any of them
// (`dependency_surface_test.dart`).
//
// So the edge consumes the same anti-dependency discipline the brain itself
// arrives through (`BrainProvisioner`): three narrow read-only *port*
// interfaces defined here, in access, and implemented in `tom_brain_run` (the
// one assembly that may legally read the trail and the memory). A higher
// assembly injects a [TelegramInspectors] bundle when it stands the process up;
// the CLI default ([TelegramInspectors.none]) supplies none, and the edge then
// answers each inspection command with a "not available on this deployment"
// reply rather than failing.
//
// Each port returns already-rendered, channel-neutral data (digests, tails, a
// status string). The edge owns the Telegram presentation — the message
// formatting and the 4096-code-unit split — so the ports stay free of any
// Telegram-specific concern.

/// One recorded incoming prompt's digest for the `/observatory_show_prompts`
/// list (parts b).
///
/// Carries exactly what the list line shows: the [index] the user passes to
/// `/observatory_analyze_prompt`, the [receivedAt] timestamp, and a [preview]
/// (the first N characters of the user prompt). Index `0` is the most recent
/// prompt — the list is newest-first and the same index addresses the same
/// prompt in [TelegramPromptInspector.promptDetail].
final class TelegramPromptDigest {
  /// The prompt's position in the newest-first list — the value the user
  /// passes to `/observatory_analyze_prompt`.
  final int index;

  /// When the prompt was received.
  final DateTime receivedAt;

  /// The first N characters of the user prompt (the preview length is the
  /// edge's choice, passed to [TelegramPromptInspector.recentPrompts]).
  final String preview;

  /// Builds a prompt digest.
  const TelegramPromptDigest({
    required this.index,
    required this.receivedAt,
    required this.preview,
  });
}

/// Reads the recorded incoming prompts back for the `/observatory_*` commands
/// (parts b + c).
///
/// Implemented in `tom_brain_run` over the §5.3 `incoming/` trail. The index
/// space is shared between the two methods: [recentPrompts] returns the newest
/// `limit` prompts newest-first (index `0` = most recent), and
/// [promptDetail] resolves the same index to that prompt's full detail.
abstract interface class TelegramPromptInspector {
  /// Returns up to [limit] of the most recently recorded prompts, newest-first,
  /// each with a [previewLength]-character preview of its user text.
  Future<List<TelegramPromptDigest>> recentPrompts({
    required int limit,
    required int previewLength,
  });

  /// Returns the full, already-rendered detail of the prompt at [index] (the
  /// index from a [recentPrompts] digest), or `null` when no prompt holds that
  /// index. The edge splits the returned text across Telegram messages.
  Future<String?> promptDetail(int index);
}

/// One log file's tail for the `/show_logs` command (part d).
final class TelegramLogTail {
  /// A human-readable identifier for the file (e.g. `brain.log`,
  /// `components/tom_brain.substrate.llm.log`).
  final String name;

  /// The tail of the file — its last N lines (the line count is the edge's
  /// choice, passed to [TelegramLogInspector.tailLogs]).
  final String content;

  /// Builds a log tail.
  const TelegramLogTail({required this.name, required this.content});
}

/// Reads the tails of the important log files for the `/show_logs` command
/// (part d).
///
/// Implemented in `tom_brain_run` over the trail root's `brain.log`,
/// `components/*.log`, and `memory/*.log`.
abstract interface class TelegramLogInspector {
  /// Returns the last [lines] lines of each important log file, one
  /// [TelegramLogTail] per file. An empty list when no log files exist (the
  /// edge then reports there is nothing to show).
  Future<List<TelegramLogTail>> tailLogs({required int lines});
}

/// Renders an overview of the brain's memory for the `/memory_status` command
/// (part e).
///
/// Implemented in `tom_brain_run` over the memory client's `stats()`.
abstract interface class TelegramMemoryInspector {
  /// Returns an already-rendered, multi-line overview of the memory (node and
  /// edge counts, stack sizes, trail totals). The edge splits it across
  /// Telegram messages if it overflows.
  Future<String> status();
}

/// Renders a comprehensive operational status for the `/check_status` command.
///
/// Implemented in `tom_brain_run` over the live dispatcher-coordinator snapshot
/// (what is running right now) plus the on-disk trail (the latest received
/// prompt, the recent procedure runs' outcomes, and any errors — budget
/// overruns included). Answers the user's "what is the system doing without me
/// sending another prompt?" — whether a prompt is in flight, or, if processing
/// has stopped, what halted it.
abstract interface class TelegramStatusInspector {
  /// Returns an already-rendered, multi-line operational status: the live
  /// processing state, the latest prompt, and the recent runs' outcomes and
  /// errors. The edge splits it across Telegram messages if it overflows.
  Future<String> report();
}

/// Reads and clears the working todo list of one conversation session for the
/// `/todos_list` and `/todos_clear` commands.
///
/// The brain keeps a scratch todo list per conversation session (the engine's
/// process-lifetime `SessionTodoStores`), surviving across the prompts of a
/// conversation but never written to memory. Implemented in `tom_brain_run`,
/// the one assembly that may read the engine's stores; the access edge owns the
/// session resolution (it maps the Telegram user to its active session id) and
/// hands that id in. Each method returns already-rendered, channel-neutral text.
abstract interface class TelegramTodosInspector {
  /// Renders the working todo list of the session [sessionId] — each entry's
  /// done-state and text — or an explicit empty notice when the session holds
  /// no list yet or it is empty.
  Future<String> list(String sessionId);

  /// Empties the working todo list of the session [sessionId] and renders the
  /// outcome (how many entries were removed, or that there was nothing to
  /// clear).
  Future<String> clear(String sessionId);
}

/// Renders the live budget of the prompt being processed right now for the
/// `/check_usage` command.
///
/// Where [TelegramStatusInspector] answers "what is the system doing?", this
/// answers "how much has the current prompt spent *so far*?" — the elapsed time
/// since the prompt started and its accumulating effort (LLM calls, tool calls,
/// estimated tokens). It reads the engine's process-lifetime live-run registry
/// (the single foreground prompt's open runs), so it is process-global: there is
/// no session to resolve. Implemented in `tom_brain_run`, the one assembly that
/// may read the engine. Returns already-rendered, channel-neutral text.
abstract interface class TelegramUsageInspector {
  /// Renders the live budget of the prompt currently being processed — elapsed
  /// time and accumulated effort — or an explicit "no prompt is being
  /// processed" notice when nothing is in flight.
  Future<String> currentUsage();
}

/// Interrupts the prompt being processed right now for the `/stop_prompt`
/// command.
///
/// The one *controller* among the inspection seams — every other port reads,
/// this one acts. It cooperatively cancels the single foreground prompt's
/// in-flight run via the engine's process-lifetime live-run registry, so like
/// [TelegramUsageInspector] it is process-global (no session to resolve).
/// Implemented in `tom_brain_run`, the one assembly that may reach the engine.
/// Returns already-rendered, channel-neutral text.
abstract interface class TelegramStopController {
  /// Cooperatively interrupts the prompt currently being processed and renders
  /// the outcome — a "stopped" confirmation when a prompt was in flight, or an
  /// explicit "no prompt is being processed" notice when the brain is idle.
  Future<String> stopCurrentPrompt();
}

/// The read-only inspectors the Telegram edge drives for the inspection
/// commands (parts b–e).
///
/// Each member is optional: a `null` member means that inspection is *not
/// available on this deployment*, and the edge replies accordingly. The CLI
/// default is [none] (no inspector wired); a higher assembly (`tom_brain_run`)
/// injects a bundle built over the live trail + memory.
final class TelegramInspectors {
  /// Reads recorded prompts for `/observatory_show_prompts` +
  /// `/observatory_analyze_prompt`, or `null` when unavailable.
  final TelegramPromptInspector? prompts;

  /// Reads log tails for `/show_logs`, or `null` when unavailable.
  final TelegramLogInspector? logs;

  /// Reads the memory overview for `/memory_status`, or `null` when
  /// unavailable.
  final TelegramMemoryInspector? memory;

  /// Reads the live operational status for `/check_status`, or `null` when
  /// unavailable.
  final TelegramStatusInspector? status;

  /// Reads and clears the active session's working todo list for `/todos_list`
  /// and `/todos_clear`, or `null` when unavailable.
  final TelegramTodosInspector? todos;

  /// Reads the live budget of the prompt being processed now for
  /// `/check_usage`, or `null` when unavailable.
  final TelegramUsageInspector? usage;

  /// Interrupts the prompt being processed now for `/stop_prompt`, or `null`
  /// when unavailable.
  final TelegramStopController? stop;

  /// Builds an inspector bundle; every member defaults to absent.
  const TelegramInspectors({
    this.prompts,
    this.logs,
    this.memory,
    this.status,
    this.todos,
    this.usage,
    this.stop,
  });

  /// The no-inspectors bundle: every inspection command answers "not available
  /// on this deployment". The standalone access binary uses this.
  static const TelegramInspectors none = TelegramInspectors();
}
