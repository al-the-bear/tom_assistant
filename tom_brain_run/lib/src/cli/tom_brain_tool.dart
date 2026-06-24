// tom_brain_tool.dart — the `tom_build_base` tool definition for the unified
// `tom_brain` binary (CLI plan step #8; `tom_brain_cli.md` § 5).
//
// One executable with five subcommands — `serve` (the default), `memory-mcp`,
// `observatory`, `init`, `bundle` — replacing the three hand-rolled launchers
// (CLI-Q1). `tom_build_base` provides `--help`, `--version`, and uniform error
// formatting; this file declares the tool shape (commands + the § 5.2 global /
// § 5.3 serve option surface, so the flags appear in `--help`).
//
// ── Why a subcommand normaliser ──
//
// The `tom_build_base` arg parser only treats a `:`-prefixed token as a
// command; a bare leading `serve` is a positional, not a command. The spec
// writes subcommands colon-less (`tom_brain serve`, `tom_brain memory-mcp`), so
// [normalizeSubcommand] rewrites a leading bare subcommand token to its
// `:`-prefixed form before `ToolRunner.run`. A leading flag / `help` / empty
// args / an already-`:`-prefixed token are left untouched (CLP-37).
//
// ── Why the serve flag semantics live in the assembler, not here ──
//
// The serve options are declared here for `--help`, but their *values* are
// parsed by `assembleServeConfig` straight from the raw argv (CLP-38): the
// parser cannot express repeatable options (`--set` / `--write-scope` /
// `--read-scope`), optional-value channel flags (`--openai[=port]`), or the
// `${env:…}`-expand-before-resolve contract. The executor holds the raw argv
// and hands it to the assembler, which is the single authority over flag
// semantics.

import 'package:tom_build_base/tom_build_base_v2.dart';

/// Semantic version of the `tom_brain` binary (kept in lockstep with
/// `pubspec.yaml` by hand). Surfaced through `--version`.
const String tomBrainVersion = '0.0.1';

/// Full `--version` banner.
const String tomBrainVersionString = 'Tom Brain v$tomBrainVersion';

/// The default OpenAI HTTP/SSE port a `serve` invocation binds when neither the
/// config nor a `--openai=PORT` supplies one (§ 5.3; matches the access
/// package's `defaultAccessOpenAiPort`).
const int defaultServeOpenAiPort = 8080;

/// The default Ollama-channel port for a bare `--ollama` (conventional Ollama
/// listener port).
const int defaultServeOllamaPort = 11434;

/// The default Anthropic-channel port for a bare `--anthropic` (a free local
/// port that collides with nothing else this process opens).
const int defaultServeAnthropicPort = 8082;

/// `serve` subcommand name (the default command).
const String tomBrainServeCommandName = 'serve';

/// `memory-mcp` subcommand name.
const String tomBrainMemoryMcpCommandName = 'memory-mcp';

/// `observatory` subcommand name.
const String tomBrainObservatoryCommandName = 'observatory';

/// `init` subcommand name.
const String tomBrainInitCommandName = 'init';

/// `bundle` subcommand name.
const String tomBrainBundleCommandName = 'bundle';

/// The five registered subcommand names — the set [normalizeSubcommand]
/// promotes from a bare leading token to a `:`-prefixed command.
const Set<String> tomBrainCommandNames = {
  tomBrainServeCommandName,
  tomBrainMemoryMcpCommandName,
  tomBrainObservatoryCommandName,
  tomBrainInitCommandName,
  tomBrainBundleCommandName,
};

// ── Global options (§ 5.2) — declared so they show in `--help`. Values are
//    parsed from raw argv by `assembleServeConfig`. ───────────────────────────

