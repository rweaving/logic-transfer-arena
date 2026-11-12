import 'dart:math' as math;
import 'dart:typed_data';

import 'signal_types.dart';

/// Polylines and cumulative normalized arc-length parameterization for a directed wire.
final class WirePath {
  final int edgeIndex;
  final int srcNode;
  final int dstNode;
  final int pinRole;

  /// Interleaved normalized `[x0, y0, x1, y1, ...]` coordinates in `[0.0, 1.0]`.
  final Float32List points;

  /// Cumulative normalized distance `[0.0, ..., 1.0]` per vertex for smooth pulse interpolation.
  final Float32List cumulativeT;

  final double totalLength;

  WirePath({
    required this.edgeIndex,
    required this.srcNode,
    required this.dstNode,
    required this.pinRole,
    required this.points,
  }) : assert(points.length >= 4 && points.length.isEven),
       cumulativeT = _computeCumulative(points),
       totalLength = _computeTotalLength(points);

  int get vertexCount => points.length >> 1;

  /// Samples normalized `(x, y)` along the polyline at fraction `u` in `[0.0, 1.0]`.
  (double x, double y) sampleAt(double u) {
    final double clamped = u.clamp(0.0, 1.0);
    final int count = vertexCount;
    if (clamped <= 0.0 || count <= 1) {
      return (points[0], points[1]);
    }
    if (clamped >= 1.0) {
      return (points[(count - 1) * 2], points[(count - 1) * 2 + 1]);
    }
    for (int i = 1; i < count; i++) {
      final double t1 = cumulativeT[i];
      if (clamped <= t1) {
        final double t0 = cumulativeT[i - 1];
        final double span = t1 - t0;
        final double f = span > 1e-6 ? (clamped - t0) / span : 0.0;
        final double x0 = points[(i - 1) * 2];
        final double y0 = points[(i - 1) * 2 + 1];
        final double x1 = points[i * 2];
        final double y1 = points[i * 2 + 1];
        return (x0 + (x1 - x0) * f, y0 + (y1 - y0) * f);
      }
    }
    return (points[(count - 1) * 2], points[(count - 1) * 2 + 1]);
  }

  static double _computeTotalLength(Float32List pts) {
    double sum = 0.0;
    for (int i = 2; i < pts.length; i += 2) {
      final double dx = pts[i] - pts[i - 2];
      final double dy = pts[i + 1] - pts[i - 1];
      sum += math.sqrt(dx * dx + dy * dy);
    }
    return sum;
  }

  static Float32List _computeCumulative(Float32List pts) {
    final int n = pts.length >> 1;
    final Float32List cum = Float32List(n);
    double total = 0.0;
    for (int i = 1; i < n; i++) {
      final double dx = pts[i * 2] - pts[(i - 1) * 2];
      final double dy = pts[i * 2 + 1] - pts[(i - 1) * 2 + 1];
      total += math.sqrt(dx * dx + dy * dy);
      cum[i] = total;
    }
    if (total > 1e-6) {
      for (int i = 1; i < n; i++) {
        cum[i] /= total;
      }
    } else {
      for (int i = 1; i < n; i++) {
        cum[i] = i / (n - 1);
      }
    }
    cum[n - 1] = 1.0;
    return cum;
  }
}

/// Immutable flat-array graph representation shared across simulation and AI rollouts.
final class ArenaTopology {
  static const int maxSupportedNodes = 64;
  static const int ticksPerSecond = 20;

  final String id;
  final String title;
  final BoardArchetype archetype;

  final int nodeCount;
  final int edgeCount;

  /// [NodeType.index] for each node `[0 .. nodeCount - 1]`.
  final Uint8List nodeType;

