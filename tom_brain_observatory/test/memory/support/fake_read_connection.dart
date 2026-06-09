// A test double for the [McpReadConnection] seam (PT-5.1). It records every
// tool name and argument map it is asked to call (so a test can assert the
// client's full surface maps onto exactly the nine read tools — the OBS-2
// centrepiece) and returns canned payloads keyed by tool name.

import 'package:tom_brain_observatory/src/memory/mcp_read_connection.dart';

/// Records the tools/args the client calls and replays canned payloads.
final class FakeReadConnection implements McpReadConnection {
  FakeReadConnection(this._responses);

  final Map<String, Map<String, Object?>> _responses;

  /// Tool names in call order — the OBS-2 assertion reads this.
  final List<String> calledTools = <String>[];

  /// Argument maps in call order, aligned with [calledTools].
  final List<Map<String, Object?>> calledArgs = <Map<String, Object?>>[];

  int closeCount = 0;

  @override
  Future<List<Map<String, Object?>>> listTools() async => <Map<String, Object?>>[
        for (final name in _responses.keys) <String, Object?>{'name': name},
      ];

  @override
  Future<Map<String, Object?>> callTool(
    String name,
    Map<String, Object?> args,
  ) async {
    calledTools.add(name);
    calledArgs.add(args);
    final response = _responses[name];
    if (response == null) {
      throw McpReadException('no stubbed response for tool "$name"');
    }
    return response;
  }

  @override
  Future<void> close() async => closeCount++;
}

/// A canned payload for every read tool, so a single fake can answer the whole
/// client surface (used by the OBS-2 surface test).
Map<String, Map<String, Object?>> allReadToolStubs() => <String, Map<String, Object?>>{
      'memory.recall': _recallPayload,
      'memory.recall.multi': _recallMultiPayload,
      'memory.get': <String, Object?>{
        'nodes': <Object?>[_questionNode],
      },
      'memory.edgesOf': <String, Object?>{
        'edges': <Object?>[_edge],
      },
      'memory.stack.list': <String, Object?>{
        'stacks': <Object?>[_stackSummary],
      },
      'memory.stack.peek': <String, Object?>{
        'entries': <Object?>[_stackEntry],
      },
      'memory.classify': _classification,
      'memory.profiles.list': <String, Object?>{
        'profiles': <Object?>['default', 'eval'],
      },
      'memory.profile.current': <String, Object?>{'profile': 'default'},
    };

const Map<String, Object?> _questionNode = <String, Object?>{
  'id': 'n_question1',
  'typeName': 'Question',
  'values': <String, Object?>{'text': 'what about backup?'},
  'embedding': <Object?>[0.1, 0.2, 0.3],
  'createdAt': '2026-01-01T12:00:00.000Z',
  'status': 'active',
};

const Map<String, Object?> _claimNode = <String, Object?>{
  'id': 'n_claim1',
  'typeName': 'Claim',
  'values': <String, Object?>{'statement': 'tiered backup is decided'},
  'embedding': null,
  'createdAt': '2026-01-01T12:01:00.000Z',
  'status': 'active',
};

const Map<String, Object?> _edge = <String, Object?>{
  'id': 'e_1',
  'from': 'n_question1',
  'type': 'satisfied_by',
  'to': 'n_claim1',
  'weight': 1.0,
  'attrs': <String, Object?>{'note': 'answer'},
};

const Map<String, Object?> _stackSummary = <String, Object?>{
  'name': 'working',
  'size': 3,
  'topPriority': 0.9,
  'bootstrap': false,
};

const Map<String, Object?> _stackEntry = <String, Object?>{
  'id': 'se_1',
  'stackName': 'working',
  'nodeId': 'n_question1',
  'priority': 0.9,
  'pushedAt': '2026-01-01T12:02:00.000Z',
  'status': 'active',
  'attrs': <String, Object?>{},
};

const Map<String, Object?> _classification = <String, Object?>{
  'decision': 'confident',
  'bestMatch': 'Question',
  'bestSimilarity': 0.82,
  'secondSimilarity': 0.41,
};

const Map<String, Object?> _recallReport = <String, Object?>{
  'candidatesPerMode': <String, Object?>{'bm25': 5, 'vector': 2},
  'fusionStrategy': 'rrf',
  'diversityStrategy': 'mmr',
  'diversityLambda': 0.7,
  'elapsedMs': 12,
  'embeddingsCallouts': 0,
  'reRankInvoked': false,
  'degraded': false,
};

const Map<String, Object?> _recallPayload = <String, Object?>{
  'nodes': <Object?>[_questionNode, _claimNode],
  'report': _recallReport,
};

const Map<String, Object?> _recallMultiPayload = <String, Object?>{
  'nodes': <Object?>[_questionNode, _claimNode],
  'report': _recallReport,
  'provenance': <Object?>[
    <String, Object?>{
      'nodeId': 'n_question1',
      'seedIndexes': <Object?>[0, 1],
      'fusedScore': 0.66,
    },
  ],
};
