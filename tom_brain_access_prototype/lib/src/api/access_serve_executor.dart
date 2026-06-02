// The `serve` command executor for the access-prototype process.
//
// E.9 ships the entry-point skeleton, so this executor is a faithful
// no-op: it resolves the `--config` path, prints the not-yet-wired status
// to stdout, and returns success. The real run loop — boot the substrate,
// the memory isolate, the engine, the dispatcher, and the OpenAI /
// Telegram adapters, open the listener, and block until shutdown — lands
// at Plan E.41–E.45 once the `boot/` module exists.
//
// The `serve` command is declared non-traversal (see
// `access_prototype_tool.dart`), so the `ToolRunner` dispatches to
// [executeWithoutTraversal]. [execute] is part of the [CommandExecutor]
// contract but is unreachable for a non-traversal command; it delegates to
// the same routine and wraps the outcome as an [ItemResult] so the two
// entry points cannot drift.

import 'package:tom_build_base/tom_build_base_v2.dart';

import 'access_prototype_tool.dart';

/// Executor for the `serve` command.
class AccessServeExecutor extends CommandExecutor {
  @override
  Future<ToolResult> executeWithoutTraversal(CliArgs args) async {
    _announce(_resolveConfigPath(args));
    return const ToolResult.success(processedCount: 1);
  }

  // Unreachable for a non-traversal command, but the contract requires it.
  // Delegating keeps the two paths in lockstep if `serve` ever becomes
  // traversal-capable.
  @override
  Future<ItemResult> execute(CommandContext context, CliArgs args) async {
    _announce(_resolveConfigPath(args));
    return ItemResult.success(
      path: context.path,
      name: context.name,
      message: 'access process scaffold ready (boot lands at E.41–E.45)',
    );
  }

  /// Read the `--config` value from the parsed args, if any.
  ///
  /// `--config` is a framework-reserved global option in `tom_build_base`:
  /// the parser special-cases it and surfaces the value on
  /// [CliArgs.configPath] rather than the generic [CliArgs.extraOptions]
  /// map. We declare [accessConfigOption] only so the option appears in
  /// `--help` with our own description and the `-c` abbreviation; the value
  /// itself is read from the canonical field.
  String? _resolveConfigPath(CliArgs args) => args.configPath;

  /// Print the E.9 not-yet-wired status banner to stdout.
  void _announce(String? configPath) {
    print(accessPrototypeVersionString);
    print('Tom Brain access process — entry-point scaffold (Plan E.9).');
    if (configPath != null) {
      print('Config (loaded at E.44): $configPath');
    } else {
      print('Config: none supplied (--config) — built-in defaults.');
    }
    print(
      'Boot is not yet wired: the substrate, the memory isolate, the '
      'engine, the dispatcher, and the OpenAI / Telegram adapters are '
      'composed at Plan E.41–E.45. Nothing is served yet.',
    );
  }
}

/// Build the executor map the `ToolRunner` dispatches against.
///
/// Keyed by command name (`serve`); the bare invocation routes here via the
/// tool's `defaultCommand`.
Map<String, CommandExecutor> createAccessPrototypeExecutors() {
  return {accessServeCommandName: AccessServeExecutor()};
}
