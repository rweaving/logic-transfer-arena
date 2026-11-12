library arena_protocol;

import 'dart:convert';
import 'dart:typed_data';

import 'package:arena_core/arena_core.dart';

/// Binary hot-path opcodes exchanged over WebSockets / WebRTC DataChannels.
abstract final class LockstepOpcode {
  /// Client -> Server (`4` bytes): `[0x01, clientTickHi, clientTickLo, railIndex]`.
  static const int cmdDeploy = 0x01;

  /// Server -> Clients (`4` bytes): `[0x02, execTickHi, execTickLo, (sideCode << 6) | railIndex]`.
  static const int evtInput = 0x02;

  /// Client <-> Server (`7` bytes): `[0x03, tickHi, tickLo, h3, h2, h1, h0]`.
  static const int hashCheck = 0x03;

  /// Server -> Clients (`3` bytes): `[0x04, tickHi, tickLo]` when hashes diverge.
  static const int desyncAlert = 0x04;

  /// Client -> Server (`3` bytes): `[0x05, nodeId, newNodeTypeIndex]` during Pre-Round Gate Prep.
  static const int cmdPrepGate = 0x05;

  /// Client -> Server (`4` bytes): `[0x06, srcNodeId, dstNodeId, pinRole]` during Pre-Round Gate Prep.
  static const int cmdPrepWire = 0x06;

  /// Server -> Clients (`5` bytes): `[0x07, kind(0=gate,1=wire), sideCode, a, b | (pinRole << 6)]`.
  static const int evtPrepApplied = 0x07;

  /// Client -> Server (`2` bytes): `[0x08, ready(0|1)]` lock-in during Pre-Round Countdown.
  static const int cmdPrepReady = 0x08;
}

/// Kind of Pre-Round circuit configuration action synchronized across 1v1 peers.
enum PrepEditKind {
  gateSwap(0),
  jumperWire(1);

  const PrepEditKind(this.code);
  final int code;

  static PrepEditKind fromCode(int c) =>
      c == 1 ? PrepEditKind.jumperWire : PrepEditKind.gateSwap;
}

/// Authoritative Pre-Round Gate/Jumper configuration event broadcast by the room.
final class PrepEditEvent {
  final PrepEditKind kind;
  final ArenaSide side;
  final int nodeOrSrc;
  final int typeOrDst;
  final int pinRole;

  PrepEditEvent.gate({
    required this.side,
    required int nodeId,
    required NodeType newType,
  })  : kind = PrepEditKind.gateSwap,
        nodeOrSrc = nodeId,
        typeOrDst = newType.index,
        pinRole = PinRole.standard;

  const PrepEditEvent.wire({
    required this.side,
    required int srcNode,
    required int dstNode,
    this.pinRole = PinRole.standard,
  })  : kind = PrepEditKind.jumperWire,
        nodeOrSrc = srcNode,
        typeOrDst = dstNode;

  NodeType get gateType =>
      NodeType.values[typeOrDst.clamp(0, NodeType.values.length - 1)];

  Uint8List toBinaryFrame() {
    final Uint8List buf = Uint8List(5);
    buf[0] = LockstepOpcode.evtPrepApplied;
    buf[1] = kind.code & 0x01;
    buf[2] = side.code & 0x03;
    buf[3] = nodeOrSrc & 0x3F;
    buf[4] = (typeOrDst & 0x3F) | ((pinRole & 0x03) << 6);
    return buf;
  }

  static PrepEditEvent fromBinaryFrame(Uint8List bytes) {
    if (bytes.length < 5 || bytes[0] != LockstepOpcode.evtPrepApplied) {
      throw const FormatException('Invalid EVT_PREP_APPLIED binary frame.');
    }
    final PrepEditKind kind = PrepEditKind.fromCode(bytes[1] & 0x01);
    final ArenaSide? side = ArenaSide.fromCode(bytes[2] & 0x03);
    if (side == null) {
      throw FormatException('Invalid side code in EVT_PREP_APPLIED: ${bytes[2]}');
    }
    final int a = bytes[3] & 0x3F;
    final int b = bytes[4] & 0x3F;
    final int role = (bytes[4] >>> 6) & 0x03;
    if (kind == PrepEditKind.gateSwap) {
      if (b >= NodeType.values.length) {
        throw FormatException('Invalid gate type index in EVT_PREP_APPLIED: $b');
      }
      return PrepEditEvent.gate(
        side: side,
        nodeId: a,
        newType: NodeType.values[b],
      );
    }
    return PrepEditEvent.wire(
      side: side,
      srcNode: a,
      dstNode: b,
      pinRole: role,
    );
  }
}