  /// Per-node parameter:
  /// - `inputRail` / `burstRail`: `1 = Cyan`, `2 = Amber`
  /// - `buffer`: delay ticks `1..16` (default `4`)
  /// - `notGate`: territory bias `1 = Cyan`, `2 = Amber`
  /// - `busNode`: score multiplier (`1` standard, `2` Core Node)
  /// - `srLatch`: optional initial pre-charge owner (`0 = Neutral`, `1 = Cyan`, `2 = Amber`)
  final Uint8List nodeParam;

  /// Normalized `[0.0, 1.0]` landscape board coordinates.
  final Float32List nodeX;
  final Float32List nodeY;

  /// Compressed Sparse Row (CSR) incoming edge tables for `O(1)` lookup in `step()`.
  final Uint16List inEdgeStart;
  final Uint8List inEdgeSrc;
  final Uint8List inEdgeRole;

  /// Compressed Sparse Row (CSR) outgoing edge tables for static analysis & UI trace highlight.
  final Uint16List outEdgeStart;
  final Uint8List outEdgeDst;
  final Uint8List outEdgeWireIndex;

  /// Ordered node indices for Left (Cyan) rails, Right (Amber) rails, and Central Bus.
  final Uint8List leftRails;
  final Uint8List rightRails;
  final Uint8List busNodes;

  /// Precomputed polyline paths for every directed wire edge.
  final List<WirePath> wires;

  /// Precomputed bitmask of nodes that have a directed causal path to at least one Bus Node.
  final int busCausalMaskLo;
  final int busCausalMaskHi;

  /// Match configuration parameters.
  final int cyanInitialPulsers;
  final int amberInitialPulsers;
  final int pulserBurnTicks;
  final int burstBurnTicks;
  final int railCooldownTicks;
  final int liveDurationTicks;
  final int maxOvertimeTicks;
  final bool allowPrepPhase;

  ArenaTopology._({
    required this.id,
    required this.title,
    required this.archetype,
    required this.nodeCount,
    required this.edgeCount,
    required this.nodeType,
    required this.nodeParam,
    required this.nodeX,
    required this.nodeY,
    required this.inEdgeStart,
    required this.inEdgeSrc,
    required this.inEdgeRole,
    required this.outEdgeStart,
    required this.outEdgeDst,
    required this.outEdgeWireIndex,
    required this.leftRails,
    required this.rightRails,
    required this.busNodes,
    required this.wires,
    required this.busCausalMaskLo,
    required this.busCausalMaskHi,
    required this.cyanInitialPulsers,
    required this.amberInitialPulsers,
    required this.pulserBurnTicks,
    required this.burstBurnTicks,
    required this.railCooldownTicks,
    required this.liveDurationTicks,
    required this.maxOvertimeTicks,
    required this.allowPrepPhase,
  });

  NodeType typeOf(int nodeId) => NodeType.values[nodeType[nodeId]];

  Uint8List railsFor(ArenaSide side) =>
      side == ArenaSide.cyan ? leftRails : rightRails;

  bool canReachBus(int nodeId) {
    if (nodeId < 32) {
      return ((busCausalMaskLo >>> nodeId) & 1) != 0;
    }
    return ((busCausalMaskHi >>> (nodeId - 32)) & 1) != 0;
  }

  /// Propagation delay in ticks for a single pass through [nodeId].
  int delayOf(int nodeId) {
    final NodeType t = typeOf(nodeId);
    if (t == NodeType.buffer) {
      return nodeParam[nodeId].clamp(1, 16);
    }
    if (t.isRail || t == NodeType.busNode) {
      return 0;
    }
    return 1;
  }

  /// Total maximum Bus score points available on this board.
  int get maxBusPoints {
    int sum = 0;
    for (int i = 0; i < busNodes.length; i++) {
      sum += nodeParam[busNodes[i]].clamp(1, 2);
    }
    return sum;
  }

