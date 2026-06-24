// The read-only authoring banner (plan step 9). When the observatory was
// launched `--observatory-readonly`, `GET /api/meta` reports
// `configWritable: false` and the three authoring editors (procedure script,
// template, config) grey their Save control and show this strip, so the
// operator sees the surface is closed up front rather than discovering it from a
// `409 config_is_immutable` on save.

import 'package:flutter/material.dart';

/// A tinted strip stating the authoring surface is read-only — shown above an
/// editor whose Save is disabled because the host is `--observatory-readonly`.
class ReadOnlyNotice extends StatelessWidget {
  const ReadOnlyNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.lock_outline, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Read-only: this observatory was launched --observatory-readonly, '
              'so config cannot be edited here.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