/// Authoritative timestamped rail deployment event.
final class ScheduledInputEvent {
  final int executeTick;
  final ArenaSide side;
  final int railIndex;

  const ScheduledInputEvent({
    required this.executeTick,
    required this.side,
    required this.railIndex,
  });

  /// Encodes `EVT_INPUT` into a 4-byte binary frame.
  Uint8List toBinaryFrame() {
    final Uint8List buf = Uint8List(4);
    buf[0] = LockstepOpcode.evtInput;
    buf[1] = (executeTick >>> 8) & 0xFF;
    buf[2] = executeTick & 0xFF;
    buf[3] = ((side.code & 0x3) << 6) | (railIndex & 0x3F);
    return buf;
  }

  static ScheduledInputEvent fromBinaryFrame(Uint8List bytes) {
    if (bytes.length < 4 || bytes[0] != LockstepOpcode.evtInput) {
      throw const FormatException('Invalid EVT_INPUT binary frame.');
    }
    final int tick = (bytes[1] << 8) | bytes[2];
    final int sideCode = (bytes[3] >>> 6) & 0x3;
    final int railIdx = bytes[3] & 0x3F;
    final ArenaSide? side = ArenaSide.fromCode(sideCode);
    if (side == null) {
      throw FormatException('Invalid side code in EVT_INPUT: $sideCode');
    }
    return ScheduledInputEvent(
      executeTick: tick,
      side: side,
      railIndex: railIdx,
    );
  }
}

/// Encodes/decodes compact binary and JSON control frames for 1v1 PvP rooms.
abstract final class WireFrameCodec {
  static Uint8List encodeCmdDeploy({
    required int clientTick,
    required int railIndex,
  }) {
    final Uint8List buf = Uint8List(4);
    buf[0] = LockstepOpcode.cmdDeploy;
    buf[1] = (clientTick >>> 8) & 0xFF;
    buf[2] = clientTick & 0xFF;
    buf[3] = railIndex & 0x3F;
    return buf;
  }

  static ({int clientTick, int railIndex}) decodeCmdDeploy(Uint8List bytes) {
    if (bytes.length < 4 || bytes[0] != LockstepOpcode.cmdDeploy) {
      throw const FormatException('Invalid CMD_DEPLOY frame.');
    }
    return (
      clientTick: (bytes[1] << 8) | bytes[2],
      railIndex: bytes[3] & 0x3F,
    );
  }

  static Uint8List encodeCmdPrepGate({
    required int nodeId,
    required NodeType newType,
  }) {
    final Uint8List buf = Uint8List(3);
    buf[0] = LockstepOpcode.cmdPrepGate;
    buf[1] = nodeId & 0x3F;
    buf[2] = newType.index & 0x3F;
    return buf;
  }

  static ({int nodeId, NodeType newType}) decodeCmdPrepGate(Uint8List bytes) {
    if (bytes.length < 3 || bytes[0] != LockstepOpcode.cmdPrepGate) {
      throw const FormatException('Invalid CMD_PREP_GATE frame.');
    }
    final int idx = bytes[2] & 0x3F;
    if (idx >= NodeType.values.length) {
      throw FormatException('Invalid NodeType index in CMD_PREP_GATE: $idx');
    }
    return (nodeId: bytes[1] & 0x3F, newType: NodeType.values[idx]);
  }