  /// Returns downstream node & wire indices up to [maxHops] from [startNode] for press-and-hold UX.
  ({Set<int> nodes, Set<int> wireIndices}) traceDownstream(
    int startNode, {
    int maxHops = 3,
  }) {
    final Set<int> visitedNodes = <int>{startNode};
    final Set<int> visitedWires = <int>{};
    List<int> frontier = <int>[startNode];

    for (int hop = 0; hop < maxHops && frontier.isNotEmpty; hop++) {
      final List<int> nextFrontier = <int>[];
      for (final int u in frontier) {
        final int start = outEdgeStart[u];
        final int end = outEdgeStart[u + 1];
        for (int e = start; e < end; e++) {
          final int v = outEdgeDst[e];
          visitedWires.add(outEdgeWireIndex[e]);
          if (visitedNodes.add(v) && typeOf(v) != NodeType.busNode) {
            nextFrontier.add(v);
          }
        }
      }
      frontier = nextFrontier;
    }
    return (nodes: visitedNodes, wireIndices: visitedWires);
  }

  /// Returns which side's configurable territory [nodeId] belongs to (`null` if Central Bus or Rail).
  ArenaSide? configurableSideOf(int nodeId) {
    if (nodeId < 0 || nodeId >= nodeCount) return null;
    if (!typeOf(nodeId).isConfigurableSocket) return null;
    final double x = nodeX[nodeId];
    if (x > 0.08 && x < 0.47) return ArenaSide.cyan;
    if (x > 0.53 && x < 0.92) return ArenaSide.amber;
    return null;
  }

  /// Reconfigures a gate socket in [side]'s territory to any real Boolean gate in
  /// [NodeType.configurablePalette] (`AND`, `OR`, `XOR`, `NAND`, `NOR`, `NOT`, `BUFFER`).
  ArenaTopology? tryConfigureGate({
    required ArenaSide side,
    required int nodeId,
    required NodeType newType,
  }) {
    if (nodeId < 0 || nodeId >= nodeCount) return null;
    if (!NodeType.configurablePalette.contains(newType)) return null;
    final ArenaSide? ownerSide = configurableSideOf(nodeId);
    if (ownerSide != side) return null;

    final ArenaTopologyBuilder builder = toBuilder();
    builder.nodes[nodeId].type = newType;
    if (newType == NodeType.buffer) {
      builder.nodes[nodeId].param = 4; // 4-tick (200ms) hardware delay
    } else if (newType.isInvertingGate) {
      // Bit 0x08 marks CMOS VCC-gated territory power (active while side has >=1 live Pulser).
      builder.nodes[nodeId].param = side.code | 0x08;
    } else {
      builder.nodes[nodeId].param = 0;
    }
    return builder.build();
  }

  /// Backward-compatible alias for swapping a gate in [side]'s home territory during Prep.
  ArenaTopology? trySwapHomeGate({
    required ArenaSide side,
    required int nodeId,
    required NodeType newType,
  }) =>
      tryConfigureGate(side: side, nodeId: nodeId, newType: newType);

  /// Returns a new topology with a Pre-Round Prep jumper wire added in [side]'s home territory.
  ArenaTopology? tryAddHomeJumper({
    required ArenaSide side,
    required int srcNode,
    required int dstNode,
    int pinRole = PinRole.standard,
  }) {
    if (srcNode < 0 ||
        srcNode >= nodeCount ||
        dstNode < 0 ||
        dstNode >= nodeCount ||
        srcNode == dstNode) {
      return null;
    }
    final NodeType dstType = typeOf(dstNode);
    if (dstType.isRail || typeOf(srcNode) == NodeType.deadEnd) return null;

    final double sx = nodeX[srcNode];
    final double dx = nodeX[dstNode];
    final bool validTerritory = side == ArenaSide.cyan
        ? (sx <= 0.47 && dx > 0.08 && dx <= 0.50)
        : (sx >= 0.53 && dx >= 0.50 && dx < 0.92);
    if (!validTerritory) return null;

    // Prevent duplicate edges.
    for (int e = outEdgeStart[srcNode]; e < outEdgeStart[srcNode + 1]; e++) {
      if (outEdgeDst[e] == dstNode) return null;
    }
    // Cap gate input count to 3 so truth tables stay readable.
    final int currentInputs = inEdgeStart[dstNode + 1] - inEdgeStart[dstNode];
    if (currentInputs >= 3) return null;

    final ArenaTopologyBuilder builder = toBuilder();
    final int resolvedRole =
        dstType == NodeType.srLatch && pinRole == PinRole.standard
            ? PinRole.set
            : pinRole;
    builder.addOctilinearEdge(srcNode, dstNode, pinRole: resolvedRole);
    return builder.build();
  }

