import 'dart:typed_data';

import 'package:arena_core/arena_core.dart';
import 'package:arena_protocol/arena_protocol.dart';

import 'arena_ws.dart';

enum OnlineRoomStage {
  disconnected,
  connecting,
  waitingForOpponent,
  inPrepPhase,
  inLiveMatch,
  roundSummary,
  error,
}

/// Manages 1v1 WebSocket Room lifecycle, Pre-Round Gate Prep sync,
/// 4-byte binary Lockstep input relay, `FNV-1a` hash checks, and optional
/// real-WebSocket Bot Challenger peer for solo testing.
final class OnlinePvpCoordinator {
  PlatformWsClient? _socket;
  PlatformWsClient? _botSocket;
  LockstepSession? _botSession;
  DroidProbeController? _botAi;
  bool _botSentReady = false;

  OnlineRoomStage stage = OnlineRoomStage.disconnected;
  String roomCode = '';
  String wsBaseUrl = ArenaWsTransport.defaultWsBase();
  ArenaSide localSide = ArenaSide.cyan;
  int playersConnected = 0;

  int roundNumber = 1;
  int cyanWins = 0;
  int amberWins = 0;
  ArenaSide? loserPicksNext;
  ArenaSide? seriesWinner;

  bool cyanPrepReady = false;
  bool amberPrepReady = false;
  bool desyncDetected = false;
  bool roundResultReported = false;
  int lastRttMs = 0;
  String statusMessage = 'Disconnected';

  LockstepSession? session;

  final void Function(ArenaTopology topology, ArenaState state) onMatchStarted;
  final void Function(ArenaTopology topology, PrepEditEvent edit)
      onPrepEditApplied;
  final void Function() onLiveRoundStarted;
  final void Function() onStateChanged;

  OnlinePvpCoordinator({
    required this.onMatchStarted,
    required this.onPrepEditApplied,
    required this.onLiveRoundStarted,
    required this.onStateChanged,
  });

  bool get isActive =>
      stage != OnlineRoomStage.disconnected && stage != OnlineRoomStage.error;

  bool get localPrepReady =>
      localSide == ArenaSide.cyan ? cyanPrepReady : amberPrepReady;

  bool get hasBotChallenger => _botSocket != null;

  static BoardArchetype _parseArchetype(String? name) => switch (name) {
        'pointSymmetric' => BoardArchetype.pointSymmetric,
        'latchHeavy' => BoardArchetype.latchHeavy,
        'prepHybrid' => BoardArchetype.prepHybrid,
        _ => BoardArchetype.mirrorSymmetric,
      };

  static ArenaTopology _buildSharedMatchBoard(Map<String, Object?> msg) {
    final String? customHash = msg['customUrlHash'] as String?;
    if (customHash != null && customHash.startsWith('#arena=v1.')) {
      try {
        return CircuitUrlCodec.decodeUrlFragment(customHash);
      } catch (_) {}
    }
    final int seedLo = (msg['seedLo'] as num?)?.toInt() ?? 0x12345678;
    final int seedHi = (msg['seedHi'] as num?)?.toInt() ?? 0x9ABCDEF0;
    final BoardArchetype arch = _parseArchetype(msg['archetype'] as String?);
    return ProceduralGenerator.generate(
      seedLo: seedLo,
      seedHi: seedHi,
      archetype: arch,
      customTitle: '1v1 Duel Sector • Round ${msg['round'] ?? 1}',
    );
  }

  /// Creates a fresh 4-letter Room Code via `/api/rooms` and connects immediately.
  Future<void> hostNewRoom({String? customBoardHash}) async {
    final String code = await ArenaWsTransport.createOrGenerateRoomCode();
    connectToRoom(code, customBoardHash: customBoardHash);
  }