  static Uint8List encodeCmdPrepWire({
    required int srcNode,
    required int dstNode,
    int pinRole = PinRole.standard,
  }) {
    final Uint8List buf = Uint8List(4);
    buf[0] = LockstepOpcode.cmdPrepWire;
    buf[1] = srcNode & 0x3F;
    buf[2] = dstNode & 0x3F;
    buf[3] = pinRole & 0x03;
    return buf;
  }

  static ({int srcNode, int dstNode, int pinRole}) decodeCmdPrepWire(
    Uint8List bytes,
  ) {
    if (bytes.length < 4 || bytes[0] != LockstepOpcode.cmdPrepWire) {
      throw const FormatException('Invalid CMD_PREP_WIRE frame.');
    }
    return (
      srcNode: bytes[1] & 0x3F,
      dstNode: bytes[2] & 0x3F,
      pinRole: bytes[3] & 0x03,
    );
  }

  static Uint8List encodeCmdPrepReady({bool ready = true}) {
    final Uint8List buf = Uint8List(2);
    buf[0] = LockstepOpcode.cmdPrepReady;
    buf[1] = ready ? 1 : 0;
    return buf;
  }

  static bool decodeCmdPrepReady(Uint8List bytes) {
    if (bytes.length < 2 || bytes[0] != LockstepOpcode.cmdPrepReady) {
      throw const FormatException('Invalid CMD_PREP_READY frame.');
    }
    return bytes[1] != 0;
  }

  static Uint8List encodeHashCheck({
    required int tick,
    required int stateHash32,
  }) {
    final Uint8List buf = Uint8List(7);
    buf[0] = LockstepOpcode.hashCheck;
    buf[1] = (tick >>> 8) & 0xFF;
    buf[2] = tick & 0xFF;
    buf[3] = (stateHash32 >>> 24) & 0xFF;
    buf[4] = (stateHash32 >>> 16) & 0xFF;
    buf[5] = (stateHash32 >>> 8) & 0xFF;
    buf[6] = stateHash32 & 0xFF;
    return buf;
  }

  static ({int tick, int stateHash32}) decodeHashCheck(Uint8List bytes) {
    if (bytes.length < 7 || bytes[0] != LockstepOpcode.hashCheck) {
      throw const FormatException('Invalid HASH_CHECK frame.');
    }
    final int tick = (bytes[1] << 8) | bytes[2];
    final int hash = ((bytes[3] << 24) |
            (bytes[4] << 16) |
            (bytes[5] << 8) |
            bytes[6]) &
        0xFFFFFFFF;
    return (tick: tick, stateHash32: hash);
  }

  static String encodeControlJson(Map<String, Object?> payload) =>
      jsonEncode(payload);

  static Map<String, Object?> decodeControlJson(String text) =>
      (jsonDecode(text) as Map<String, dynamic>).cast<String, Object?>();
}

/// Deterministic lockstep session manager with Pre-Round Prep application,
/// 2-tick input buffer, and 32-tick rollback ring.
///
/// Guarantees identical state hashes between two networked peers even under
/// `80ms +/- 40ms` jitter and out-of-order packet arrival.
final class LockstepSession {
  static const int snapshotWindow = 32;
  static const int defaultInputDelayTicks = 2;

  ArenaTopology topology;
  final ArenaState liveState;

  final List<ArenaState> _ringSnapshots;
  final Int32List _ringTicks;
  final Map<int, List<ScheduledInputEvent>> _eventsByTick =
      <int, List<ScheduledInputEvent>>{};

  LockstepSession(
    this.topology, {
    MatchPhase startPhase = MatchPhase.liveCountdown,
    int? initialPhaseTicks,
  })  : liveState = ArenaState.initial(topology, startPhase: startPhase),
        _ringSnapshots = List<ArenaState>.generate(
          snapshotWindow,
          (_) => ArenaState.initial(topology, startPhase: startPhase),
          growable: false,
        ),
        _ringTicks = Int32List(snapshotWindow)..fillRange(0, snapshotWindow, -1) {
    if (initialPhaseTicks != null) {
      liveState.phaseTicksRemaining = initialPhaseTicks;
    }
    _saveSnapshot(liveState);
  }