  ArenaTopologyBuilder toBuilder() {
    final ArenaTopologyBuilder b = ArenaTopologyBuilder(
      id: id,
      title: title,
      archetype: archetype,
      cyanInitialPulsers: cyanInitialPulsers,
      amberInitialPulsers: amberInitialPulsers,
      pulserBurnTicks: pulserBurnTicks,
      burstBurnTicks: burstBurnTicks,
      railCooldownTicks: railCooldownTicks,
      liveDurationTicks: liveDurationTicks,
      maxOvertimeTicks: maxOvertimeTicks,
      allowPrepPhase: allowPrepPhase,
    );
    for (int i = 0; i < nodeCount; i++) {
      b.addNode(
        type: typeOf(i),
        x: nodeX[i],
        y: nodeY[i],
        param: nodeParam[i],
      );
    }
    for (final WirePath w in wires) {
      b.addEdgeWithPoints(
        w.srcNode,
        w.dstNode,
        pinRole: w.pinRole,
        points: Float32List.fromList(w.points),
      );
    }
    return b;
  }
}

/// Mutable node specification used during [ArenaTopologyBuilder] construction.
final class NodeSpec {
  NodeType type;
  double x;
  double y;
  int param;

  NodeSpec({
    required this.type,
    required this.x,
    required this.y,
    required this.param,
  });
}

final class _EdgeSpec {
  final int src;
  final int dst;
  final int pinRole;
  final Float32List points;

  const _EdgeSpec({
    required this.src,
    required this.dst,
    required this.pinRole,
    required this.points,
  });
}

/// Ergonomic builder that compiles graphs into flat CSR [ArenaTopology] tables.
final class ArenaTopologyBuilder {
  String id;
  String title;
  BoardArchetype archetype;
  int cyanInitialPulsers;
  int amberInitialPulsers;
  int pulserBurnTicks;
  int burstBurnTicks;
  int railCooldownTicks;
  int liveDurationTicks;
  int maxOvertimeTicks;
  bool allowPrepPhase;

  final List<NodeSpec> nodes = <NodeSpec>[];
  final List<_EdgeSpec> _edges = <_EdgeSpec>[];

  ArenaTopologyBuilder({
    this.id = 'custom',
    this.title = 'Transfer Sector',
    this.archetype = BoardArchetype.mirrorSymmetric,
    this.cyanInitialPulsers = 5,
    this.amberInitialPulsers = 5,
    this.pulserBurnTicks = 80,
    this.burstBurnTicks = 10,
    this.railCooldownTicks = 6,
    this.liveDurationTicks = 300,
    this.maxOvertimeTicks = 40,
    this.allowPrepPhase = false,
  });

  int addNode({
    required NodeType type,
    required double x,
    required double y,
    int param = 0,
  }) {
    if (nodes.length >= ArenaTopology.maxSupportedNodes) {
      throw StateError(
        'ArenaTopology supports at most ${ArenaTopology.maxSupportedNodes} nodes.',
      );
    }
    final int idx = nodes.length;
    nodes.add(NodeSpec(
      type: type,
      x: x.clamp(0.0, 1.0),
      y: y.clamp(0.0, 1.0),
      param: param,
    ));
    return idx;
  }

