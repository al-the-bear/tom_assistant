// Small presentation helpers shared by the views. Pure functions over the §3.9
// DTO fields — no widgets, no state — so they are trivially unit-testable.

/// A compact wall-clock label: `2.1s` for >=1s, `800ms` otherwise. `null` (an
/// in-flight turn) renders as an em dash.
String formatWallClock(int? wallClockMs) {
  if (wallClockMs == null) return '—';
  if (wallClockMs >= 1000) return '${(wallClockMs / 1000).toStringAsFixed(1)}s';
  return '${wallClockMs}ms';
}

/// `HH:MM:SS` of [when] in local time, or an em dash when absent.
String formatClock(DateTime? when) {
  if (when == null) return '—';
  final t = when.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}
