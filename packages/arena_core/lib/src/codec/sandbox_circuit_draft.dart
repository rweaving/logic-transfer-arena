import '../gen/fairness_validator.dart';
import '../sim/arena_topology.dart';
import '../sim/signal_types.dart';
import 'circuit_url_codec.dart';

/// Mutable node entry inside [SandboxCircuitDraft].
final class SandboxNodeDraft {
  NodeType type;
  double x;
  double y;
  int param;

  SandboxNodeDraft({
    required this.type,
    required this.x,
    required this.y,
    required this.param,
  });

  SandboxNodeDraft clone() => SandboxNodeDraft(
        type: type,
        x: x,
        y: y,
        param: param,
      );
}

/// Mutable directed wire entry inside [SandboxCircuitDraft].
final class SandboxEdgeDraft {
  int src;
  int dst;
  int pinRole;

  SandboxEdgeDraft({
    required this.src,
    required this.dst,
    this.pinRole = PinRole.standard,
  });

  SandboxEdgeDraft clone() => SandboxEdgeDraft(
        src: src,
        dst: dst,
        pinRole: pinRole,
      );
}

/// Live validation & URL hash telemetry for the interactive Sandbox Circuit Editor.
final class SandboxValidationReport {
  final bool ok;
  final String? error;
  final String? urlHash;
  final int? minCycleDelay;
  final int causalCyanRails;
  final int totalCyanRails;
  final int causalAmberRails;
  final int totalAmberRails;

  const SandboxValidationReport({
    required this.ok,
    required this.error,
    required this.urlHash,
    required this.minCycleDelay,
    required this.causalCyanRails,
    required this.totalCyanRails,
    required this.causalAmberRails,
    required this.totalAmberRails,
  });
}

/// Pure-Dart interactive Sandbox Circuit Editor model (`Sandbox -> Arena Bridge`).
///
/// Supports placing, dragging, deleting, and wiring all 15 [NodeType] components,
/// optional real-time Left/Right mirror symmetry (`autoMirror`), `SET`/`RESET`
/// SR-Latch pin selection, fairness checks, and `#arena=v1.<base64url>` export.
final class SandboxCircuitDraft {
  String id;
  String title;
  BoardArchetype archetype;
  int cyanInitialPulsers;
  int amberInitialPulsers;
  int pulserBurnTicks;
  int burstBurnTicks;
  int liveDurationTicks;
  bool allowPrepPhase;
  bool autoMirror;

  final List<SandboxNodeDraft> nodes = <SandboxNodeDraft>[];
  final List<SandboxEdgeDraft> edges = <SandboxEdgeDraft>[];

  SandboxCircuitDraft({
    this.id = 'sandbox_custom',
    this.title = 'Custom Sandbox Arena',
    this.archetype = BoardArchetype.mirrorSymmetric,
    this.cyanInitialPulsers = 5,
    this.amberInitialPulsers = 5,
    this.pulserBurnTicks = 80,
    this.burstBurnTicks = 10,
    this.liveDurationTicks = 300,
    this.allowPrepPhase = true,
    this.autoMirror = true,
  });

  /// Creates a clean starter scaffold with outer Input Rails and a Central Bus spine
  /// ready for placing and wiring custom Boolean gates from scratch.
  factory SandboxCircuitDraft.scaffold({
    int railsPerSide = 4,
    int busCount = 5,
    bool autoMirror = true,
  }) {
    final SandboxCircuitDraft draft = SandboxCircuitDraft(
      autoMirror: autoMirror,
    );
    final int clampedBus = busCount.isEven ? busCount + 1 : busCount;
    for (int i = 0; i < clampedBus; i++) {
      final double y = clampedBus == 1
          ? 0.50
          : 0.16 + (0.68 * i) / (clampedBus - 1);
      final bool isCore = i == clampedBus ~/ 2;
      draft.nodes.add(SandboxNodeDraft(
        type: NodeType.busNode,
        x: 0.50,
        y: _snap63(y),
        param: isCore ? 2 : 1,
      ));
    }

    for (int i = 0; i < railsPerSide; i++) {
      final double y = railsPerSide == 1
          ? 0.50
          : 0.18 + (0.64 * i) / (railsPerSide - 1);
      final NodeType rType =
          (i == railsPerSide ~/ 2 && railsPerSide >= 3)
              ? NodeType.burstRail
              : NodeType.inputRail;
      draft.nodes.add(SandboxNodeDraft(
        type: rType,
        x: _snap63(0.06),
        y: _snap63(y),
        param: ArenaSide.cyan.code,
      ));
      draft.nodes.add(SandboxNodeDraft(
        type: rType,
        x: _snap63(0.94),
        y: _snap63(y),
        param: ArenaSide.amber.code,
      ));
    }
    return draft;
  }