  void addEdgeWithPoints(
    int src,
    int dst, {
    int pinRole = PinRole.standard,
    required Float32List points,
  }) {
    _edges.add(_EdgeSpec(
      src: src,
      dst: dst,
      pinRole: pinRole,
      points: points,
    ));
  }

  /// Routes a clean 45-degree chamfered PCB trace between [src] and [dst].
  void addOctilinearEdge(
    int src,
    int dst, {
    int pinRole = PinRole.standard,
    double laneOffset = 0.0,
  }) {
    final NodeSpec a = nodes[src];
    final NodeSpec b = nodes[dst];
    final Float32List pts = routeOctilinear(
      a.x,
      a.y,
      b.x,
      b.y,
      laneOffset: laneOffset,
    );
    addEdgeWithPoints(src, dst, pinRole: pinRole, points: pts);
  }

  /// Generates octilinear (`0° / 45° / 90°`) PCB trace points between two normalized coordinates.
  static Float32List routeOctilinear(
    double x0,
    double y0,
    double x1,
    double y1, {
    double laneOffset = 0.0,
  }) {
    final double dx = x1 - x0;
    final double dy = y1 - y0;
    final double adx = dx.abs();
    final double ady = dy.abs();

    if (ady < 0.004 || adx < 0.004) {
      return Float32List.fromList(<double>[x0, y0, x1, y1]);
    }

    // Chamfered Z-bend: horizontal lead -> 45-degree diagonal / vertical jog -> horizontal lead.
    final double midX = ((x0 + x1) * 0.5 + laneOffset).clamp(0.04, 0.96);
    final double bevel = math.min(adx * 0.22, ady * 0.45);
    final double sx = dx >= 0 ? 1.0 : -1.0;
    final double sy = dy >= 0 ? 1.0 : -1.0;

    final double p1x = midX - sx * bevel;
    final double p1y = y0;
    final double p2x = midX;
    final double p2y = y0 + sy * bevel;
    final double p3x = midX;
    final double p3y = y1 - sy * bevel;
    final double p4x = midX + sx * bevel;
    final double p4y = y1;

    if ((p1x - x0) * sx <= 0.002 || (x1 - p4x) * sx <= 0.002) {
      return Float32List.fromList(<double>[
        x0,
        y0,
        midX,
        y0,
        midX,
        y1,
        x1,
        y1,
      ]);
    }

    return Float32List.fromList(<double>[
      x0,
      y0,
      p1x,
      p1y,
      p2x,
      p2y,
      p3x,
      p3y,
      p4x,
      p4y,
      x1,
      y1,
    ]);
  }

