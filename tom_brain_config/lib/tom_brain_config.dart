/// The Tom Brain's configuration model and loaders: brain run, cognition,
/// LLM routes, dream cadence, scripts, tools, trail and profiles.
///
/// tom_brain_run boots from it and re-exports it; tom_brain_observatory reads
/// it to show and validate a configuration with the brain's own parsers.
library;

export 'src/brain_run_config.dart';
export 'src/brain_run_config_loader.dart';
export 'src/cognition_config.dart';
export 'src/cognition_config_loader.dart';
export 'src/cognition_run_config.dart';
export 'src/cognition_run_config_loader.dart';
export 'src/dream_cadence_driver.dart';
export 'src/dream_config.dart';
export 'src/dream_config_loader.dart';
export 'src/dream_throttle.dart';
export 'src/dream_window_schedule.dart';
export 'src/llm_route_config.dart';
export 'src/profile/profile.dart';
export 'src/profile/profile_config_errors.dart';
export 'src/profile/profile_registry.dart';
export 'src/scripts_config.dart';
export 'src/scripts_config_loader.dart';
export 'src/tools_config.dart';
export 'src/tools_config_loader.dart';
export 'src/trail_config.dart';
export 'src/trail_config_loader.dart';