  /// Imports any existing [ArenaTopology] into the mutable Sandbox Editor.
  factory SandboxCircuitDraft.fromTopology(
    ArenaTopology topology, {
    bool autoMirror = false,
  }) {
    final SandboxCircuitDraft draft = SandboxCircuitDraft(
      id: topology.id,
      title: topology.title,
      archetype: topology.archetype,
      cyanInitialPulsers: topology.cyanInitialPulsers,
      amberInitialPulsers: topology.amberInitialPulsers,
      pulserBurnTicks: topology.pulserBurnTicks,
      burstBurnTicks: topology.burstBurnTicks,
      liveDurationTicks: topology.liveDurationTicks,
      allowPrepPhase: topology.allowPrepPhase,
      autoMirror: autoMirror,
    );

    for (int i = 0; i < topology.nodeCount; i++) {
      draft.nodes.add(SandboxNodeDraft(
        type: topology.typeOf(i),
        x: topology.nodeX[i],
        y: topology.nodeY[i],
        param: topology.nodeParam[i],
      ));
    }
    for (final WirePath w in topology.wires) {
      draft.edges.add(SandboxEdgeDraft(
        src: w.srcNode,
        dst: w.dstNode,
        pinRole: w.pinRole,
      ));
    }
    return draft;
  }

  static double _snap63(double v) =>
      ((v.clamp(0.03, 0.97) * 63.0).round() / 63.0).clamp(0.0, 1.0);

  static int defaultParamFor({
    required NodeType type,
    required double x,
    bool coreBus2x = false,
    int bufferDelay = 4,
  }) {
    final ArenaSide side = x <= 0.50 ? ArenaSide.cyan : ArenaSide.amber;
    if (type.isRail) return side.code;
    if (type == NodeType.busNode) return coreBus2x ? 2 : 1;
    if (type == NodeType.buffer) return bufferDelay.clamp(1, 15);
    if (type.isInvertingGate) return side.code | 0x08;
    return 0;
  }

  /// Places a component (and optionally its mirrored twin when [autoMirror] is active).
  /// Returns the primary placed node index, or `null` if the 64-node cap is reached.
  int? placeComponent({
    required NodeType type,
    required double x,
    required double y,
    bool coreBus2x = false,
    int bufferDelay = 4,
  }) {
    if (nodes.length >= ArenaTopology.maxSupportedNodes) return null;

    final double sx = type == NodeType.busNode ? 0.50 : _snap63(x);
    final double sy = _snap63(y);
    final int primaryIdx = nodes.length;
    nodes.add(SandboxNodeDraft(
      type: type,
      x: sx,
      y: sy,
      param: defaultParamFor(
        type: type,
        x: sx,
        coreBus2x: coreBus2x,
        bufferDelay: bufferDelay,
      ),
    ));

    if (autoMirror &&
        type != NodeType.busNode &&
        (sx - 0.50).abs() > 0.045 &&
        nodes.length < ArenaTopology.maxSupportedNodes) {
      final double mx = _snap63(1.0 - sx);
      if (findNearestNode(mx, sy, maxDist: 0.035) == null) {
        nodes.add(SandboxNodeDraft(
          type: type,
          x: mx,
          y: sy,
          param: defaultParamFor(
            type: type,
            x: mx,
            coreBus2x: coreBus2x,
            bufferDelay: bufferDelay,
          ),
        ));
      }
    }
    return primaryIdx;
  }

