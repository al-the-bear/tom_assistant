// PT-2.2 — the configuration-in-effect view (§ 4.3). For the whole turn it shows
// the distinct (provider, model, profile, role) tuples that *actually ran*
// (reconstructed server-side from the turn's `llm/` dumps, § 3.4) plus the
// memory profile. Each tuple is a read-only chip: tapping it reveals the full
// tuple (the config that ran), and there is no write affordance anywhere — the
// "config reference" deep-link is read-only by construction (OBS-1..OBS-5).
//
// The view renders *what ran*, never *what was configured*: when two calls in
// the same turn used different providers (a free-tier rotation mid-turn), both
// chips appear.

import 'package:flutter/material.dart';

import '../model/prompt_trace.dart';

/// Renders the § 4.3 configuration-in-effect for [configuration].
class ConfigurationInEffectView extends StatelessWidget {
  final Configuration configuration;

  const ConfigurationInEffectView({super.key, required this.configuration});

  @override
  Widget build(BuildContext context) {
    if (configuration.entries.isEmpty) {
      return const Text('(no configuration recorded for this turn)');
    }
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (configuration.memoryProfile != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('memory profile: ${configuration.memoryProfile}',
                style: theme.textTheme.bodySmall),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final entry in configuration.entries) ConfigChip(entry: entry),
          ],
        ),
      ],
    );
  }
}

/// A read-only chip for one (provider, model, profile, role) tuple. Tapping it
/// opens a read-only detail of the config that ran — the deep-link target is
/// the tuple itself (§ 4.3); there is no write affordance.
class ConfigChip extends StatelessWidget {
  final ConfigEntry entry;

  const ConfigChip({super.key, required this.entry});

  /// `role · provider/model[ · profile]` — the compact one-line label.
  String get label => <String>[
        entry.role,
        '${entry.provider}/${entry.model}',
        if (entry.profile != null) entry.profile!,
      ].join(' · ');

  @override
  Widget build(BuildContext context) => ActionChip(
        avatar: const Icon(Icons.tune, size: 16),
        label: Text(label),
        onPressed: () => _showDetail(context),
      );

  void _showDetail(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(entry.role),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _kv('provider', entry.provider),
            _kv('model', entry.model),
            _kv('profile', entry.profile ?? '—'),
            _kv('role', entry.role),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _kv(String key, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text.rich(TextSpan(children: <InlineSpan>[
          TextSpan(text: '$key: ', style: const TextStyle(fontWeight: FontWeight.bold)),
          TextSpan(text: value),
        ])),
      );
}