const List<OptionDefinition> _globalOptions = [
  OptionDefinition.option(
    name: 'home',
    description: 'Host project root; the brain root defaults to <home>/agent. '
        'Default: CWD.',
    valueName: 'dir',
  ),
  OptionDefinition.option(
    name: 'agent-dir',
    description: 'Relocate the agent root independently of --home.',
    valueName: 'dir',
  ),
  OptionDefinition.option(
    name: 'config',
    abbr: 'c',
    description: 'Load a whole BrainRunConfig from one YAML file (additive to '
        '--home).',
    valueName: 'file',
  ),
  OptionDefinition.option(
    name: 'providers',
    description: 'Relocate the substrate providers aspect.',
    valueName: 'dir',
  ),
  OptionDefinition.option(
    name: 'models',
    description: 'Relocate the substrate models aspect.',
    valueName: 'dir',
  ),
  OptionDefinition.option(
    name: 'profiles',
    description: 'Relocate the session-profiles aspect.',
    valueName: 'dir',
  ),
  OptionDefinition.option(
    name: 'prompts',
    description: 'Relocate the cognition prompts aspect.',
    valueName: 'dir',
  ),
  OptionDefinition.option(
    name: 'scripts',
    description: 'Relocate the procedure scripts aspect.',
    valueName: 'dir',
  ),
  OptionDefinition.option(
    name: 'memory-dir',
    description: 'Relocate the memory store root.',
    valueName: 'dir',
  ),
  OptionDefinition.option(
    name: 'trail-dir',
    description: 'Relocate the prompt-tracing trail root.',
    valueName: 'dir',
  ),
  OptionDefinition.option(
    name: 'history-dir',
    description: 'Relocate the durable conversation-history directory.',
    valueName: 'dir',
  ),
  OptionDefinition.option(
    name: 'edge-dir',
    description: 'Relocate the edge-limiter persisted-state directory.',
    valueName: 'dir',
  ),
  OptionDefinition.option(
    name: 'sqlite-vec',
    description: 'Relocate the sqlite-vec native-library directory.',
    valueName: 'dir',
  ),
  OptionDefinition.multi(
    name: 'set',
    description: 'Scalar override into the resolved config (key=value; '
        'repeatable; value also \${env:…}-expanded).',
    valueName: 'key=value',
  ),
  OptionDefinition.multi(
    name: 'write-scope',
    description: 'File-tool write scope (repeatable).',
    valueName: 'dir',
  ),
  OptionDefinition.multi(
    name: 'read-scope',
    description: 'File-tool read scope (repeatable).',
    valueName: 'dir',
  ),
];

// ── `serve` options (§ 5.3). ────────────────────────────────────────────────

const List<OptionDefinition> _serveOptions = [
  OptionDefinition.option(
    name: 'openai',
    description: 'Enable the OpenAI edge (the mandatory channel); optional '
        '=port overrides the file.',
    valueName: 'port',
  ),
  OptionDefinition.option(
    name: 'ollama',
    description: 'Enable the Ollama channel; optional =port.',
    valueName: 'port',
  ),
  OptionDefinition.option(
    name: 'anthropic',
    description: 'Enable the Anthropic channel; optional =port.',
    valueName: 'port',
  ),
  OptionDefinition.flag(
    name: 'telegram',
    description: 'Enable the Telegram channel (needs --telegram-token).',
  ),
  OptionDefinition.option(
    name: 'telegram-token',
    description: 'Telegram bot token (expands \${env:…}).',
    valueName: 'token',
  ),
  OptionDefinition.option(
    name: 'memory-mcp',
    description: 'Pin/relocate the co-hosted memory MCP server port '
        '(ephemeral loopback by default).',
    valueName: 'port',
  ),
  OptionDefinition.flag(
    name: 'no-memory-mcp',
    description: 'Do NOT co-host the memory MCP server.',
  ),
  OptionDefinition.flag(
    name: 'observatory',
    description: 'Co-host the Observatory (the default).',
  ),
  OptionDefinition.flag(
    name: 'no-observatory',
    description: 'Do NOT co-host the Observatory.',
  ),
  OptionDefinition.option(
    name: 'observatory-port',
    description: 'Move the Observatory loopback bind port.',
    valueName: 'N',
  ),
  OptionDefinition.option(
    name: 'observatory-host',
    description: 'Move the Observatory loopback bind address.',
    valueName: 'ADDR',
  ),
  OptionDefinition.flag(
    name: 'observatory-readonly',
    description: 'Force the Observatory read-only even in directory mode.',
  ),
];

/// The `serve` command — boot the whole cognition and serve every configured
/// access channel plus the memory MCP server and the Observatory in one
/// process (the default command).
final CommandDefinition tomBrainServeCommand = CommandDefinition(
  name: tomBrainServeCommandName,
  description: 'Boot the cognition and serve every channel + the memory MCP '
      'server + the Observatory in one process (CLI-Q1).',
  requiresTraversal: false,
  supportsProjectTraversal: false,
  options: _serveOptions,
  examples: const [
    'tom_brain serve',
    'tom_brain serve --config config/bomber/brain_run.yaml',
    'tom_brain serve --home ~/brains/edge --openai=8081 --no-observatory',
  ],
);

/// The `memory-mcp` command — run the read-mostly memory MCP server standalone.
final CommandDefinition tomBrainMemoryMcpCommand = CommandDefinition(
  name: tomBrainMemoryMcpCommandName,
  description: 'Run the read-mostly memory MCP server standalone (split '
      'deployments).',
  requiresTraversal: false,
  supportsProjectTraversal: false,
  options: const [
    OptionDefinition.option(
      name: 'memory-mcp',
      description: 'Pin the MCP server port (default 8765).',
      valueName: 'port',
    ),
  ],
  examples: const ['tom_brain memory-mcp --config brain.yaml'],
);

