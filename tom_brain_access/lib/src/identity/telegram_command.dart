// The Telegram slash-command vocabulary, its parser, and the `/help` text
// (access spec § 6.5 + the inspection commands).
//
// ── Why one parser for every command ─────────────────────────────────
//
// A Telegram user drives the brain with plain prompts and with slash
// commands. The commands fall into three families, but they are all just
// `/word [argument]` lines off the same channel, so one parser recognises
// them all and the edge dispatches each family to its handler:
//
//   * session continuity (§ 6.5) — `/create_session`, `/list_sessions`,
//     `/pick_session`, `/rename_session`, handled by the
//     `TelegramSessionRegistry`;
//   * discoverability — `/help`, answered from [telegramHelpText];
//   * inspection — `/observatory_show_prompts`, `/observatory_analyze_prompt`,
//     `/show_logs`, `/memory_status`, answered by the injected read-only
//     inspectors (absent ⇒ a "not available on this deployment" reply).
//
// The parser is pure (no I/O, no state); the edge owns the dispatch and the
// inspectors own the reads. Keeping the vocabulary in one place is what lets
// [telegramHelpText] stay in lock-step with what the parser actually accepts.

/// Every Telegram slash-command the edge understands. A line that is not one
/// of these (an ordinary prompt, or an unknown `/word`) parses to `null`.
enum TelegramCommandKind {
  /// `/create_session <name>` — mint a new session and activate it (§ 6.5).
  createSession,

  /// `/list_sessions` — list every session, three-digit-numbered (§ 6.5).
  listSessions,

  /// `/pick_session <nnn>` — activate the session at a three-digit index
  /// (§ 6.5).
  pickSession,

  /// `/rename_session <new name>` — rename the active session (§ 6.5).
  renameSession,

  /// `/help` — list every available command.
  help,

  /// `/observatory_show_prompts` — list the recently-recorded prompts, each
  /// with an index, timestamp, and a short preview.
  observatoryShowPrompts,

  /// `/observatory_analyze_prompt <index>` — show the full detail of the
  /// prompt at the [observatoryShowPrompts] index.
  observatoryAnalyzePrompt,

  /// `/show_logs` — show the tail of each important log file.
  showLogs,

  /// `/memory_status` — show an overview of the brain's memory (node/edge
  /// counts, stack sizes, trail totals).
  memoryStatus,

  /// `/check_status` — show a comprehensive operational status: what is being
  /// processed right now, or, if processing has stopped, the recent runs'
  /// outcomes and any errors (budget overruns included).
  checkStatus,

  /// `/todos_list` — show the working todo list of the active session (the
  /// scratch plan the brain keeps for itself, surviving across the prompts of
  /// the conversation).
  todosList,

  /// `/todos_clear` — empty the working todo list of the active session.
  todosClear,

  /// `/check_usage` — show the live budget of the prompt being processed right
  /// now: time since it started and its accumulating effort (LLM calls, tool
  /// calls, estimated tokens).
  checkUsage,

  /// `/stop_prompt` — interrupt the prompt being processed right now,
  /// cooperatively abandoning the in-flight foreground run. A no-op (with a
  /// "nothing is being processed" reply) when the brain is idle.
  stopPrompt,

  /// `/tools_list` — list the engine tools the brain can call (name, group,
  /// and a one-line description per tool).
  toolsList,

  /// `/tool_inspect <name>` — show one tool's full detail (group, description,
  /// and input schema).
  toolInspect,

  /// `/mcp_list` — list the configured external MCP servers (id, transport,
  /// description).
  mcpList,

  /// `/mcp_inspect <server>` — list the tools an MCP server advertises; with a
  /// second argument `/mcp_inspect <server> <tool>` show one tool's detail.
  mcpInspect,

  /// `/show_models` — list the configured substrate providers and their
  /// models, each with the `<providerId>:<model>` id used by `/switch_model`.
  showModels,

  /// `/show_prompts` — list the cognition prompt types, each with the model
  /// route and role it currently resolves to.
  showPrompts,

  /// `/switch_model <prompt-id> <model-id>` — override the model a cognition
  /// prompt type uses, for this running process (not persisted to config).
  switchModel,

  /// `/cli_server_port <port>` — change the VS Code bridge / agent-SDK
  /// CLI-server port the running brain connects to: persist it to the run
  /// config and disconnect/reconnect the live agent-SDK providers.
  cliServerPort,

  /// `/trace_memory` — toggle per-user memory-recall tracing. While on, each
  /// memory lookup the brain runs for this user surfaces what every retrieval
  /// search found as its own out-of-band message. The same command turns it
  /// back off; the reply states the resulting state.
  traceMemory,
}

