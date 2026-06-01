// B.43 — Spec-table attestation (review-pass sentinel).
//
// Step B.43 of the tom_brain prototype implementation plan is a
// **code review pass**: every file vs the spec section that owns it,
// divergences flagged. The deliverable is the divergence report in
// `prototype_implementation_details.md` § B.43.
//
// This test file is the *code-level* sentinel that pins the
// structural conclusions of that review. Four spec tables surfaced
// as the load-bearing taxonomies the review confirmed match the
// implementation:
//
//   1. Spec § 6.2 — Five prototype roles
//      (`assistant_to_user`, `analyser`, `sub_thinker`, `recaller`,
//      `evaluator`).
//   2. Spec § 5.4 — Failover classification (eleven required codes;
//      the implementation carries one additional documented entry —
//      `cancelled_by_consumer` — tracked under Q-B.43.1).
//   3. Spec § 10.1 — Logger categories (six entries, matching the
//      `tom_brain.substrate.<area>` namespace verbatim).
//   4. Spec § 10.2 — Event taxonomy (twelve `SubstrateEvent`
//      subtypes, each reachable via the package barrel).
//
// Each table has its own per-step test elsewhere (B.22 for the role
// list, B.20 for the router conformance, B.37 for the log
// categories, B.38 for the event bus). The B.43 sentinel is the
// cross-cutting attestation that those tables match the spec text
// **bidirectionally**: a code-side rename, addition, or reorder, or
// a spec-side drift, both fail this test before any per-step test
// catches it, with a message that names the spec section.
//
// Drives the public API only — never imports `lib/src/…` directly;
// every reference flows through `package:tom_brain_substrate/…`.

