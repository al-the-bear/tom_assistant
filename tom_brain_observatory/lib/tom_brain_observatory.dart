/// Tom Brain Observatory — the read-only observability web app over a running
/// Tom Brain prototype (`prompt_tracing.md`).
///
/// This library exposes two read surfaces:
///
/// - **Module 1 — Prompt Tracing** (`prompt_tracing_plan.md` PT-1.*): the
///   [PromptTrace] projection (§ 3.2), the recursive [ProcedureRun] run-tree
///   (§ 3.6), and the parsers that re-assemble them from the trail files the
///   brain already wrote — [promptTraceFor] for a single turn and [promptList]
///   for the §4.1 entry view.
/// - **Module 2 — Memory Monitoring** (PT-5.*): the [MemoryReadClient] facade
///   over the brain's memory MCP server (the nine read tools; § 5.1), its
///   read-only view models ([MemoryNode], [MemoryEdge], [RecallResult], …), and
///   the [TypeBrowser] that composes browse-by-type from those reads (§ 5.2).
///
/// The Flutter-web front-end and the shelf endpoints that serve this model land
/// in later phases.
///
/// Read-only is load-bearing (OBS-1…OBS-5, `prompt_tracing.md` § 6.2): no code
/// in this package ever writes a trail file, the memory store, or any brain
/// control surface. The memory door is the nine-read MCP client — never a DB
/// handle (OBS-3), never the write tool (OBS-2).
library;

export 'src/api/catalogue_read_api.dart';
export 'src/api/memory_read_api.dart';
export 'src/api/trail_read_api.dart';
export 'src/launch/observatory_server.dart'
    show ObservatoryLog, ObservatoryOptions, ObservatoryServer, startObservatoryServer;
export 'src/memory/http_mcp_read_connection.dart';
export 'src/memory/mcp_read_connection.dart';
export 'src/memory/memory_nodes.dart';
export 'src/memory/memory_read_client.dart';
export 'src/memory/type_browser.dart';
export 'src/model/prompt_trace.dart';
export 'src/model/run_tree.dart';
export 'src/parse/configuration_builder.dart';
export 'src/parse/inbound_parser.dart';
export 'src/parse/prompt_list_builder.dart';
export 'src/parse/prompt_trace_parser.dart';
export 'src/parse/reply_parser.dart';
export 'src/parse/run_tree_parser.dart';
export 'src/parse/run_tree_walk.dart';
export 'src/parse/trail_host.dart';

/// The observatory package version, mirroring `pubspec.yaml`'s `version`.
const String observatoryVersion = '0.0.1';
