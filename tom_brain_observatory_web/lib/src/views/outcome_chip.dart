// A small status chip shared by the prompt list (§ 4.1) and the reply section
// (§ 4.2). Maps the turn's terminal status onto a colour + label: `accepted` →
// OK (green), an error status → the status text (red), and a `null` status →
// "in-flight" (an in-flight turn has no completed run-tree, § 4.1).

import 'package:flutter/material.dart';

/// Renders [status] as a coloured chip. `null` → an "in-flight" chip.
class OutcomeChip extends StatelessWidget {
  final String? status;
  const OutcomeChip({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (String label, Color bg, Color fg) = switch (status) {
      null => ('in-flight', scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
      'accepted' => ('OK', Colors.green.shade100, Colors.green.shade900),
      _ => (status!, scheme.errorContainer, scheme.onErrorContainer),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg),
      ),
    );
  }
}
