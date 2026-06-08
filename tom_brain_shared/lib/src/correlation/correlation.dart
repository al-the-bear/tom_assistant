// Barrel for the `correlation/` module (logging-spec §3).
//
// Carries the per-turn correlation state threaded from the access edge through
// the procedure engine to each substrate call. The `TurnId` itself lives in the
// `ids/` module (it is a `PrefixedUlidId`); this module adds the mutable
// `TurnContext` that pairs that id with the per-turn `callSeq` counter.

export 'turn_context.dart' show TurnContext;