  /// Connects to an existing or new 4-letter Room Code over WebSocket.
  void connectToRoom(String code, {String? customBoardHash}) {
    disconnect();
    final String cleanCode = code.trim().toUpperCase();
    if (cleanCode.length < 3) {
      stage = OnlineRoomStage.error;
      statusMessage = 'Room code must be at least 3 characters.';
      onStateChanged();
      return;
    }

    roomCode = cleanCode;
    stage = OnlineRoomStage.connecting;
    desyncDetected = false;
    statusMessage = 'Connecting to room $roomCode...';
    onStateChanged();

    _socket = ArenaWsTransport.connectRoom(
      roomCode: roomCode,
      wsBase: wsBaseUrl,
      customBoardHash: customBoardHash,
      onOpen: () {
        sendPing();
        onStateChanged();
      },
      onText: _handleServerJson,
      onBinary: _handleServerBinary,
      onClose: () {
        if (stage != OnlineRoomStage.disconnected &&
            stage != OnlineRoomStage.error) {
          stage = OnlineRoomStage.disconnected;
          statusMessage = 'Room $roomCode connection closed.';
          onStateChanged();
        }
      },
      onError: (String err) {
        stage = OnlineRoomStage.error;
        statusMessage = 'Connection error: $err';
        onStateChanged();
      },
    );
  }

  /// Spawns a real second WebSocket peer into the current room (`Unit 742` Bot)
  /// so a single player can test full WebSocket matchmaking + binary lockstep solo!
  void spawnSocketBotChallenger() {
    if (_botSocket != null || roomCode.isEmpty) return;
    _botSentReady = false;
    _botSocket = ArenaWsTransport.connectRoom(
      roomCode: roomCode,
      wsBase: wsBaseUrl,
      onOpen: () {},
      onText: _handleBotJson,
      onBinary: _handleBotBinary,
      onClose: () {
        _botSocket = null;
        _botSession = null;
        _botAi = null;
      },
      onError: (_) {
        _botSocket = null;
      },
    );
    statusMessage = 'Spawned WebSocket Challenger Bot in room $roomCode...';
    onStateChanged();
  }

  void sendPing() {
    _socket?.sendText(WireFrameCodec.encodeControlJson(<String, Object?>{
      'type': 'PING',
      'clientTs': DateTime.now().millisecondsSinceEpoch,
    }));
  }

  void sendPrepGateSwap(int nodeId, NodeType newType) {
    if (stage != OnlineRoomStage.inPrepPhase) return;
    _socket?.sendBytes(
      WireFrameCodec.encodeCmdPrepGate(nodeId: nodeId, newType: newType),
    );
  }

  void sendPrepJumperWire(int srcNode, int dstNode, {int pinRole = PinRole.standard}) {
    if (stage != OnlineRoomStage.inPrepPhase) return;
    _socket?.sendBytes(
      WireFrameCodec.encodeCmdPrepWire(
        srcNode: srcNode,
        dstNode: dstNode,
        pinRole: pinRole,
      ),
    );
  }

  void sendPrepReady({bool ready = true}) {
    if (stage != OnlineRoomStage.inPrepPhase) return;
    _socket?.sendBytes(WireFrameCodec.encodeCmdPrepReady(ready: ready));
  }

  void sendDeployRailIndex(int clientTick, int railIndex) {
    if (stage != OnlineRoomStage.inLiveMatch) return;
    _socket?.sendBytes(
      WireFrameCodec.encodeCmdDeploy(
        clientTick: clientTick,
        railIndex: railIndex,
      ),
    );
  }

  void sendHashCheck(int tick, int hash32) {
    _socket?.sendBytes(
      WireFrameCodec.encodeHashCheck(tick: tick, stateHash32: hash32),
    );
  }

  void reportRoundFinished({required int cyanPoints, required int amberPoints}) {
    if (roundResultReported) return;
    roundResultReported = true;
    _socket?.sendText(WireFrameCodec.encodeControlJson(<String, Object?>{
      'type': 'ROUND_RESULT',
      'cyanPoints': cyanPoints,
      'amberPoints': amberPoints,
    }));
  }

  void sendLoserArchetypePick(BoardArchetype pick) {
    _socket?.sendText(WireFrameCodec.encodeControlJson(<String, Object?>{
      'type': 'LOSER_PICK_ARCHETYPE',
      'archetype': pick.name,
    }));
  }

  void requestRematch() {
    _socket?.sendText(WireFrameCodec.encodeControlJson(<String, Object?>{
      'type': 'REQUEST_REMATCH',
    }));
  }

