// The collapsed one-line row shared by the run-tree's run rows and LLM-call
// rows (§ 4.4) — extracted so both render identically: a leading kind icon, a
// single-line label, an optional [trailing] action, and (when [expandable]) a
// trailing chevron whose direction reflects [expanded]. Tapping invokes [onTap]
// (open detail / toggle children); a `null` [onTap] makes the row inert (a leaf
// primitive/note/error).

import 'package:flutter/material.dart';

/// Visual emphasis for a row. [error] tints the row with the error colour.
enum CollapsedRowEmphasis { normal, error }

/// A single collapsed row in the run tree.
class CollapsedRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool expandable;
  final bool expanded;
  final VoidCallback? onTap;
  final CollapsedRowEmphasis emphasis;

  /// An optional action shown before the expand chevron (e.g. the run row's
  /// "inspect script" button, PT-3.2). `null` for rows with no action.
  final Widget? trailing;

  const CollapsedRow({
    super.key,
    required this.icon,
    required this.label,
    required this.expandable,
    required this.expanded,
    required this.onTap,
    this.emphasis = CollapsedRowEmphasis.normal,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color =
        emphasis == CollapsedRowEmphasis.error ? scheme.error : scheme.onSurface;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color,
                  fontFamily: 'monospace',
                  fontSize: 13,
                ),
              ),
            ),
            ?trailing,
            if (expandable)
              Icon(expanded ? Icons.expand_less : Icons.chevron_right,
                  size: 18, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