  /// Moves [nodeId] to `(newX, newY)` and updates side-dependent rail/inverter parameters.
  void moveNode(int nodeId, double newX, double newY) {
    if (nodeId < 0 || nodeId >= nodes.length) return;
    final SandboxNodeDraft n = nodes[nodeId];
    final double oldX = n.x;
    final double oldY = n.y;
    final int? mirrorId = (autoMirror && n.type != NodeType.busNode)
        ? _findMirroredTwin(nodeId, oldX, oldY)
        : null;

    n.x = n.type == NodeType.busNode ? 0.50 : _snap63(newX);
    n.y = _snap63(newY);
    if (n.type.isRail) {
      n.param = (n.x <= 0.50 ? ArenaSide.cyan : ArenaSide.amber).code;
    } else if (n.type.isInvertingGate) {
      n.param =
          ((n.x <= 0.50 ? ArenaSide.cyan : ArenaSide.amber).code) | 0x08;
    }

    if (mirrorId != null && mirrorId != nodeId && mirrorId < nodes.length) {
      final SandboxNodeDraft m = nodes[mirrorId];
      m.x = _snap63(1.0 - n.x);
      m.y = n.y;
      if (m.type.isRail) {
        m.param = (m.x <= 0.50 ? ArenaSide.cyan : ArenaSide.amber).code;
      } else if (m.type.isInvertingGate) {
        m.param =
            ((m.x <= 0.50 ? ArenaSide.cyan : ArenaSide.amber).code) | 0x08;
      }
    }
  }

  /// Toggles `1x`/`2x` Core weight on a Bus Node, or buffer delay (`2/4/8` ticks) on a Buffer.
  void cycleNodeParam(int nodeId) {
    if (nodeId < 0 || nodeId >= nodes.length) return;
    final SandboxNodeDraft n = nodes[nodeId];
    if (n.type == NodeType.busNode) {
      n.param = n.param == 2 ? 1 : 2;
    } else if (n.type == NodeType.buffer) {
      n.param = switch (n.param) {
        2 => 4,
        4 => 8,
        _ => 2,
      };
    } else if (n.type == NodeType.inputRail) {
      n.type = NodeType.burstRail;
    } else if (n.type == NodeType.burstRail) {
      n.type = NodeType.inputRail;
    }
  }

  /// Deletes [nodeId] (and its mirrored twin if [autoMirror] is active) and re-indexes edges.
  void deleteNode(int nodeId) {
    if (nodeId < 0 || nodeId >= nodes.length) return;
    final SandboxNodeDraft target = nodes[nodeId];
    final int? mirrorId = (autoMirror && target.type != NodeType.busNode)
        ? _findMirroredTwin(nodeId, target.x, target.y)
        : null;

    final List<int> toRemove = <int>[nodeId];
    if (mirrorId != null && mirrorId != nodeId) {
      toRemove.add(mirrorId);
    }
    toRemove.sort((a, b) => b.compareTo(a));
    for (final int idx in toRemove) {
      _removeSingleNode(idx);
    }
  }

  void _removeSingleNode(int idx) {
    if (idx < 0 || idx >= nodes.length) return;
    nodes.removeAt(idx);
    edges.removeWhere((e) => e.src == idx || e.dst == idx);
    for (final SandboxEdgeDraft e in edges) {
      if (e.src > idx) e.src--;
      if (e.dst > idx) e.dst--;
    }
  }

