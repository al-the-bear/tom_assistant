// Plan Extension-H step #29 — retrieval roles + templates + routes.
//
// Plan-step text (verbatim, prototype_tools_mcp_extension_plan.md):
//   "Extension-H retrieval roles + templates (substrate). Add the six
//    roles (spec substrate § 6.2a): `recall_planner`, `hypothesis_writer`,
//    `query_term_writer`, `category_selector`, `retrieval_reranker`,
//    `profile_selector` — each a `<role>.system.md` template
//    (anchor-carrying) + a `roleRoutes` entry defaulting to a small/cheap
//    route + a structured output schema so the result parses
//    deterministically. Test: each role assembles with the anchor first;
//    each output schema parses a well-formed result and rejects a
//    malformed one (graceful `retrieval.*`, not a crash); the routes
//    resolve. Verify: analyze + role-template + anchor tests green;
//    adding the roles is config-only (no engine change)."
//
// This suite drives the four Test-clause obligations:
//
//   1. Roster + registry — the six retrieval roles exist as RoleTemplate
//      instances with non-null output schemas, in canonical order; they
//      compose with the five bootstrap roles into an 11-role registry
//      without disturbing the bootstrap roster (b22 still sees 5).
//   2. Anchor-first assembly — every retrieval role's assembled prompt
//      body starts with the assistant-dedication anchor and stamps
//      `AnchorRegistry.currentHash`, exactly like every other role (§ 6.3).
//   3. Output schema parse/reject — each role's hand-written parser turns
//      a well-formed JSON object into a typed `RetrievalRoleParsed` and a
//      malformed one into a `RetrievalRoleDegraded` carrying
//      `retrieval.role.output.malformed`; the dispatcher never throws.
//   4. Routes resolve — `defaultRetrievalRoleRoutes` yields a cheap route
//      for each of the six roles, resolvable through `RouterPolicy.routesFor`.

