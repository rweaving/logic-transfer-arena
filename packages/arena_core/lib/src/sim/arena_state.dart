import 'dart:typed_data';

import '../math/xoshiro128pp.dart';
import 'arena_topology.dart';
import 'signal_types.dart';

/// Compact L1-cache-resident simulation snapshot (`< 400` bytes).
///
/// Cloning an [ArenaState] copies only two tiny typed arrays (`64B` + `256B`),
/// allowing AI lookahead rollouts to simulate 300+ ticks in microseconds.
final class ArenaState {
  int tick;
  MatchPhase phase;
  int phaseTicksRemaining;
  int overtimeIdleStreak;

  int cyanPulsersRemaining;
  int amberPulsersRemaining;

  /// Current tick output signal (`SignalState`) per node (`64` bytes).
  final Uint8List nodeOut;

  /// Double-buffer scratch space written during `ArenaSolver.step()` (`64` bytes).
  final Uint8List scratchOut;

  /// Bit-packed per-node internal state word (`64 * 4 = 256` bytes).
  final Uint32List nodeInternal;

  ArenaState._raw({
    required this.tick,
    required this.phase,
    required this.phaseTicksRemaining,
    required this.overtimeIdleStreak,
    required this.cyanPulsersRemaining,
    required this.amberPulsersRemaining,
    required this.nodeOut,
    required this.scratchOut,
    required this.nodeInternal,
  });

  /// Creates the initial state for [topology].
  factory ArenaState.initial(
    ArenaTopology topology, {
    MatchPhase startPhase = MatchPhase.liveCountdown,
  }) {
    final Uint8List out = Uint8List(ArenaTopology.maxSupportedNodes);
    final Uint8List scratch = Uint8List(ArenaTopology.maxSupportedNodes);
    final Uint32List internal = Uint32List(ArenaTopology.maxSupportedNodes);

    // Initialize pre-charged SR-Latches (used in 999 Boss encounters) and NOT gate initial outputs.
    for (int i = 0; i < topology.nodeCount; i++) {
      final NodeType t = topology.typeOf(i);
      final int param = topology.nodeParam[i];
      if (t == NodeType.srLatch &&
          (param == ArenaSide.cyan.code || param == ArenaSide.amber.code)) {
        internal[i] = param & 0x3;
        out[i] = param;
      } else if (t == NodeType.notGate &&
          (param == ArenaSide.cyan.code || param == ArenaSide.amber.code)) {
        out[i] = param;
      }
    }

    final int initialPhaseTicks = switch (startPhase) {
      MatchPhase.coinFlip => 40,
      MatchPhase.prepPhase => 100,
      MatchPhase.liveCountdown => topology.liveDurationTicks,
      MatchPhase.overtime => topology.maxOvertimeTicks,
      MatchPhase.finished => 0,
    };

    return ArenaState._raw(
      tick: 0,
      phase: startPhase,
      phaseTicksRemaining: initialPhaseTicks,
      overtimeIdleStreak: 0,
      cyanPulsersRemaining: topology.cyanInitialPulsers,
      amberPulsersRemaining: topology.amberInitialPulsers,
      nodeOut: out,
      scratchOut: scratch,
      nodeInternal: internal,
    );
  }

  /// Zero-GC-churn fast clone for AI rollouts and lockstep rollback ring buffers.
  ArenaState clone() => ArenaState._raw(
        tick: tick,
        phase: phase,
        phaseTicksRemaining: phaseTicksRemaining,
        overtimeIdleStreak: overtimeIdleStreak,
        cyanPulsersRemaining: cyanPulsersRemaining,
        amberPulsersRemaining: amberPulsersRemaining,
        nodeOut: Uint8List.fromList(nodeOut),
        scratchOut: Uint8List(ArenaTopology.maxSupportedNodes),
        nodeInternal: Uint32List.fromList(nodeInternal),
      );

  /// Copies state in-place from [other] without allocating.
  void copyFrom(ArenaState other) {
    tick = other.tick;
    phase = other.phase;
    phaseTicksRemaining = other.phaseTicksRemaining;
    overtimeIdleStreak = other.overtimeIdleStreak;
    cyanPulsersRemaining = other.cyanPulsersRemaining;
    amberPulsersRemaining = other.amberPulsersRemaining;
    nodeOut.setRange(0, nodeOut.length, other.nodeOut);
    nodeInternal.setRange(0, nodeInternal.length, other.nodeInternal);
  }

