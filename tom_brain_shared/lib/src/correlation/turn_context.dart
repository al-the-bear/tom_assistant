// TurnContext — the per-turn correlation tuple (logging-spec §3).
//
// Carries the [TurnId] minted at the access edge plus the per-turn `callSeq`
// counter. `turnId` + `callSeq` together uniquely name any LLM call across the
// whole system: the turn fixes *which* request is being served, the callSeq
// fixes *which* LLM call within it.
//
// One TurnContext is created per turn at `ProcedureEngine.invoke` and shared
// across every (possibly nested) run of that turn, so the one counter spans
// sub-procedures — the nth LLM call of the turn gets seq n regardless of which
// procedure issued it.

import '../ids/turn_id.dart';

/// Mutable per-turn correlation state shared across every run of one turn.
final class TurnContext {
  /// The id minted at the access edge for this turn.
  final TurnId turnId;

  int _callSeq = 0;

  TurnContext(this.turnId);

  /// Returns the next LLM call sequence number for this turn.
  ///
  /// Starts at 1 and increments by one on each call. Only consumed by actual
  /// LLM completions — embeddings and other substrate operations do not advance
  /// it — so the returned value is the call's ordinal within the turn.
  int nextCallSeq() => ++_callSeq;
}
