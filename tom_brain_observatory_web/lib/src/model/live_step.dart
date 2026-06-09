// PT-4.2 — one cognitive step streamed from the SSE live-tail (§ 4.8). The
// backend emits one `data:` event per `### `-headed step the brain appends to a
// session live-trail; this is the web-side projection the streaming Reply view
// replays. A pure DTO — no Flutter, no `dart:io` — so it compiles for dart2js.

/// A single live-tail step: its [heading] (e.g. `🧠 thinking (recall_planner)`,
/// `💬 assistant`, or the `✅ DONE` banner), its verbatim [body], and whether it
/// is the terminal [isDone] step.
class LiveStep {
  final String heading;
  final String body;
  final bool isDone;

  const LiveStep({
    required this.heading,
    required this.body,
    required this.isDone,
  });

  factory LiveStep.fromJson(Map<String, dynamic> json) => LiveStep(
        heading: json['heading'] as String? ?? '',
        body: json['body'] as String? ?? '',
        isDone: json['done'] as bool? ?? false,
      );

  /// True for the streamed assistant answer block (§ 3.5) the Reply view shows.
  bool get isAssistant => heading.startsWith('💬 assistant');
}
