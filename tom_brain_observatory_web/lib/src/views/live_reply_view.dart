// PT-4.2 — the streaming Reply view (§ 3.5, § 4.8). Driven by the per-turn SSE
// live-tail ([TraceApiClient.tailTurn]), it replays the `💬 assistant` answer
// blocks as they arrive, surfaces the current non-assistant step (thinking, a
// memory/tool act) as a running status, and on the `✅ DONE` banner stops the
// progress indicator and shows the outcome. Read-only: it only consumes the
// stream the backend produces from a file watch (OBS-5).

import 'dart:async';

import 'package:flutter/material.dart';

import '../model/live_step.dart';

/// Replays the live-tail [steps] of one in-flight turn as the streamed Reply.
class LiveReplyView extends StatefulWidget {
  final Stream<LiveStep> steps;

  const LiveReplyView({super.key, required this.steps});

  @override
  State<LiveReplyView> createState() => _LiveReplyViewState();
}

class _LiveReplyViewState extends State<LiveReplyView> {
  StreamSubscription<LiveStep>? _sub;

  /// The assistant answer blocks, in arrival order (§ 3.5 may stream several).
  final List<String> _assistant = <String>[];

  /// The heading of the latest non-assistant step — shown as a running status.
  String? _status;

  /// The `✅ DONE` banner once the turn finishes; `null` while in flight.
  String? _doneBanner;

  @override
  void initState() {
    super.initState();
    _sub = widget.steps.listen(_onStep);
  }

  void _onStep(LiveStep step) {
    setState(() {
      if (step.isDone) {
        _doneBanner = step.heading;
        _status = null;
      } else if (step.isAssistant) {
        if (step.body.isNotEmpty) _assistant.add(step.body);
      } else {
        _status = step.heading;
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running = _doneBanner == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (running && _status != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: <Widget>[
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_status!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall),
                ),
              ],
            ),
          ),
        if (_assistant.isNotEmpty)
          SelectableText(_assistant.join('\n\n'))
        else if (running)
          Text('(waiting for the answer…)', style: theme.textTheme.bodySmall),
        if (_doneBanner != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              children: <Widget>[
                Icon(Icons.check_circle, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_doneBanner!, style: theme.textTheme.bodySmall),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