import 'package:test/test.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show AssistantDedicationAnchor;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('retrieval role roster', () {
    test('retrievalRoleIds is the six § 6.2a ids in canonical order', () {
      expect(
        retrievalRoleIds,
        equals(<String>[
          'recall_planner',
          'hypothesis_writer',
          'query_term_writer',
          'category_selector',
          'retrieval_reranker',
          'profile_selector',
        ]),
      );
    });

    test('retrievalRoleTemplates() yields six structured-output roles', () {
      final templates = retrievalRoleTemplates();
      expect(templates, hasLength(6));
      expect(
        templates.map((t) => t.id).toList(),
        equals(retrievalRoleIds),
      );
      for (final t in templates) {
        expect(t.personaText.trim(), isNotEmpty, reason: t.id);
        expect(t.objective.trim(), isNotEmpty, reason: t.id);
        // § 6.2a: "Each role carries a structured output schema so its
        // result parses deterministically."
        expect(t.outputSchema, isNotNull, reason: t.id);
      }
    });

    test('every retrieval role allows llmCall and forbids user-facing / '
        'memory-write actions', () {
      for (final t in retrievalRoleTemplates()) {
        expect(t.allowedActions, contains(AllowedAction.llmCall),
            reason: t.id);
        expect(t.permits(AllowedAction.userFacingAnswer), isFalse,
            reason: t.id);
        expect(t.permits(AllowedAction.memoryWrite), isFalse, reason: t.id);
      }
    });

    test('bootstrapRetrievalRoleRegistry() holds exactly the six roles', () {
      final reg = bootstrapRetrievalRoleRegistry();
      expect(reg.length, equals(6));
      expect(reg.ids.toList(), equals(retrievalRoleIds));
    });

    test('bootstrapRoleRegistryWithRetrieval() composes 6 bootstrap + 6 '
        'retrieval roles without disturbing the bootstrap roster', () {
      final composed = bootstrapRoleRegistryWithRetrieval();
      expect(composed.length, equals(12));
      for (final id in prototypeRoleIds) {
        expect(composed.contains(id), isTrue, reason: id);
      }
      for (final id in retrievalRoleIds) {
        expect(composed.contains(id), isTrue, reason: id);
      }
      // The bootstrap factory holds the six core roles (b22 lock): the
      // prototype five plus the researcher completion role (§ 6.2b).
      expect(bootstrapRoleRegistry().length, equals(6));
    });
  });

  group('retrieval role anchor-first assembly', () {
    test('each retrieval role assembles with the anchor first and stamps '
        'the current hash', () {
      for (final t in retrievalRoleTemplates()) {
        final prompt = t.assemble(inputs: const {'prompt': 'why is the sky '
            'blue?'});
        expect(prompt.combined, startsWith(AssistantDedicationAnchor.text),
            reason: t.id);
        expect(prompt.anchorHash, equals(AnchorRegistry.currentHash),
            reason: t.id);
        expect(prompt.roleId, equals(t.id), reason: t.id);
      }
    });

    test('anchor-first holds for an empty inputs map too', () {
      for (final t in retrievalRoleTemplates()) {
        final prompt = t.assemble();
        expect(prompt.combined, startsWith(AssistantDedicationAnchor.text),
            reason: t.id);
      }
    });
  });

  group('retrieval role output — well-formed parses', () {
    test('recall_planner parses a questions list', () {
      final parsed = parseRetrievalRoleOutput('recall_planner', const {
        'questions': <String>['what colour is air?', 'what is rayleigh '
            'scattering?'],
      });
      expect(parsed, isA<RetrievalRoleParsed>());
      final out = (parsed as RetrievalRoleParsed).output;
      expect(out, isA<RecallPlannerOutput>());
      expect((out as RecallPlannerOutput).questions, hasLength(2));
    });

    test('hypothesis_writer parses an answers list', () {
      final parsed = parseRetrievalRoleOutput('hypothesis_writer', const {
        'answers': <String>['the sky is blue because of rayleigh scattering'],
      });
      expect(parsed, isA<RetrievalRoleParsed>());
      final out = (parsed as RetrievalRoleParsed).output as HypothesisWriterOutput;
      expect(out.answers, hasLength(1));
    });

    test('query_term_writer parses a query + synonyms', () {
      final parsed = parseRetrievalRoleOutput('query_term_writer', const {
        'query': 'sky blue rayleigh',
        'synonyms': <String>['atmosphere', 'scattering'],
      });
      final out = (parsed as RetrievalRoleParsed).output as QueryTermWriterOutput;
      expect(out.query, equals('sky blue rayleigh'));
      expect(out.synonyms, hasLength(2));
    });

    test('category_selector parses node/edge/concept lists', () {
      final parsed = parseRetrievalRoleOutput('category_selector', const {
        'node_types': <String>['Concept', 'Claim'],
        'edge_types': <String>['relates_to'],
        'concept_names': <String>['optics'],
      });
      final out = (parsed as RetrievalRoleParsed).output as CategorySelectorOutput;
      expect(out.nodeTypes, equals(<String>['Concept', 'Claim']));
      expect(out.edgeTypes, equals(<String>['relates_to']));
      expect(out.conceptNames, equals(<String>['optics']));
    });

    test('retrieval_reranker parses a scored ordering', () {
      final parsed = parseRetrievalRoleOutput('retrieval_reranker', const {
        'ranking': <Map<String, Object?>>[
          {'id': 'n1', 'score': 0.9},
          {'id': 'n2', 'score': 0.4},
        ],
      });
      final out = (parsed as RetrievalRoleParsed).output as RetrievalRerankerOutput;
      expect(out.ranking, hasLength(2));
      expect(out.ranking.first.id, equals('n1'));
      expect(out.ranking.first.score, closeTo(0.9, 1e-9));
    });

    test('profile_selector parses a profile + confidence', () {
      final parsed = parseRetrievalRoleOutput('profile_selector', const {
        'profile': 'work',
        'confidence': 0.82,
      });
      final out = (parsed as RetrievalRoleParsed).output as ProfileSelectorOutput;
      expect(out.profile, equals('work'));
      expect(out.confidence, closeTo(0.82, 1e-9));
    });
  });

  group('retrieval role output — malformed degrades gracefully', () {
    // The Test clause: "rejects a malformed one (graceful `retrieval.*`,
    // not a crash)". Every malformed shape must yield a Degraded carrying
    // `retrieval.role.output.malformed`, never throw.
    final malformed = <String, Map<String, Object?>>{
      'recall_planner': const {'questions': 'not a list'},
      'hypothesis_writer': const {'answers': <Object?>[42]},
      'query_term_writer': const {'synonyms': <String>['x']}, // no query
      'category_selector': const {'node_types': 'Concept'}, // wrong type
      'retrieval_reranker': const {
        'ranking': <Map<String, Object?>>[
          {'id': 'n1'}, // missing score
        ],
      },
      'profile_selector': const {'profile': 'work'}, // no confidence
    };

    for (final id in retrievalRoleIds) {
      test('$id degrades on a malformed payload', () {
        final parse = parseRetrievalRoleOutput(id, malformed[id]!);
        expect(parse, isA<RetrievalRoleDegraded>(), reason: id);
        expect(
          (parse as RetrievalRoleDegraded).code,
          equals(retrievalRoleOutputMalformed),
          reason: id,
        );
      });

      test('$id degrades on an empty payload', () {
        final parse = parseRetrievalRoleOutput(id, const {});
        expect(parse, isA<RetrievalRoleDegraded>(), reason: id);
      });
    }

    test('an unknown role id degrades rather than throwing', () {
      final parse = parseRetrievalRoleOutput('not_a_role', const {});
      expect(parse, isA<RetrievalRoleDegraded>());
    });
  });

  group('retrieval role routes resolve', () {
    test('defaultRetrievalRoleRoutes yields a cheap route per role', () {
      final routes = defaultRetrievalRoleRoutes(
        providerId: 'ollama',
        model: 'gemma3:4b',
      );
      final policy = RouterPolicy(roleRoutes: routes);
      for (final id in retrievalRoleIds) {
        final chain = policy.routesFor(id);
        expect(chain, isNotNull, reason: id);
        expect(chain, isNotEmpty, reason: id);
        expect(chain!.first.providerId, equals('ollama'), reason: id);
        expect(chain.first.model, equals('gemma3:4b'), reason: id);
      }
    });
  });
}
