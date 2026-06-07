// Cross-process MCP server fixture (todo #35).
//
// This is the **server half** of the cross-process conformance proof
// for `memory_specification.md` § 20 item 5 ("the MCP server v1 surface
// is callable from a second process"). It is meant to be spawned as a
// real, separate OS process by `mcp_cross_process_test.dart`; the test
// process is the MCP client and never shares an isolate (let alone a
// `TomBrainMemory` reference) with this server.
//
// What it does:
//
//   1. Builds a deterministic in-memory `TomBrainMemory` double
//      (`_SeededMemory`) so the client can assert exact round-tripped
//      values without standing up sqlite-vec in a child process. The
//      *transport / process boundary* is what this fixture proves; the
//      concrete `SqliteTomBrainMemory` substitution is a separate
//      carry-forward (memory_specification.md § 20 item 1) and is out
//      of scope here.
//   2. Binds the Streamable-HTTP server transport (`McpHttpServer`,
//      todo #3) on the loopback interface, OS-assigned port (`port: 0`),
//      with the seven v1 tools wired (`memory:` supplied) and no
//      authenticator (anonymous, the trust-the-VPN default).
//   3. Prints exactly one machine-readable line to stdout —
//      `MCP_HTTP_PORT=<port>` — so the parent can discover the port.
//      (Any `MemoryLog` noise on stdout is ignored by the parent's
//      line scan; only the marker line matches.)
//   4. Stays alive until its stdin closes (the parent killing the
//      process, or closing the pipe), then tears the server down.
//
// Run directly: `dart test/fixtures/mcp_http_server_fixture.dart`.

import 'dart:async';
import 'dart:io';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        EdgeId,
        MultiRecallQuery,
        NodeId,
        RecallProvenanceEntry,
        StackEntryId,
        Vec;

/// The marker prefix the parent process scans stdout for. Kept in sync
/// with the consumer in `mcp_cross_process_test.dart`.
const String portMarker = 'MCP_HTTP_PORT=';

Future<void> main() async {
  final memory = _SeededMemory();
  final server = await McpHttpServer.bind(
    onSession: (channel) => TomBrainMemoryMcpServer(channel, memory: memory),
  );

  // Single machine-readable handshake line for the parent.
  stdout.writeln('$portMarker${server.port}');
  await stdout.flush();

  // Stay alive until the parent closes our stdin (or kills us). Listening
  // on stdin gives a clean shutdown path that does not leak the listener.
  final done = Completer<void>();
  stdin.listen(
    (_) {/* ignore any input bytes */},
    onDone: done.complete,
    onError: (Object _) => done.complete(),
    cancelOnError: true,
  );
  await done.future;

  await server.close();
}

// ─── Seeded deterministic memory double ───────────────────────────────
//
// Mirrors the `_FakeMemory` pattern from `a77_mcp_tools_test.dart`: only
// the read+persist surface the seven v1 tools touch is implemented; every
// other `TomBrainMemory` member raises through `noSuchMethod` to keep the
// boundary explicit.

/// The seeded Question node every read tool surfaces. The client asserts
/// these exact values came back across the process boundary.
final NodeId _seedNodeId = NodeId.fromString('n_${_ulid('Q001')}');
final NodeId _seedTargetId = NodeId.fromString('n_${_ulid('Q002')}');

Node _seedNode() => Node(
      id: _seedNodeId,
      typeName: 'Question',
      values: const {'text': 'why is the sky blue'},
      createdAt: DateTime.utc(2026, 6, 4, 9, 0, 0),
    );

class _SeededMemory implements TomBrainMemory {
  @override
  final _SeededStacks stacks = _SeededStacks();

  @override
  Future<RecallResult> recall(RecallQuery query) async => RecallResult(
        nodes: [_seedNode()],
        report: const RecallReport(
          candidatesPerMode: {RecallMode.bm25: 1},
          fusionStrategy: FusionStrategy.rrf,
          diversityStrategy: DiversityStrategy.mmr,
          diversityLambda: 0.7,
          elapsedMs: 3,
        ),
      );

