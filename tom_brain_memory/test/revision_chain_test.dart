// Todo 8 (G-P5) — the domain-free `superseded_by` chain walk
// (`planning_specification.md` § 7.4; `procedure_specification.md` § 7.2; hard
// principle 6).
//
// `walkSupersededByChain` is the single graph primitive behind both
// `ProcedureRevisionChain` (procedure spec) and `SupersededHistoryOf` (planning
// spec): a `superseded_by` edge points `old → new`, so the walk goes backward
// along incoming edges to the chain root and forward along outgoing edges to
// the live tip, returning the whole retained history oldest → newest. These
// tests pin the walk against a recording fake so the composition is host-free.

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  group('walkSupersededByChain', () {
    test('walks both ways from a mid-chain anchor, oldest → newest', () async {
      final a = _node('a');
      final b = _node('b');
      final c = _node('c');
      final fake = _FakeClient()
        ..nodes = {a.id: a, b.id: b, c.id: c}
        ..supersededByOutgoing = {a.id: b.id, b.id: c.id}
        ..supersededByIncoming = {c.id: b.id, b.id: a.id};

      final chain = await walkSupersededByChain(fake, b.id);

      expect(chain.map((n) => n.values['tag']), <String>['a', 'b', 'c']);
    });

    test('a lone node is its own one-element chain', () async {
      final only = _node('solo');
      final fake = _FakeClient()..nodes = {only.id: only};

      final chain = await walkSupersededByChain(fake, only.id);
      expect(chain.map((n) => n.values['tag']), <String>['solo']);
    });

    test('an unknown anchor yields an empty chain', () async {
      final chain = await walkSupersededByChain(_FakeClient(), NodeId.generate());
      expect(chain, isEmpty);
    });

    test('a cycle is broken by the seen-set (no infinite walk)', () async {
      final a = _node('a');
      final b = _node('b');
      final fake = _FakeClient()
        ..nodes = {a.id: a, b.id: b}
        // a → b → a, a malformed fork — the walk must terminate.
        ..supersededByOutgoing = {a.id: b.id, b.id: a.id}
        ..supersededByIncoming = {b.id: a.id, a.id: b.id};

      final chain = await walkSupersededByChain(fake, a.id);
      expect(chain.length, 2);
      expect(chain.map((n) => n.values['tag']).toSet(), <String>{'a', 'b'});
    });
  });
}

Node _node(String tag) => Node(
      id: NodeId.generate(),
      typeName: 'Concept',
      createdAt: DateTime.utc(2026, 1, 1),
      values: <String, Object?>{'tag': tag},
    );

class _FakeClient implements TomBrainMemoryClient {
  Map<NodeId, Node> nodes = <NodeId, Node>{};
  Map<NodeId, NodeId> supersededByOutgoing = <NodeId, NodeId>{};
  Map<NodeId, NodeId> supersededByIncoming = <NodeId, NodeId>{};

  @override
  Future<Node?> get(NodeId id) async => nodes[id];

  @override
  Future<List<Node>> getMany(List<NodeId> ids) async =>
      <Node>[for (final id in ids) if (nodes[id] != null) nodes[id]!];

  @override
  Future<List<Edge>> edgesOf(
    NodeId id, {
    EdgeDirection direction = EdgeDirection.both,
    Set<EdgeType>? types,
  }) async {
    final edges = <Edge>[];
    if (direction == EdgeDirection.outgoing) {
      final to = supersededByOutgoing[id];
      if (to != null) edges.add(_edge(id, to));
    } else if (direction == EdgeDirection.incoming) {
      final from = supersededByIncoming[id];
      if (from != null) edges.add(_edge(from, id));
    }
    return edges;
  }

  Edge _edge(NodeId from, NodeId to) => Edge(
        id: EdgeId.generate(),
        from: from,
        type: EdgeType.supersededBy,
        to: to,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        '_FakeClient does not implement ${invocation.memberName}.',
      );
}
