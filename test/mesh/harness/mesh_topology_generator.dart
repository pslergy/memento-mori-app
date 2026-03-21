// Topology generator for mesh network stress tests.
// Generates random graphs, clusters, partitions, bridge nodes.

import 'dart:math' as math;

enum MeshTopologyType {
  random,
  chain,
  star,
  cluster,
  partition,
}

class MeshTopology {
  final int nodeCount;
  final List<MeshEdge> edges;

  MeshTopology({required this.nodeCount, required this.edges});
}

class MeshEdge {
  final String from;
  final String to;

  MeshEdge(this.from, this.to);
}

class MeshTopologyGenerator {
  final math.Random _random;

  MeshTopologyGenerator({int? seed}) : _random = math.Random(seed);

  MeshTopology generate(int nodeCount, MeshTopologyType type) {
    switch (type) {
      case MeshTopologyType.random:
        return _generateRandom(nodeCount);
      case MeshTopologyType.chain:
        return _generateChain(nodeCount);
      case MeshTopologyType.star:
        return _generateStar(nodeCount);
      case MeshTopologyType.cluster:
        return _generateCluster(nodeCount);
      case MeshTopologyType.partition:
        return _generatePartition(nodeCount);
    }
  }

  MeshTopology _generateRandom(int n) {
    final edges = <MeshEdge>[];
    final edgeProb = 0.15 + _random.nextDouble() * 0.2;
    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j < n; j++) {
        if (_random.nextDouble() < edgeProb) {
          edges.add(MeshEdge('node_$i', 'node_$j'));
        }
      }
    }
    if (edges.isEmpty && n > 1) {
      edges.add(MeshEdge('node_0', 'node_1'));
    }
    return MeshTopology(nodeCount: n, edges: edges);
  }

  MeshTopology _generateChain(int n) {
    final edges = <MeshEdge>[];
    for (var i = 0; i < n - 1; i++) {
      edges.add(MeshEdge('node_$i', 'node_${i + 1}'));
    }
    return MeshTopology(nodeCount: n, edges: edges);
  }

  MeshTopology _generateStar(int n) {
    final edges = <MeshEdge>[];
    for (var i = 1; i < n; i++) {
      edges.add(MeshEdge('node_0', 'node_$i'));
    }
    return MeshTopology(nodeCount: n, edges: edges);
  }

  MeshTopology _generateCluster(int n) {
    final clusterSize = (n / 3).ceil().clamp(2, n);
    final edges = <MeshEdge>[];
    for (var c = 0; c < n; c += clusterSize) {
      final end = (c + clusterSize).clamp(0, n);
      for (var i = c; i < end; i++) {
        for (var j = i + 1; j < end; j++) {
          if (j < n) edges.add(MeshEdge('node_$i', 'node_$j'));
        }
      }
      if (c + clusterSize < n) {
        edges.add(MeshEdge('node_$c', 'node_${c + clusterSize}'));
      }
    }
    return MeshTopology(nodeCount: n, edges: edges);
  }

  MeshTopology _generatePartition(int n) {
    final mid = n ~/ 2;
    final edges = <MeshEdge>[];
    for (var i = 0; i < mid - 1; i++) {
      edges.add(MeshEdge('node_$i', 'node_${i + 1}'));
    }
    for (var i = mid; i < n - 1; i++) {
      edges.add(MeshEdge('node_$i', 'node_${i + 1}'));
    }
    return MeshTopology(nodeCount: n, edges: edges);
  }
}