  @override
  Future<List<Node>> getMany(List<NodeId> ids) async =>
      ids.contains(_seedNodeId) ? [_seedNode()] : const [];

  @override
  Future<List<Edge>> edgesOf(
    NodeId id, {
    EdgeDirection direction = EdgeDirection.both,
    Set<EdgeType>? types,
  }) async =>
      [
        Edge(
          id: EdgeId.fromString('e_${_ulid('E001')}'),
          from: _seedNodeId,
          type: EdgeType.mentions,
          to: _seedTargetId,
        ),
      ];

  @override
  Future<ClassificationResult> classify(
    Vec embedding, {
    ClassificationTarget target = ClassificationTarget.nodeType,
  }) async =>
      const ClassificationResult(
        decision: ClassificationDecision.confident,
        bestMatch: 'Question',
        bestSimilarity: 0.93,
        secondSimilarity: 0.42,
      );

  @override
  Future<NodeId> persist(NodeDraft draft, {required Scope scope}) async =>
      NodeId.fromString('n_${_ulid('P001')}');

  /// A deterministic multi-seed fusion result. The seeded node is
  /// surfaced by both seeds (`seedIndexes: [0, 1]`) so the client can
  /// assert that the provenance crossed the process boundary intact.
  /// No substrate / LLM is involved — the executor would embed text
  /// seeds through the storage-stack embedder, never an LLM, and this
  /// double simply returns the canned fusion.
  @override
  Future<RecallResult> recallMulti(MultiRecallQuery query) async =>
      RecallResult(
        nodes: [_seedNode()],
        report: const RecallReport(
          candidatesPerMode: {RecallMode.bm25: 2},
          fusionStrategy: FusionStrategy.rrf,
          diversityStrategy: DiversityStrategy.mmr,
          diversityLambda: 0.7,
          elapsedMs: 4,
        ),
        provenance: [
          RecallProvenanceEntry(
            nodeId: _seedNodeId,
            seedIndexes: const [0, 1],
            fusedScore: 0.5,
          ),
        ],
      );

  @override
  MemoryProfileRegistry get profiles => _SeededProfiles();

  @override
  String? get currentProfile => 'eval_a';

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        '_SeededMemory does not implement ${invocation.memberName}; the '
        'cross-process fixture only exercises the v1 tool methods.',
      );
}

/// A deterministic profile registry — only `list` is reachable through
/// the read-only MCP surface (`memory.profiles.list`); every mutating
/// member raises to keep the boundary explicit.
class _SeededProfiles implements MemoryProfileRegistry {
  @override
  Future<List<String>> list() async => const ['eval_a', 'eval_b'];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        '_SeededProfiles does not implement ${invocation.memberName}; the '
        'cross-process fixture only exercises list.',
      );
}

class _SeededStacks implements StackApi {
  @override
  Future<List<StackSummary>> list() async => const [
        StackSummary(
          name: 'questions_open',
          size: 1,
          topPriority: 0.9,
          bootstrap: true,
        ),
      ];

  @override
  Future<List<StackEntry>> peek(String name, {int k = 16}) async => [
        StackEntry(
          id: StackEntryId.fromString('se_${_ulid('S001')}'),
          stackName: name,
          nodeId: _seedNodeId,
          priority: 0.75,
          pushedAt: DateTime.utc(2026, 6, 4, 9, 5, 0),
        ),
      ];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        '_SeededStacks does not implement ${invocation.memberName}; the '
        'cross-process fixture only exercises list and peek.',
      );
}

/// Builds a 26-char Crockford base-32 ULID payload whose last four chars
/// are a sanitised [tail], so ids are human-recognisable in assertions.
/// Mirrors the helper in `a77_mcp_tools_test.dart`.
String _ulid(String tail) {
  const filler = '0000000000000000000000';
  const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  final upper = tail.toUpperCase();
  final buf = StringBuffer();
  for (var i = 0; i < upper.length && buf.length < 4; i++) {
    final ch = upper[i];
    if (alphabet.contains(ch)) buf.write(ch);
  }
  return filler + buf.toString().padLeft(4, '0');
}