  int pulsersRemainingFor(ArenaSide side) =>
      side == ArenaSide.cyan ? cyanPulsersRemaining : amberPulsersRemaining;

  /// Remaining active burn ticks on a rail node (`0` if idle).
  int railRemainingBurnTicks(int railNodeId) =>
      (nodeInternal[railNodeId] >>> 2) & 0x3FF;

  /// Remaining thermal cooldown ticks after burnout (`0` if ready).
  int railCooldownTicks(int railNodeId) =>
      (nodeInternal[railNodeId] >>> 12) & 0xFF;

  /// Whether [side] can currently deploy a Pulser onto [railNodeId].
  bool canDeployOnRail(ArenaTopology topology, ArenaSide side, int railNodeId) {
    if (phase != MatchPhase.liveCountdown) return false;
    if (pulsersRemainingFor(side) <= 0) return false;
    if (railNodeId < 0 || railNodeId >= topology.nodeCount) return false;
    if (!topology.typeOf(railNodeId).isRail) return false;
    if (topology.nodeParam[railNodeId] != side.code) return false;
    return railRemainingBurnTicks(railNodeId) == 0 &&
        railCooldownTicks(railNodeId) == 0;
  }

  /// Remaining charge ticks on a Capacitor node (`0..60`).
  int capacitorChargeTicks(int nodeId) => (nodeInternal[nodeId] >>> 2) & 0x3FF;

  /// Stored owner of an SR-Latch Vault (`null` if Neutral).
  ArenaSide? latchStoredOwner(int nodeId) =>
      ArenaSide.fromCode(nodeInternal[nodeId] & 0x3);

  /// Whether a Clock Oscillator has been awakened.
  bool isClockAwake(int nodeId) => ((nodeInternal[nodeId] >>> 2) & 0x1) != 0;

  /// Decodes the current [BusNodeStatus] of a Central Bus node.
  BusNodeStatus busNodeStatus(int busNodeId) {
    final int word = nodeInternal[busNodeId];
    final int owner = word & 0x3;
    final bool clamped = ((word >>> 2) & 0x1) != 0;
    final bool contested = ((word >>> 3) & 0x1) != 0;
    if (contested) return BusNodeStatus.contested;
    if (owner == ArenaSide.cyan.code) {
      return clamped ? BusNodeStatus.clampedCyan : BusNodeStatus.softCyan;
    }
    if (owner == ArenaSide.amber.code) {
      return clamped ? BusNodeStatus.clampedAmber : BusNodeStatus.softAmber;
    }
    return BusNodeStatus.neutral;
  }

  /// Computes current weighted Central Bus score `(cyanPoints, amberPoints, neutralCount)`.
  ({int cyan, int amber, int neutral}) computeBusScore(ArenaTopology topology) {
    int cyan = 0;
    int amber = 0;
    int neutral = 0;
    for (int i = 0; i < topology.busNodes.length; i++) {
      final int nodeId = topology.busNodes[i];
      final int weight = topology.nodeParam[nodeId].clamp(1, 2);
      final BusNodeStatus status = busNodeStatus(nodeId);
      switch (status.scoringOwner) {
        case ArenaSide.cyan:
          cyan += weight;
        case ArenaSide.amber:
          amber += weight;
        case null:
          neutral++;
      }
    }
    return (cyan: cyan, amber: amber, neutral: neutral);
  }

  /// Deterministic 32-bit FNV-1a hash of the authoritative simulation state for PvP lockstep checks.
  int stateHash32(int nodeCount) {
    int h = 0x811C9DC5;
    h = Xoshiro128PlusPlus.fnv1a32(<int>[
      tick & 0xFF,
      (tick >>> 8) & 0xFF,
      phase.index,
      phaseTicksRemaining & 0xFF,
      (phaseTicksRemaining >>> 8) & 0xFF,
      cyanPulsersRemaining,
      amberPulsersRemaining,
    ], h);
    h = Xoshiro128PlusPlus.fnv1a32(nodeOut.sublist(0, nodeCount), h);
    final ByteData bd = nodeInternal.buffer.asByteData(
      nodeInternal.offsetInBytes,
      nodeCount * 4,
    );
    final List<int> internalBytes =
        List<int>.generate(nodeCount * 4, (int i) => bd.getUint8(i));
    return Xoshiro128PlusPlus.fnv1a32(internalBytes, h);
  }
}