/// The `observatory` command — run the Observatory standalone against a trail.
final CommandDefinition tomBrainObservatoryCommand = CommandDefinition(
  name: tomBrainObservatoryCommandName,
  description: 'Run the Observatory standalone against a trail root (split '
      'deployments).',
  requiresTraversal: false,
  supportsProjectTraversal: false,
  options: const [
    OptionDefinition.option(
      name: 'observatory-port',
      description: 'Bind port (default 8787).',
      valueName: 'N',
    ),
    OptionDefinition.option(
      name: 'observatory-host',
      description: 'Bind address (default 127.0.0.1).',
      valueName: 'ADDR',
    ),
    OptionDefinition.flag(
      name: 'observatory-readonly',
      description: 'Force read-only.',
    ),
  ],
  examples: const ['tom_brain observatory --trail-dir agent/trail'],
);

/// The `init` command — scaffold the `--home`/agent convention skeleton.
final CommandDefinition tomBrainInitCommand = CommandDefinition(
  name: tomBrainInitCommandName,
  description: 'Scaffold the <home>/agent convention skeleton (§ 5.4): the '
      'three *.example.yaml aspect templates, an empty mcp/, and (unless '
      '--no-extract) the bundled prompts/scripts extracted onto disk.',
  requiresTraversal: false,
  supportsProjectTraversal: false,
  options: const [
    OptionDefinition.flag(
      name: 'no-extract',
      description: 'Leave the project running off the bundle (do not extract '
          'prompts/scripts).',
    ),
  ],
  examples: const ['tom_brain init ~/brains/research'],
);

/// The `bundle` command — codegen the in-binary prompt/script/native bundle.
final CommandDefinition tomBrainBundleCommand = CommandDefinition(
  name: tomBrainBundleCommandName,
  description: 'Codegen the compiled-in prompt/script/native asset bundle '
      '(§ 4).',
  requiresTraversal: false,
  supportsProjectTraversal: false,
  options: const [
    OptionDefinition.option(
      name: 'out',
      description: 'Output Dart source path for the generated bundle.',
      valueName: 'file',
    ),
    OptionDefinition.option(
      name: 'prompts',
      description: 'Prompts directory to bundle.',
      valueName: 'dir',
    ),
    OptionDefinition.option(
      name: 'scripts',
      description: 'Scripts directory to bundle.',
      valueName: 'dir',
    ),
    OptionDefinition.option(
      name: 'sqlite-vec',
      description: 'sqlite-vec native-binaries root to bundle.',
      valueName: 'dir',
    ),
    OptionDefinition.flag(
      name: 'list',
      description: 'Print a human-readable listing instead of writing source.',
    ),
  ],
  examples: const ['tom_brain bundle --out lib/src/bundle/brain_bundle.g.dart'],
);

/// The `tom_brain` tool definition: `multiCommand` mode with `serve` as the
/// default non-traversal command.
final ToolDefinition tomBrainTool = ToolDefinition(
  name: 'tom_brain',
  description: 'Tom Brain — the cognition engine. Serve the OpenAI/Telegram '
      'edges, the memory MCP server, and the Observatory in one process, or '
      'run any of them standalone.',
  version: tomBrainVersion,
  versionString: tomBrainVersionString,
  mode: ToolMode.multiCommand,
  defaultCommand: tomBrainServeCommandName,
  globalOptions: _globalOptions,
  commands: [
    tomBrainServeCommand,
    tomBrainMemoryMcpCommand,
    tomBrainObservatoryCommand,
    tomBrainInitCommand,
    tomBrainBundleCommand,
  ],
  helpFooter: '''
Subcommands:
  tom_brain serve                  # cognition + memory-MCP + Observatory (default)
  tom_brain memory-mcp --config X  # memory MCP server standalone
  tom_brain observatory --trail-dir X
  tom_brain init <dir>             # scaffold the agent/ convention
  tom_brain bundle --out X         # codegen the compiled-in asset bundle

Every flag value accepts \${env:NAME}; an unset variable is a clear startup
error, not an empty string.''',
);

/// Rewrites a leading bare subcommand token (`serve`, `memory-mcp`, …) to its
/// `:`-prefixed form so the `tom_build_base` parser routes it as a command.
///
/// Leaves empty args, a leading flag (`--help` / `--version` / `-c …`), a bare
/// `help` / `version` positional, an already-`:`-prefixed token, and a
/// non-command leading positional untouched (CLP-37).
List<String> normalizeSubcommand(List<String> args) {
  if (args.isEmpty) return args;
  final first = args.first;
  if (tomBrainCommandNames.contains(first)) {
    return <String>[':$first', ...args.skip(1)];
  }
  return args;
}