  /// Adds or removes a directed wire `(src -> dst)`. Returns a human-readable status message.
  String connectOrToggleWire({
    required int src,
    required int dst,
    int requestedPinRole = PinRole.standard,
  }) {
    if (src < 0 ||
        src >= nodes.length ||
        dst < 0 ||
        dst >= nodes.length ||
        src == dst) {
      return 'Select two distinct components to route a PCB trace.';
    }
    final SandboxNodeDraft srcNode = nodes[src];
    final SandboxNodeDraft dstNode = nodes[dst];
    if (dstNode.type.isRail) {
      return 'Input Rails cannot receive incoming wires (select the Rail first, then a Gate).';
    }
    if (srcNode.type == NodeType.busNode || srcNode.type == NodeType.deadEnd) {
      return '${srcNode.type.shortLabel} is a terminal sink and cannot drive downstream wires.';
    }

    final int existingIdx =
        edges.indexWhere((e) => e.src == src && e.dst == dst);
    if (existingIdx >= 0) {
      // If connecting to SR-Latch, cycle SET -> RESET -> Delete; otherwise delete wire.
      final SandboxEdgeDraft cur = edges[existingIdx];
      if (dstNode.type == NodeType.srLatch && cur.pinRole != PinRole.reset) {
        cur.pinRole = PinRole.reset;
        _mirrorWireUpdate(src, dst, mode: _MirrorWireOp.setReset);
        return 'Switched wire #$src → #$dst to SR-Latch RESET pin.';
      }
      edges.removeAt(existingIdx);
      _mirrorWireUpdate(src, dst, mode: _MirrorWireOp.remove);
      return 'Removed PCB trace #$src → #$dst.';
    }

    if (edges.length >= 250) {
      return 'Maximum wire count reached.';
    }

    final int role = dstNode.type == NodeType.srLatch
        ? (requestedPinRole == PinRole.reset ? PinRole.reset : PinRole.set)
        : PinRole.standard;
    edges.add(SandboxEdgeDraft(src: src, dst: dst, pinRole: role));
    _mirrorWireUpdate(src, dst, mode: _MirrorWireOp.add, pinRole: role);

    final String roleTag = dstNode.type == NodeType.srLatch
        ? (role == PinRole.reset ? ' (RESET)' : ' (SET)')
        : '';
    return 'Routed trace ${srcNode.type.shortLabel} #$src → ${dstNode.type.shortLabel} #$dst$roleTag.';
  }

  void _mirrorWireUpdate(
    int src,
    int dst, {
    required _MirrorWireOp mode,
    int pinRole = PinRole.standard,
  }) {
    if (!autoMirror) return;
    final int? mSrc = nodes[src].type == NodeType.busNode
        ? src
        : _findMirroredTwin(src, nodes[src].x, nodes[src].y);
    final int? mDst = nodes[dst].type == NodeType.busNode
        ? dst
        : _findMirroredTwin(dst, nodes[dst].x, nodes[dst].y);
    if (mSrc == null || mDst == null || (mSrc == src && mDst == dst)) return;
    if (mSrc == mDst) return;

    final int idx = edges.indexWhere((e) => e.src == mSrc && e.dst == mDst);
    switch (mode) {
      case _MirrorWireOp.add:
        if (idx < 0) {
          edges.add(SandboxEdgeDraft(src: mSrc, dst: mDst, pinRole: pinRole));
        }
      case _MirrorWireOp.setReset:
        if (idx >= 0) {
          edges[idx].pinRole = PinRole.reset;
        }
      case _MirrorWireOp.remove:
        if (idx >= 0) {
          edges.removeAt(idx);
        }
    }
  }

  /// Clears all interior gates & traces while preserving Input Rails and Central Bus nodes.
  void clearInteriorGates() {
    final List<SandboxNodeDraft> kept = nodes
        .where((n) => n.type.isRail || n.type == NodeType.busNode)
        .map((n) => n.clone())
        .toList();
    nodes
      ..clear()
      ..addAll(kept);
    edges.clear();
  }

  int? findNearestNode(double x, double y, {double maxDist = 0.055}) {
    int? best;
    double bestD2 = maxDist * maxDist;
    for (int i = 0; i < nodes.length; i++) {
      final double dx = nodes[i].x - x;
      final double dy = nodes[i].y - y;
      final double d2 = dx * dx + dy * dy;
      if (d2 <= bestD2) {
        bestD2 = d2;
        best = i;
      }
    }
    return best;
  }

