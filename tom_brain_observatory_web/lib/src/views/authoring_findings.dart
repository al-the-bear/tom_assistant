// The rejected-save banner shared by the two source-authoring editors (§ 6.3,
// AUTH-3): a procedure save rejected by the brain's `ProcedureValidationChain`,
// and a prompt save rejected for blank prose. Each finding is a `code` +
// `message` (+ optional `field`), shown above the kept buffer so the operator
// can fix the source and re-save — a rejected edit is never silently dropped.

import 'package:flutter/material.dart';

import '../model/authoring.dart';

/// The error-tinted findings list for the last rejected save. Render only when
/// [findings] is non-empty.
class AuthoringFindingsBanner extends StatelessWidget {
  final List<AuthoringFinding> findings;

  const AuthoringFindingsBanner({super.key, required this.findings});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'rejected — not saved',
            style: TextStyle(
                color: scheme.onErrorContainer, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          for (final finding in findings)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '${finding.code}: ${finding.message}'
                '${finding.field != null ? ' (${finding.field})' : ''}',
                style: TextStyle(color: scheme.onErrorContainer, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}
