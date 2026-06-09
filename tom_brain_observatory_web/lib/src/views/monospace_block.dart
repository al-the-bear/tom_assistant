// The scrollable, copyable monospace block shared by the trace-detail JSON
// dumps (raw envelope, § 4.2) and the LLM-call wire body (§ 4.5) — extracted so
// both render identically: a full-width rounded surface holding selectable
// monospace text, optionally height-capped with its own scroll view for long
// bodies. Read-only by construction (SelectableText copies, never edits).

import 'package:flutter/material.dart';

/// A monospace text block. [maxHeight] caps the height and wraps the content in
/// a scroll view (for long wire bodies); `null` lets it size to its content.
class MonospaceBlock extends StatelessWidget {
  final String text;
  final double? maxHeight;

  const MonospaceBlock({super.key, required this.text, this.maxHeight});

  @override
  Widget build(BuildContext context) {
    final body = SelectableText(
      text,
      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
    );
    return Container(
      width: double.infinity,
      constraints: maxHeight == null ? null : BoxConstraints(maxHeight: maxHeight!),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: maxHeight == null ? body : SingleChildScrollView(child: body),
    );
  }
}