  int? _findMirroredTwin(int sourceId, double x, double y) {
    final double targetX = 1.0 - x;
    int? best;
    double bestD2 = 0.042 * 0.042;
    for (int i = 0; i < nodes.length; i++) {
      if (i == sourceId) continue;
      if (nodes[i].type != nodes[sourceId].type) continue;
      final double dx = nodes[i].x - targetX;
      final double dy = nodes[i].y - y;
      final double d2 = dx * dx + dy * dy;
      if (d2 <= bestD2) {
        bestD2 = d2;
        best = i;
      }
    }
    return best;
  }

  /// Compiles the current draft into an immutable [ArenaTopology] with octilinear PCB wires.
  ArenaTopology buildTopology() {
    final ArenaTopologyBuilder b = ArenaTopologyBuilder(
      id: id,
      title: title,
      archetype: autoMirror
          ? BoardArchetype.mirrorSymmetric
          : BoardArchetype.prepHybrid,
      cyanInitialPulsers: cyanInitialPulsers,
      amberInitialPulsers: amberInitialPulsers,
      pulserBurnTicks: pulserBurnTicks,
      burstBurnTicks: burstBurnTicks,
      liveDurationTicks: liveDurationTicks,
      allowPrepPhase: allowPrepPhase,
    );

    for (final SandboxNodeDraft n in nodes) {
      b.addNode(type: n.type, x: n.x, y: n.y, param: n.param);
    }
    for (int i = 0; i < edges.length; i++) {
      final SandboxEdgeDraft e = edges[i];
      if (e.src >= 0 &&
          e.src < nodes.length &&
          e.dst >= 0 &&
          e.dst < nodes.length &&
          e.src != e.dst) {
        final double lane = ((i % 3) - 1) * 0.012;
        b.addOctilinearEdge(
          e.src,
          e.dst,
          pinRole: e.pinRole,
          laneOffset: lane,
        );
      }
    }
    return b.build();
  }

  /// Runs Sandbox-to-Arena validation, cycle-delay analysis, and URL hash encoding.
  SandboxValidationReport validate() {
    final ArenaTopology topo = buildTopology();
    final ({bool ok, String? error}) baseCheck =
        CircuitUrlCodec.validateSandboxCircuit(topo);
    final int? minCycle = FairnessValidator.computeMinCycleDelay(topo);

    int causalCyan = 0;
    for (final int r in topo.leftRails) {
      if (topo.canReachBus(r)) causalCyan++;
    }
    int causalAmber = 0;
    for (final int r in topo.rightRails) {
      if (topo.canReachBus(r)) causalAmber++;
    }

    if (!baseCheck.ok) {
      return SandboxValidationReport(
        ok: false,
        error: baseCheck.error,
        urlHash: null,
        minCycleDelay: minCycle,
        causalCyanRails: causalCyan,
        totalCyanRails: topo.leftRails.length,
        causalAmberRails: causalAmber,
        totalAmberRails: topo.rightRails.length,
      );
    }

    if (causalCyan == 0 || causalAmber == 0) {
      return SandboxValidationReport(
        ok: false,
        error:
            'Connect at least 1 Left Rail and 1 Right Rail to the Central Bus.',
        urlHash: null,
        minCycleDelay: minCycle,
        causalCyanRails: causalCyan,
        totalCyanRails: topo.leftRails.length,
        causalAmberRails: causalAmber,
        totalAmberRails: topo.rightRails.length,
      );
    }

    final String hash = CircuitUrlCodec.encodeUrlFragment(topo);
    return SandboxValidationReport(
      ok: true,
      error: null,
      urlHash: hash,
      minCycleDelay: minCycle,
      causalCyanRails: causalCyan,
      totalCyanRails: topo.leftRails.length,
      causalAmberRails: causalAmber,
      totalAmberRails: topo.rightRails.length,
    );
  }
}

enum _MirrorWireOp { add, setReset, remove }