  int get currentTick => liveState.tick;

  /// Applies an authoritative Pre-Round Gate or Jumper edit identically on both peers.
  bool applyPrepEdit(PrepEditEvent edit) {
    if (liveState.phase != MatchPhase.prepPhase && liveState.tick > 0) {
      return false;
    }
    ArenaTopology? next;
    if (edit.kind == PrepEditKind.gateSwap) {
      next = topology.tryConfigureGate(
        side: edit.side,
        nodeId: edit.nodeOrSrc,
        newType: edit.gateType,
      );
    } else {
      next = topology.tryAddHomeJumper(
        side: edit.side,
        srcNode: edit.nodeOrSrc,
        dstNode: edit.typeOrDst,
        pinRole: edit.pinRole,
      );
    }
    if (next == null) return false;
    topology = next;
    _saveSnapshot(liveState);
    return true;
  }

  /// Transitions from `MatchPhase.prepPhase` into tick `0` of `MatchPhase.liveCountdown`.
  void lockInLiveStart() {
    liveState.phase = MatchPhase.liveCountdown;
    liveState.phaseTicksRemaining = topology.liveDurationTicks;
    liveState.tick = 0;
    _eventsByTick.clear();
    _ringTicks.fillRange(0, snapshotWindow, -1);
    _saveSnapshot(liveState);
  }

  /// Records an authoritative [event]; if `event.executeTick < liveState.tick`,
  /// seamlessly rolls back to the saved snapshot at `executeTick` and re-simulates!
  bool ingestAuthoritativeEvent(
    ScheduledInputEvent event, {
    List<SimEvent>? simEvents,
  }) {
    final List<ScheduledInputEvent> list = _eventsByTick.putIfAbsent(
      event.executeTick,
      () => <ScheduledInputEvent>[],
    );

    // Deduplicate identical frames and maintain canonical ordering (Cyan before Amber, then railIdx).
    final bool exists = list.any((e) =>
        e.side == event.side &&
        e.railIndex == event.railIndex &&
        e.executeTick == event.executeTick);
    if (exists) return true;

    list.add(event);
    list.sort((a, b) {
      final int sc = a.side.code.compareTo(b.side.code);
      return sc != 0 ? sc : a.railIndex.compareTo(b.railIndex);
    });

    if (event.executeTick >= liveState.tick) {
      return true;
    }

    // Late packet arrived: rewind to `event.executeTick` from ring buffer and re-forward!
    final int targetTick = event.executeTick;
    final int slot = targetTick % snapshotWindow;
    if (_ringTicks[slot] != targetTick) {
      return false;
    }

    final int restoreTargetTick = liveState.tick;
    liveState.copyFrom(_ringSnapshots[slot]);
    while (liveState.tick < restoreTargetTick &&
        liveState.phase != MatchPhase.finished) {
      stepTick(simEvents: simEvents);
    }
    return true;
  }

  /// Advances the lockstep simulation by 1 tick (`50ms`), applying all scheduled inputs.
  void stepTick({List<SimEvent>? simEvents}) {
    final int t = liveState.tick;
    _saveSnapshot(liveState);

    final List<ScheduledInputEvent>? due = _eventsByTick[t];
    if (due != null) {
      for (final ScheduledInputEvent ev in due) {
        final Uint8List sideRails = topology.railsFor(ev.side);
        if (ev.railIndex >= 0 && ev.railIndex < sideRails.length) {
          ArenaSolver.deployPulser(
            topology,
            liveState,
            ev.side,
            sideRails[ev.railIndex],
            events: simEvents,
          );
        }
      }
    }

    ArenaSolver.step(topology, liveState, events: simEvents);
    _saveSnapshot(liveState);

    _eventsByTick.remove(t - snapshotWindow - 2);
  }

  int computeStateHash() => liveState.stateHash32(topology.nodeCount);

  void _saveSnapshot(ArenaState s) {
    final int slot = s.tick % snapshotWindow;
    _ringSnapshots[slot].copyFrom(s);
    _ringTicks[slot] = s.tick;
  }
}