  /// Steps any attached WebSocket Bot peer by 1 simulation tick (`50ms`).
  void stepAttachedBotTick() {
    final PlatformWsClient? bWs = _botSocket;
    final LockstepSession? bSes = _botSession;
    if (bWs == null || !bWs.isOpen || bSes == null) return;

    if (bSes.liveState.phase == MatchPhase.prepPhase) {
      if (bSes.liveState.phaseTicksRemaining == 165) {
        for (int i = 0; i < bSes.topology.nodeCount; i++) {
          if (bSes.topology.configurableSideOf(i) == ArenaSide.amber) {
            bWs.sendBytes(WireFrameCodec.encodeCmdPrepGate(
              nodeId: i,
              newType: NodeType.nandGate,
            ));
            break;
          }
        }
      }
      if (bSes.liveState.phaseTicksRemaining <= 140 && !_botSentReady) {
        _botSentReady = true;
        bWs.sendBytes(WireFrameCodec.encodeCmdPrepReady(ready: true));
      }
      if (bSes.liveState.phaseTicksRemaining > 1) {
        bSes.liveState.phaseTicksRemaining--;
      }
      return;
    }

    if (bSes.liveState.phase == MatchPhase.liveCountdown && _botAi != null) {
      final int? targetRailNode = _botAi!.updateTick(bSes.liveState);
      if (targetRailNode != null) {
        final Uint8List rails = bSes.topology.railsFor(ArenaSide.amber);
        final int rIdx = rails.indexOf(targetRailNode);
        if (rIdx >= 0) {
          bWs.sendBytes(WireFrameCodec.encodeCmdDeploy(
            clientTick: bSes.currentTick,
            railIndex: rIdx,
          ));
        }
      }
    }

    if (bSes.liveState.phase != MatchPhase.finished) {
      bSes.stepTick();
      if (bSes.currentTick > 0 && bSes.currentTick % 20 == 0) {
        bWs.sendBytes(WireFrameCodec.encodeHashCheck(
          tick: bSes.currentTick,
          stateHash32: bSes.computeStateHash(),
        ));
      }
    }
  }

  void _handleServerJson(String raw) {
    final Map<String, Object?> msg = WireFrameCodec.decodeControlJson(raw);
    final String? type = msg['type'] as String?;

    switch (type) {
      case 'PONG':
        final int? sent = (msg['clientTs'] as num?)?.toInt();
        if (sent != null) {
          lastRttMs =
              (DateTime.now().millisecondsSinceEpoch - sent).clamp(0, 9999);
        }
      case 'WELCOME':
        localSide =
            (msg['side'] == 'amber') ? ArenaSide.amber : ArenaSide.cyan;
        playersConnected = (msg['playersConnected'] as num?)?.toInt() ?? 1;
        if (playersConnected < 2) {
          stage = OnlineRoomStage.waitingForOpponent;
          statusMessage =
              'Room $roomCode ready — Share code $roomCode or spawn Bot Challenger.';
        }
        onStateChanged();
      case 'ROOM_STATUS':
        playersConnected =
            (msg['playersConnected'] as num?)?.toInt() ?? playersConnected;
        onStateChanged();
      case 'MATCH_START':
        roundNumber = (msg['round'] as num?)?.toInt() ?? 1;
        cyanWins = (msg['cyanWins'] as num?)?.toInt() ?? 0;
        amberWins = (msg['amberWins'] as num?)?.toInt() ?? 0;
        cyanPrepReady = false;
        amberPrepReady = false;
        desyncDetected = false;
        roundResultReported = false;
        seriesWinner = null;
        loserPicksNext = null;

        final ArenaTopology board = _buildSharedMatchBoard(msg);
        final int prepTicks =
            (msg['prepDurationTicks'] as num?)?.toInt() ?? 200;
        session = LockstepSession(
          board,
          startPhase: MatchPhase.prepPhase,
          initialPhaseTicks: prepTicks,
        );
        stage = OnlineRoomStage.inPrepPhase;
        statusMessage =
            'Room $roomCode • Round $roundNumber • Configure ${localSide.name.toUpperCase()} gates!';
        onMatchStarted(session!.topology, session!.liveState);
        onStateChanged();
      case 'PREP_READY_STATE':
        cyanPrepReady = msg['cyanReady'] == true;
        amberPrepReady = msg['amberReady'] == true;
        onStateChanged();
      case 'LIVE_ROUND_START':
        if (session != null) {
          session!.lockInLiveStart();
          stage = OnlineRoomStage.inLiveMatch;
          statusMessage =
              'LIVE 1v1 LOCKSTEP • Playing as ${localSide.name.toUpperCase()}';
          onLiveRoundStarted();
          onStateChanged();
        }
      case 'ROUND_SUMMARY':
        cyanWins = (msg['cyanWins'] as num?)?.toInt() ?? cyanWins;
        amberWins = (msg['amberWins'] as num?)?.toInt() ?? amberWins;
        final String? loserStr = msg['loserPicksNext'] as String?;
        loserPicksNext = loserStr == 'cyan'
            ? ArenaSide.cyan
            : (loserStr == 'amber' ? ArenaSide.amber : null);
        final String? winStr = msg['matchWinner'] as String?;
        seriesWinner = winStr == 'cyan'
            ? ArenaSide.cyan
            : (winStr == 'amber' ? ArenaSide.amber : null);
        stage = OnlineRoomStage.roundSummary;
        onStateChanged();
      case 'OPPONENT_DISCONNECTED':
        playersConnected = 1;
        stage = OnlineRoomStage.waitingForOpponent;
        statusMessage = 'Opponent disconnected — waiting in room $roomCode.';
        onStateChanged();
    }
  }