  ArenaTopology build() {
    final int n = nodes.length;
    final int m = _edges.length;

    final Uint8List nodeType = Uint8List(n);
    final Uint8List nodeParam = Uint8List(n);
    final Float32List nodeX = Float32List(n);
    final Float32List nodeY = Float32List(n);

    final List<int> leftRails = <int>[];
    final List<int> rightRails = <int>[];
    final List<int> busNodes = <int>[];

    for (int i = 0; i < n; i++) {
      final NodeSpec spec = nodes[i];
      nodeType[i] = spec.type.index;
      nodeParam[i] = spec.param;
      nodeX[i] = spec.x;
      nodeY[i] = spec.y;

      if (spec.type.isRail) {
        if (spec.param == ArenaSide.cyan.code) {
          leftRails.add(i);
        } else if (spec.param == ArenaSide.amber.code) {
          rightRails.add(i);
        }
      } else if (spec.type == NodeType.busNode) {
        busNodes.add(i);
      }
    }

    leftRails.sort((a, b) => nodeY[a].compareTo(nodeY[b]));
    rightRails.sort((a, b) => nodeY[a].compareTo(nodeY[b]));
    busNodes.sort((a, b) => nodeY[a].compareTo(nodeY[b]));

    final List<WirePath> wires = List<WirePath>.generate(
      m,
      (int idx) => WirePath(
        edgeIndex: idx,
        srcNode: _edges[idx].src,
        dstNode: _edges[idx].dst,
        pinRole: _edges[idx].pinRole,
        points: _edges[idx].points,
      ),
      growable: false,
    );

    // Build CSR incoming edges.
    final Uint16List inCounts = Uint16List(n);
    final Uint16List outCounts = Uint16List(n);
    for (int e = 0; e < m; e++) {
      inCounts[_edges[e].dst]++;
      outCounts[_edges[e].src]++;
    }

    final Uint16List inEdgeStart = Uint16List(n + 1);
    final Uint16List outEdgeStart = Uint16List(n + 1);
    for (int i = 0; i < n; i++) {
      inEdgeStart[i + 1] = inEdgeStart[i] + inCounts[i];
      outEdgeStart[i + 1] = outEdgeStart[i] + outCounts[i];
    }

    final Uint8List inEdgeSrc = Uint8List(m);
    final Uint8List inEdgeRole = Uint8List(m);
    final Uint16List inCursor = Uint16List.fromList(inEdgeStart);

    final Uint8List outEdgeDst = Uint8List(m);
    final Uint8List outEdgeWireIndex = Uint8List(m);
    final Uint16List outCursor = Uint16List.fromList(outEdgeStart);

    for (int e = 0; e < m; e++) {
      final _EdgeSpec edge = _edges[e];
      final int inPos = inCursor[edge.dst]++;
      inEdgeSrc[inPos] = edge.src;
      inEdgeRole[inPos] = edge.pinRole;

      final int outPos = outCursor[edge.src]++;
      outEdgeDst[outPos] = edge.dst;
      outEdgeWireIndex[outPos] = e;
    }

    // Reverse BFS from Central Bus nodes to compute causal reachability bitmask.
    int maskLo = 0;
    int maskHi = 0;
    final List<int> queue = List<int>.from(busNodes);
    for (final int b in busNodes) {
      if (b < 32) {
        maskLo |= (1 << b);
      } else {
        maskHi |= (1 << (b - 32));
      }
    }
    int head = 0;
    while (head < queue.length) {
      final int cur = queue[head++];
      for (int e = inEdgeStart[cur]; e < inEdgeStart[cur + 1]; e++) {
        final int u = inEdgeSrc[e];
        final bool already = u < 32
            ? (((maskLo >>> u) & 1) != 0)
            : (((maskHi >>> (u - 32)) & 1) != 0);
        if (!already) {
          if (u < 32) {
            maskLo |= (1 << u);
          } else {
            maskHi |= (1 << (u - 32));
          }
          queue.add(u);
        }
      }
    }

    return ArenaTopology._(
      id: id,
      title: title,
      archetype: archetype,
      nodeCount: n,
      edgeCount: m,
      nodeType: nodeType,
      nodeParam: nodeParam,
      nodeX: nodeX,
      nodeY: nodeY,
      inEdgeStart: inEdgeStart,
      inEdgeSrc: inEdgeSrc,
      inEdgeRole: inEdgeRole,
      outEdgeStart: outEdgeStart,
      outEdgeDst: outEdgeDst,
      outEdgeWireIndex: outEdgeWireIndex,
      leftRails: Uint8List.fromList(leftRails),
      rightRails: Uint8List.fromList(rightRails),
      busNodes: Uint8List.fromList(busNodes),
      wires: wires,
      busCausalMaskLo: maskLo,
      busCausalMaskHi: maskHi,
      cyanInitialPulsers: cyanInitialPulsers,
      amberInitialPulsers: amberInitialPulsers,
      pulserBurnTicks: pulserBurnTicks,
      burstBurnTicks: burstBurnTicks,
      railCooldownTicks: railCooldownTicks,
      liveDurationTicks: liveDurationTicks,
      maxOvertimeTicks: maxOvertimeTicks,
      allowPrepPhase: allowPrepPhase,
    );
  }
}
