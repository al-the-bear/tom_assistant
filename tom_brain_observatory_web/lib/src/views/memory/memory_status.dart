// The shared "not-ready / unavailable / failed" rendering for every Module-2
// FutureBuilder over the `/api/memory/*` reads (§ 8.4). Returns `null` when the
// snapshot holds data so the caller renders its own content; otherwise returns
// the spinner, the deferred-connector banner ([MemoryUnavailable]), or a generic
// error. Extracted so every memory view treats the three non-data states alike.

import 'package:flutter/material.dart';

import '../../api/memory_api_client.dart';

/// Returns the placeholder widget for a non-data [snapshot], or `null` when the
/// snapshot is done with data (the caller should render its content then).
Widget? memoryStatus(BuildContext context, AsyncSnapshot<Object?> snapshot) {
  if (snapshot.connectionState != ConnectionState.done) {
    return const Center(child: CircularProgressIndicator());
  }
  final error = snapshot.error;
  if (error is MemoryUnavailable) {
    return MemoryUnavailableBanner(message: error.message);
  }
  if (error != null) {
    return Center(child: Text('Memory read failed: $error'));
  }
  return null;
}

/// The deferred-connector state (§ 8.4): the backend answered `503` because the
/// brain's memory connector is not wired. Environmental, never a crash.
class MemoryUnavailableBanner extends StatelessWidget {
  final String message;
  const MemoryUnavailableBanner({super.key, this.message = 'memory unavailable'});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.cloud_off, size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text('Memory unavailable', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            Text(
              'The memory connector is not wired on this brain.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