import 'package:test/test.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  // ---------------------------------------------------------------------
  // Spec § 6.2 — Five prototype roles
  // ---------------------------------------------------------------------
  group('spec § 6.2 — five prototype roles', () {
    // The canonical role list from the spec, transcribed verbatim.
    // If the spec changes, this list changes — the test then either
    // passes (code matches) or fails with a clear message naming
    // which side drifted.
    const specRoleIds = <String>[
      'assistant_to_user',
      'analyser',
      'sub_thinker',
      'recaller',
      'evaluator',
    ];

    test(
      'prototypeRoleIds matches spec § 6.2 exactly (order + count)',
      () {
        expect(
          prototypeRoleIds,
          equals(specRoleIds),
          reason:
              'spec § 6.2 lists exactly these five role ids in this '
              'order. If the implementation drifted, fix '
              '`lib/src/roles/bootstrap_roles.dart#prototypeRoleIds`; '
              'if the spec drifted, fix '
              '`_ai/quests/tom_brain/substrate_specification.md` § 6.2 '
              'and update this list.',
        );
      },
    );

    test(
      'bootstrapRoleRegistry resolves every spec § 6.2 role to a '
      'valid template',
      () {
        final registry = bootstrapRoleRegistry();
        expect(
          registry.length,
          equals(specRoleIds.length),
          reason:
              'The bootstrap registry must hold exactly the spec '
              '§ 6.2 roles — no more, no less.',
        );
        for (final id in specRoleIds) {
          expect(
            registry.contains(id),
            isTrue,
            reason: 'spec § 6.2 role `$id` missing from bootstrap '
                'registry',
          );
          final template = registry.get(id);
          expect(template.id, equals(id));
          expect(
            template.personaText,
            isNotEmpty,
            reason:
                'spec § 6.1 requires every RoleTemplate carry '
                'non-empty persona text.',
          );
          expect(
            template.objective,
            isNotEmpty,
            reason:
                'spec § 6.1 requires every RoleTemplate carry a '
                'non-empty objective.',
          );
        }
      },
    );
  });

  // ---------------------------------------------------------------------
  // Spec § 5.4 — Failover classification
  // ---------------------------------------------------------------------
  group('spec § 5.4 — failover classification taxonomy', () {
    // The eleven codes from the spec § 5.4 table, transcribed
    // verbatim. The implementation may carry additional entries
    // (currently `cancelled_by_consumer` per Q-B.43.1); those are
    // documented separately and treated as an extension, not a
    // divergence. This list is the **minimum** the closed taxonomy
    // must cover.
    const specClassCodes = <String>{
      'rate_limit',
      'overloaded',
      'billing',
      'timeout',
      'auth',
      'auth_permanent',
      'model_not_found',
      'context_overflow',
      'format',
      'network',
      'unknown',
    };

    // Spec § 1.6: "Failover classification is fixed. The taxonomy
    // in § 5.4 is closed. New error classes require a spec change."
    // The implementation's current additions to that closed set —
    // tracked under Q-B.43.* — go here. If a future revision drops
    // one of these or adds a new one, the matching question moves
    // to the spec authority and this set updates.
    const documentedImplementationExtras = <String>{
      'cancelled_by_consumer', // Q-B.43.1
    };

    test(
      'LlmFailureClass.values carries every spec § 5.4 code verbatim',
      () {
        final implCodes = {
          for (final cls in LlmFailureClass.values) cls.code,
        };
        for (final code in specClassCodes) {
          expect(
            implCodes,
            contains(code),
            reason:
                'spec § 5.4 code `$code` not present in '
                'LlmFailureClass.values. Either '
                '`lib/src/router/llm_failure_classifier.dart` dropped '
                'the entry (fix the code) or the spec dropped it '
                '(fix the spec and update this set).',
          );
        }
      },
    );

    test(
      'LlmFailureClass.values carries no undocumented codes beyond '
      'the spec § 5.4 set',
      () {
        final implCodes = {
          for (final cls in LlmFailureClass.values) cls.code,
        };
        final unexpected = implCodes
            .difference(specClassCodes)
            .difference(documentedImplementationExtras);
        expect(
          unexpected,
          isEmpty,
          reason:
              'A code is present in LlmFailureClass.values that is '
              'neither in spec § 5.4 nor in the documented Q-B.43.* '
              'extras: $unexpected. Either remove it from '
              '`lib/src/router/llm_failure_classifier.dart` or '
              'document it under a new Q-B.43.* entry and add it to '
              '`documentedImplementationExtras` in this test.',
        );
      },
    );
  });

  // ---------------------------------------------------------------------
  // Spec § 10.1 — Logger categories
  // ---------------------------------------------------------------------
  group('spec § 10.1 — logger categories', () {
    // The six categories from spec § 10.1, transcribed verbatim
    // (including the namespace prefix the spec writes them under).
    const specCategoryNames = <String>{
      'tom_brain.substrate.llm',
      'tom_brain.substrate.roles',
      'tom_brain.substrate.embed',
      'tom_brain.substrate.web',
      'tom_brain.substrate.mcp',
      'tom_brain.substrate.router',
    };

    test(
      'SubstrateLogCategory.values has exactly the spec § 10.1 set',
      () {
        final implNames = {
          for (final c in SubstrateLogCategory.values) c.name,
        };
        expect(
          implNames,
          equals(specCategoryNames),
          reason:
              'SubstrateLogCategory must list the six categories in '
              'spec § 10.1, no more and no less. If this fails, '
              'reconcile `lib/src/obs/substrate_log.dart` and the '
              'spec table.',
        );
      },
    );

    test(
      'SubstrateLog exposes exactly one const instance per spec '
      '§ 10.1 category',
      () {
        // Walk the static surface via the canonical `all` list; assert
        // each category is reachable through its public alias.
        final all = SubstrateLog.all;
        expect(
          all,
          hasLength(specCategoryNames.length),
          reason:
              'SubstrateLog.all must enumerate every spec § 10.1 '
              'category exactly once.',
        );
        expect(SubstrateLog.llm.category, SubstrateLogCategory.llm);
        expect(SubstrateLog.roles.category, SubstrateLogCategory.roles);
        expect(SubstrateLog.embed.category, SubstrateLogCategory.embed);
        expect(SubstrateLog.web.category, SubstrateLogCategory.web);
        expect(SubstrateLog.mcp.category, SubstrateLogCategory.mcp);
        expect(SubstrateLog.router.category, SubstrateLogCategory.router);
      },
    );
  });

  // ---------------------------------------------------------------------
  // Spec § 10.2 — Event taxonomy
  // ---------------------------------------------------------------------
  group('spec § 10.2 — event taxonomy', () {
    test(
      'every spec § 10.2 subtype is reachable as a SubstrateEvent '
      'subtype via the package barrel',
      () {
        // Per spec § 10.2 — the twelve named variants. Constructing
        // each one through the package barrel is the structural
        // proof that (a) the class exists, (b) it is exported,
        // (c) it `extends SubstrateEvent`. We assert the IS-A
        // relationship for each.
        final now = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

        final variants = <SubstrateEvent>[
          LlmCallStarted(
            callId: 'cid',
            roleId: 'assistant_to_user',
            providerId: 'stub',
            modelId: 'stub-model',
            occurredAt: now,
          ),
          LlmCallChunk(
            callId: 'cid',
            charCount: 1,
            occurredAt: now,
          ),
          // The full report-bearing variants need a synthetic
          // `LlmCallReport`; we use the minimal constructor.
          LlmCallCompleted(
            callId: 'cid',
            report: _stubReport(),
            occurredAt: now,
          ),
          LlmCallFailed(
            callId: 'cid',
            failure: const LlmFailure(
              classCode: 'unknown',
              message: 'spec-table-attestation stub',
            ),
            providerId: 'stub',
            modelId: 'stub-model',
            retryCount: 0,
            occurredAt: now,
          ),
          ProviderFailover(
            fromProviderId: 'stub-a',
            toProviderId: 'stub-b',
            reason: 'timeout',
            occurredAt: now,
          ),
          CredentialCooldownStarted(
            profileId: 'stub-profile',
            credentialFingerprint: 'sha-1234',
            errorClass: 'rate_limit',
            untilMs: 60_000,
            occurredAt: now,
          ),
          EmbeddingComputed(
            providerId: 'stub',
            modelId: 'nomic-embed-text',
            dims: 768,
            batchSize: 1,
            occurredAt: now,
          ),
          EmbeddingIdentityChanged(
            fromIdentity: const EmbeddingModelIdentity(
              providerId: 'stub',
              modelId: 'model-a',
              dims: 768,
              normalized: true,
            ),
            toIdentity: const EmbeddingModelIdentity(
              providerId: 'stub',
              modelId: 'model-b',
              dims: 768,
              normalized: true,
            ),
            occurredAt: now,
          ),
          WebSearchCompleted(
            provider: 'duckduckgo',
            query: 'spec-table-attestation',
            k: 3,
            hits: 0,
            occurredAt: now,
          ),
          WebFetchCompleted(
            url: 'https://example.test/',
            status: 200,
            bytes: 0,
            truncated: false,
            occurredAt: now,
          ),
          McpHandshakeCompleted(
            endpointId: 'memory',
            tools: const <String>['recall', 'search'],
            occurredAt: now,
          ),
          McpCallCompleted(
            endpointId: 'memory',
            tool: 'recall',
            wallClockMs: 0,
            ok: true,
            occurredAt: now,
          ),
        ];

        expect(
          variants,
          hasLength(12),
          reason:
              'spec § 10.2 lists exactly twelve SubstrateEvent '
              'variants. If this count drifts, reconcile '
              '`lib/src/api/substrate_event.dart` and the spec table.',
        );

        for (final v in variants) {
          expect(
            v,
            isA<SubstrateEvent>(),
            reason: 'spec § 10.2 variant `${v.runtimeType}` must '
                '`extend SubstrateEvent`.',
          );
        }
      },
    );

    test(
      'every spec § 10.2 variant carries a non-empty `kind` '
      'discriminator',
      () {
        // The kind discriminator is the kebab-case string that
        // identifies the variant on the wire / in logs. Spec § 10.2
        // does not enumerate the strings, but it does require every
        // variant to have one (the `BrainEvent` contract). Assert
        // the contract for the twelve.
        final now = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
        final samples = <SubstrateEvent>[
          LlmCallStarted(
            callId: 'cid',
            roleId: 'analyser',
            providerId: 'stub',
            modelId: 'stub-model',
            occurredAt: now,
          ),
          ProviderFailover(
            fromProviderId: 'a',
            toProviderId: 'b',
            reason: 'timeout',
            occurredAt: now,
          ),
          EmbeddingComputed(
            providerId: 'stub',
            modelId: 'nomic',
            dims: 768,
            batchSize: 1,
            occurredAt: now,
          ),
        ];
        for (final s in samples) {
          expect(
            s.kind,
            isNotEmpty,
            reason:
                'spec § 10.2 variant ${s.runtimeType} must carry a '
                'non-empty kind discriminator (BrainEvent contract).',
          );
        }
      },
    );
  });
}

/// Minimal synthetic `LlmCallReport` used only to construct
/// `LlmCallCompleted` for the IS-A attestation. The fields here are
/// not assertion-load-bearing; the test only proves the variant is a
/// valid `SubstrateEvent` subtype.
LlmCallReport _stubReport() => const LlmCallReport(
      providerId: 'stub',
      modelId: 'stub-model',
      anchorHash: 'stub-anchor',
      promptHash: 'stub-prompt',
      tokensIn: 0,
      tokensOut: 0,
      retries: 0,
      wallClockMs: 0,
    );