/// The command word a user types for each [TelegramCommandKind], without the
/// leading slash. The parser matches against these case-insensitively; the
/// help text renders them with the slash.
const Map<TelegramCommandKind, String> telegramCommandWords =
    <TelegramCommandKind, String>{
  TelegramCommandKind.createSession: 'create_session',
  TelegramCommandKind.listSessions: 'list_sessions',
  TelegramCommandKind.pickSession: 'pick_session',
  TelegramCommandKind.renameSession: 'rename_session',
  TelegramCommandKind.help: 'help',
  TelegramCommandKind.observatoryShowPrompts: 'observatory_show_prompts',
  TelegramCommandKind.observatoryAnalyzePrompt: 'observatory_analyze_prompt',
  TelegramCommandKind.showLogs: 'show_logs',
  TelegramCommandKind.memoryStatus: 'memory_status',
  TelegramCommandKind.checkStatus: 'check_status',
  TelegramCommandKind.todosList: 'todos_list',
  TelegramCommandKind.todosClear: 'todos_clear',
  TelegramCommandKind.checkUsage: 'check_usage',
  TelegramCommandKind.stopPrompt: 'stop_prompt',
  TelegramCommandKind.toolsList: 'tools_list',
  TelegramCommandKind.toolInspect: 'tool_inspect',
  TelegramCommandKind.mcpList: 'mcp_list',
  TelegramCommandKind.mcpInspect: 'mcp_inspect',
  TelegramCommandKind.showModels: 'show_models',
  TelegramCommandKind.showPrompts: 'show_prompts',
  TelegramCommandKind.switchModel: 'switch_model',
  TelegramCommandKind.cliServerPort: 'cli_server_port',
  TelegramCommandKind.traceMemory: 'trace_memory',
};

/// The reverse of [telegramCommandWords]: the command word (lower-cased,
/// slash-stripped) → its [TelegramCommandKind]. Built once.
final Map<String, TelegramCommandKind> _wordToKind =
    <String, TelegramCommandKind>{
  for (final entry in telegramCommandWords.entries) entry.value: entry.key,
};

/// A parsed command: its [kind] and the trailing [argument] (a session name,
/// a three-digit index, a prompt index; `''` when the command takes none or
/// the user supplied none).
final class TelegramCommand {
  /// Which command this is.
  final TelegramCommandKind kind;

  /// The trailing argument text (trimmed), or `''` when absent.
  final String argument;

  /// Builds a parsed command.
  const TelegramCommand({required this.kind, required this.argument});
}

/// Parses one Telegram message body into a [TelegramCommand], or returns
/// `null` when the body is not a known slash-command (an ordinary prompt, or
/// an unrecognised `/word`). Pure — no I/O, no state.
///
/// `/cmd@botname` is normalised to `/cmd` (Telegram appends the bot username to
/// commands in group chats). The match is case-insensitive on the command word.
TelegramCommand? parseTelegramCommand(String text) {
  final String trimmed = text.trim();
  if (!trimmed.startsWith('/')) return null;

  // Split the leading command word from the rest (the argument).
  final int firstSpace = trimmed.indexOf(RegExp(r'\s'));
  final String word =
      (firstSpace == -1 ? trimmed : trimmed.substring(0, firstSpace));
  final String argument =
      (firstSpace == -1 ? '' : trimmed.substring(firstSpace + 1)).trim();

  // Strip a `@botname` suffix and the leading slash, lower-case for matching.
  String command = word.substring(1);
  final int at = command.indexOf('@');
  if (at != -1) command = command.substring(0, at);
  command = command.toLowerCase();

  final TelegramCommandKind? kind = _wordToKind[command];
  if (kind == null) return null;
  return TelegramCommand(kind: kind, argument: argument);
}

/// The `/help` reply: every command with a one-line description, grouped by
/// family. A pure function so the wording is one named, unit-testable place —
/// and so [telegramHelpText] can be asserted to mention every
/// [TelegramCommandKind] (no command can ship undiscoverable).
String telegramHelpText() {
  final StringBuffer buffer = StringBuffer('Available commands:')
    ..write('\n\nSessions:')
    ..write('\n/create_session <name> — start a new session and switch to it')
    ..write('\n/list_sessions — list your sessions (000-numbered)')
    ..write('\n/pick_session <nnn> — switch to the session at that index')
    ..write('\n/rename_session <new name> — rename the active session')
    ..write('\n\nInspection:')
    ..write('\n/observatory_show_prompts — list recent prompts with an index')
    ..write('\n/observatory_analyze_prompt <index> — full detail of one prompt')
    ..write('\n/show_logs — tail of each important log file')
    ..write('\n/memory_status — overview of the brain memory')
    ..write('\n/check_status — what the brain is doing now + recent runs/errors')
    ..write('\n/todos_list — show the working todo list of the active session')
    ..write('\n/todos_clear — empty the working todo list of the active session')
    ..write('\n/check_usage — live budget of the prompt being processed now')
    ..write('\n/stop_prompt — interrupt the prompt being processed now')
    ..write('\n/tools_list — list the engine tools the brain can call')
    ..write('\n/tool_inspect <name> — full detail of one engine tool')
    ..write('\n/mcp_list — list the configured external MCP servers')
    ..write('\n/mcp_inspect <server> [tool] — list an MCP server tools (or one)')
    ..write('\n\nConfiguration:')
    ..write('\n/show_models — list the configured providers and models')
    ..write('\n/show_prompts — list the cognition prompt types')
    ..write('\n/switch_model <prompt-id> <model-id> — set a prompt type model')
    ..write('\n/cli_server_port <port> — change the VS Code bridge / agent-SDK '
        'port (persisted; reconnects the live brain)')
    ..write('\n/trace_memory — toggle messages tracing what each memory search '
        'finds (same command turns it off)')
    ..write('\n\n/help — show this list');
  return buffer.toString();
}
