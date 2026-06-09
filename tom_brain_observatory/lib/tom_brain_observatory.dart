/// Tom Brain Observatory — the read-only observability web app over a running
/// Tom Brain prototype (`prompt_tracing.md`).
///
/// This library exposes the Phase 1 Trail Read API model + parser surface
/// (`prompt_tracing_plan.md` PT-1.*): the [PromptTrace] projection (§ 3.2), the
/// recursive [ProcedureRun] run-tree (§ 3.6), and the parsers that re-assemble
/// them from the trail files the brain already wrote — [promptTraceFor] for a
/// single turn and [promptList] for the §4.1 entry view. The Flutter-web
/// front-end and the shelf endpoints that serve this model land in later phases.
///
/// Read-only is load-bearing (OBS-1…OBS-5, `prompt_tracing.md` § 6.2): no code
/// in this package ever writes a trail file, the memory store, or any brain
/// control surface.
library;

export 'src/api/trail_read_api.dart';
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
