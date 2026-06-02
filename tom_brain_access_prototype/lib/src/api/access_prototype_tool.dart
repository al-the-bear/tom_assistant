// The `tom_build_base` tool definition for the access-prototype process.
//
// E.9 lands the executable *entry point* for the running process. Per the
// workspace rule, every CLI tool is built on `tom_build_base`'s
// `ToolDefinition` — the shared arg parser, `--version` / `--help`
// handling, and the `ToolRunner` dispatch loop. This file declares the
// tool shape; `bin/tom_brain_access_prototype.dart` wires it to a
// `ToolRunner` and `access_serve_executor.dart` supplies the run logic.
//
// Scope boundary (Plan E.9 vs E.41–E.45): E.9 is the *skeleton* entry
// point inside the "E.2 — Project skeleton" subphase — the analogue of
// A.7 / B.6 / C.6 / E.6, carried one step further to the executable. The
// process actually *boots* (composing substrate + memory isolate + engine
// + dispatcher + adapters, opening the HTTP/SSE listener, wiring
// `/healthz`, loading the full YAML config) only at E.41 – E.45, once the
// `boot/` module is populated. At E.9 the `serve` command is a faithful
// no-op stub: it parses `--config`, reports the not-yet-wired status, and
// exits cleanly. `--version` and `--help` are fully functional now because
// the framework provides them.

import 'package:tom_build_base/tom_build_base_v2.dart';

/// Semantic version of the access-prototype process.
///
/// Kept in lockstep with `pubspec.yaml`'s `version:` field by hand (the
/// project has no versioner-generated file yet — see Q-E.9.2). Surfaced
/// through `--version` via [accessPrototypeTool]'s `versionString`.
const String accessPrototypeVersion = '0.0.1';

/// Full `--version` banner for the process.
const String accessPrototypeVersionString =
    'Tom Brain Access Prototype v$accessPrototypeVersion';

/// Name of the default (and, at E.9, only) command — the run loop.
const String accessServeCommandName = 'serve';

/// The OpenAI HTTP/SSE port a `--config`-less `serve` invocation binds (E.45).
///
/// Only the built-in permissive default ([AccessServeExecutor]'s no-config
/// path) uses it; a real `--config` file always carries an explicit
/// `access.openai.port`. `8080` is the conventional local OpenAI-compatible
/// listener port and collides with nothing else this process opens.
const int defaultAccessOpenAiPort = 8080;

/// Name of the global `--config` option carrying the process config path.
const String accessConfigOptionName = 'config';

/// The `--config` global option.
///
/// `--config` / `-c` is **framework-reserved** in `tom_build_base`: the
/// parser special-cases it and surfaces the value on `CliArgs.configPath`
/// (not the generic `extraOptions` map). We re-declare it here purely so it
/// appears in `--help` with our own description and the `-c` abbreviation;
/// the executor reads the value from `CliArgs.configPath`. See Q-E.9.3.
///
/// Declared at E.9 so the entry-point shape is forward-compatible with the
/// full config loader (E.44). At E.9 the executor only echoes the resolved
/// path; it does not yet parse the YAML (that is E.44's job).
const OptionDefinition accessConfigOption = OptionDefinition.option(
  name: accessConfigOptionName,
  abbr: 'c',
  description: 'Path to the access-process YAML config (loaded at E.44).',
  valueName: 'path',
);

/// The `serve` command — the long-running access process.
///
/// `requiresTraversal: false` is the load-bearing flag: it routes the
/// `ToolRunner` to [CommandExecutor.executeWithoutTraversal] (a single
/// run in the current process) instead of the project-by-project
/// traversal used by build tools. A server does not traverse projects, so
/// project/git traversal support is disabled too.
const CommandDefinition accessServeCommand = CommandDefinition(
  name: accessServeCommandName,
  description:
      'Run the Tom Brain access process (OpenAI HTTP/SSE + Telegram). '
      'Boot wiring lands at Plan E.41–E.45.',
  requiresTraversal: false,
  supportsProjectTraversal: false,
  examples: [
    // Bare invocation routes here via the tool's defaultCommand; the
    // explicit `:serve` form (buildkit `:`-prefix convention) is equivalent.
    'tom_brain_access_prototype --config=access.yaml',
    'tom_brain_access_prototype :serve --config=access.yaml',
  ],
);

/// The access-prototype tool definition.
///
/// `multiCommand` mode with a single non-traversal default command
/// (`serve`) is the idiomatic `tom_build_base` shape for a process whose
/// executor runs once rather than per-project: bare invocation routes to
/// the default command, which — being non-traversal — dispatches to
/// `executeWithoutTraversal`.
final ToolDefinition accessPrototypeTool = ToolDefinition(
  name: 'tom_brain_access_prototype',
  description:
      'Tom Brain access prototype — the inbound edge and the actual '
      'running process. Accepts OpenAI HTTP/SSE and Telegram inbound '
      'work, produces the Access object, and streams answers back.',
  version: accessPrototypeVersion,
  versionString: accessPrototypeVersionString,
  mode: ToolMode.multiCommand,
  defaultCommand: accessServeCommandName,
  globalOptions: const [accessConfigOption],
  commands: const [accessServeCommand],
  helpFooter: '''
Running the process:
  tom_brain_access_prototype                 # serve with built-in defaults
  tom_brain_access_prototype --config=PATH   # serve with a YAML config

The access layer (OpenAI HTTP/SSE + Telegram edges, /healthz, graceful
shutdown) is wired (Plan E.41–E.45). The standalone binary cannot boot the
cognition itself — substrate + memory are out of this package's dependency
surface — so a bare `serve` reports that no brain is wired and exits cleanly;
a higher assembly injects a BrainProvisioner to actually serve.''',
);