  void _handleServerBinary(Uint8List bytes) {
    if (bytes.isEmpty || session == null) return;
    final int op = bytes[0];
    if (op == LockstepOpcode.evtPrepApplied && bytes.length >= 5) {
      final PrepEditEvent edit = PrepEditEvent.fromBinaryFrame(bytes);
      if (session!.applyPrepEdit(edit)) {
        onPrepEditApplied(session!.topology, edit);
      }
    } else if (op == LockstepOpcode.evtInput && bytes.length >= 4) {
      final ScheduledInputEvent ev = ScheduledInputEvent.fromBinaryFrame(bytes);
      session!.ingestAuthoritativeEvent(ev);
    } else if (op == LockstepOpcode.desyncAlert) {
      desyncDetected = true;
      onStateChanged();
    }
  }

  void _handleBotJson(String raw) {
    final Map<String, Object?> msg = WireFrameCodec.decodeControlJson(raw);
    final String? type = msg['type'] as String?;
    if (type == 'MATCH_START') {
      final ArenaTopology board = _buildSharedMatchBoard(msg);
      final int prepTicks = (msg['prepDurationTicks'] as num?)?.toInt() ?? 200;
      _botSentReady = false;
      _botSession = LockstepSession(
        board,
        startPhase: MatchPhase.prepPhase,
        initialPhaseTicks: prepTicks,
      );
      _botAi = DroidProbeController(
        side: ArenaSide.amber,
        persona: DroidPersona.forCode(742),
        profile: BoardTacticalProfile.analyze(board),
        rng: Xoshiro128PlusPlus.fromSeed(board.id.hashCode, 742),
      );
    } else if (type == 'LIVE_ROUND_START' && _botSession != null) {
      _botSession!.lockInLiveStart();
      _botAi = DroidProbeController(
        side: ArenaSide.amber,
        persona: DroidPersona.forCode(742),
        profile: BoardTacticalProfile.analyze(_botSession!.topology),
        rng: Xoshiro128PlusPlus.fromSeed(_botSession!.topology.id.hashCode, 742),
      );
    } else if (type == 'ROUND_SUMMARY' &&
        msg['loserPicksNext'] == 'amber' &&
        msg['matchWinner'] == null) {
      _botSocket?.sendText(WireFrameCodec.encodeControlJson(<String, Object?>{
        'type': 'LOSER_PICK_ARCHETYPE',
        'archetype': 'latchHeavy',
      }));
    }
  }

  void _handleBotBinary(Uint8List bytes) {
    if (bytes.isEmpty || _botSession == null) return;
    final int op = bytes[0];
    if (op == LockstepOpcode.evtPrepApplied && bytes.length >= 5) {
      _botSession!.applyPrepEdit(PrepEditEvent.fromBinaryFrame(bytes));
    } else if (op == LockstepOpcode.evtInput && bytes.length >= 4) {
      _botSession!
          .ingestAuthoritativeEvent(ScheduledInputEvent.fromBinaryFrame(bytes));
    }
  }

  void disconnect() {
    _botSocket?.close();
    _botSocket = null;
    _botSession = null;
    _botAi = null;
    _socket?.close();
    _socket = null;
    session = null;
    stage = OnlineRoomStage.disconnected;
    playersConnected = 0;
  }
}
