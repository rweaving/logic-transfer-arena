import 'dart:ui' as ui;

import 'package:arena_core/arena_core.dart';
import 'package:arena_protocol/arena_protocol.dart';
import 'package:flutter/foundation.dart';

import '../audio/arena_synth.dart';
import '../net/online_pvp_coordinator.dart';
import '../render/spark_particle_pool.dart';

enum ArenaGameMode {
  aiLadder,
  dailyUnderdog,
  localHotseat,
  bestOfFiveDuel,
  onlinePvp,
  sandboxBuilder,
  customSandboxHash,
}

/// Tool active in the Pre-Round Logic Gate Configuration palette.
enum PrepTool {
  cycleGate('CYCLE'),
  andGate('AND'),
  orGate('OR'),
  xorGate('XOR'),
  nandGate('NAND'),
  norGate('NOR'),
  notGate('NOT'),
  bufferGate('BUF'),
  jumperWire('+WIRE');

  const PrepTool(this.label);
  final String label;

  NodeType? get targetNodeType => switch (this) {
        PrepTool.cycleGate || PrepTool.jumperWire => null,
        PrepTool.andGate => NodeType.andGate,
        PrepTool.orGate => NodeType.orGate,
        PrepTool.xorGate => NodeType.xorGate,
        PrepTool.nandGate => NodeType.nandGate,
        PrepTool.norGate => NodeType.norGate,
        PrepTool.notGate => NodeType.notGate,
        PrepTool.bufferGate => NodeType.buffer,
      };
}

/// Interactive tool active in the Custom Sandbox Circuit Editor (`Sandbox -> Arena Bridge`).
enum SandboxTool {
  wireTrace('WIRE', null),
  moveEdit('MOVE/PARAM', null),
  eraser('DELETE', null),
  placeAnd('AND', NodeType.andGate),
  placeOr('OR', NodeType.orGate),
  placeXor('XOR', NodeType.xorGate),
  placeNand('NAND', NodeType.nandGate),
  placeNor('NOR', NodeType.norGate),
  placeNot('NOT', NodeType.notGate),
  placeBuf('BUF', NodeType.buffer),
  placeSplit('SPL', NodeType.splitter),
  placeLatch('S·R', NodeType.srLatch),
  placeCap('CAP', NodeType.capacitor),
  placeClock('CLK', NodeType.clockOscillator),
  placeRail('RAIL', NodeType.inputRail),
  placeBus('BUS', NodeType.busNode);

  const SandboxTool(this.label, this.placeType);
  final String label;
  final NodeType? placeType;
}

/// Coordinates the Pre-Round Gate Configuration Countdown, 20Hz Boolean simulation,
/// 60-120Hz render interpolation, AI prep & probe updates, 1v1 WebSocket Lockstep PvP,
/// and the Interactive Sandbox Circuit Editor.
final class ArenaMatchController extends ChangeNotifier {
  static const double tickStepSec = 0.050; // 20Hz logic
  static const int defaultPrepDurationTicks = 200; // 10.0s Pre-Round Countdown
  static const int maxJumpersPerSide = 2;

  final ArenaSynth synth = ArenaSynth();
  final SparkParticlePool particles = SparkParticlePool();

  ui.FragmentProgram? substrateProgram;

  ArenaGameMode mode = ArenaGameMode.aiLadder;
  int selectedDroidCode = 385;
  int unlockedLadderIndex = 2;
  DailyUnderdogChallenge? activeDaily;

  late ArenaTopology topology;
  late ArenaState state;
  DroidProbeController? aiController;

  // Live 1v1 Online WebSocket PvP Coordinator.
  late final OnlinePvpCoordinator pvp = OnlinePvpCoordinator(
    onMatchStarted: _onOnlineMatchStarted,
    onPrepEditApplied: _onOnlinePrepEditApplied,
    onLiveRoundStarted: _onOnlineLiveRoundStarted,
    onStateChanged: notifyListeners,
  );

  // Interactive Sandbox Circuit Editor state.
  SandboxCircuitDraft sandboxDraft = SandboxCircuitDraft.scaffold();
  late SandboxValidationReport sandboxReport = sandboxDraft.validate();
  SandboxTool activeSandboxTool = SandboxTool.placeXor;
  bool sandboxResetPinMode = false;
  int? sandboxWireSourceNode;
  int? sandboxDraggingNode;
  bool sandboxDraggedMoved = false;
  String sandboxStatus =
      'SANDBOX EDITOR: Tap silicon to place mirrored gates, then select WIRE to connect Rails → Gates → Central Bus!';

  // Best-of-5 duel tracking.
  int cyanSeriesWins = 0;
  int amberSeriesWins = 0;
  ArenaSide? seriesLoserPicker;

  // Pre-Round Logic Gate Configuration state (both sides supported offline; assigned side online).
  PrepTool activePrepTool = PrepTool.xorGate;
  bool holdPrepCountdown = false;
  int cyanGateEdits = 0;
  int amberGateEdits = 0;
  int cyanJumpersPlaced = 0;
  int amberJumpersPlaced = 0;
  bool manualAmberEdited = false;
  int? prepSelectedSourceNode;
  String lastPrepStatus =
      'Select a real logic gate below and tap sockets on either side before 0.0s!';

  // Fixed-timestep accumulator & debug controls.
  double _accumulatorSec = 0.0;
  double elapsedSec = 0.0;
  double timeScale = 1.0;
  bool paused = false;
  bool showDebugBar = false;
  int _lastHeartbeatSecond = -1;
  int _lastPrepTickSecond = -1;

  // Press-and-hold downstream wire preview state.
  int? heldRailNode;
  Set<int> highlightedNodes = const <int>{};
  Set<int> highlightedWires = const <int>{};

  int _proceduralCounter = 1;

  ArenaMatchController() {
    _loadShaderAsync();
    startAiLadderMatch(droidCode: selectedDroidCode);
  }

  @override
  void dispose() {
    pvp.disconnect();
    super.dispose();
  }

  double get subTickAlpha => (_accumulatorSec / tickStepSec).clamp(0.0, 1.0);

  double get displaySecondsRemaining {
    if (mode == ArenaGameMode.sandboxBuilder) return 0.0;
    if (state.phase == MatchPhase.finished) return 0.0;
    final double exactTicks =
        (state.phaseTicksRemaining - subTickAlpha).clamp(0.0, 999.0);
    return exactTicks * tickStepSec;
  }

  int get currentStateHash => state.stateHash32(topology.nodeCount);

  String exportCurrentUrlHash() => CircuitUrlCodec.encodeUrlFragment(topology);

  Future<void> _loadShaderAsync() async {
    try {
      substrateProgram =
          await ui.FragmentProgram.fromAsset('shaders/pulse_wire.frag');
      notifyListeners();
    } catch (_) {
      // Headless test environments without shader bundle fall back to gradient cleanly.
    }
  }

  void setPrepTool(PrepTool tool) {
    activePrepTool = tool;
    if (tool != PrepTool.jumperWire) {
      prepSelectedSourceNode = null;
    }
    notifyListeners();
  }

  void toggleHoldPrepCountdown() {
    if (mode == ArenaGameMode.onlinePvp) return;
    holdPrepCountdown = !holdPrepCountdown;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // LIVE 1v1 ONLINE WEBSOCKET PVP MODE
  // ---------------------------------------------------------------------------

  Future<void> hostOnlinePvpRoom({String? customBoardHash}) async {
    mode = ArenaGameMode.onlinePvp;
    activeDaily = null;
    aiController = null;
    await pvp.hostNewRoom(customBoardHash: customBoardHash);
    notifyListeners();
  }

  void joinOnlinePvpRoom(String roomCode, {String? customBoardHash}) {
    mode = ArenaGameMode.onlinePvp;
    activeDaily = null;
    aiController = null;
    pvp.connectToRoom(roomCode, customBoardHash: customBoardHash);
    notifyListeners();
  }

  void _onOnlineMatchStarted(ArenaTopology board, ArenaState liveState) {
    topology = board;
    state = liveState;
    cyanGateEdits = 0;
    amberGateEdits = 0;
    cyanJumpersPlaced = 0;
    amberJumpersPlaced = 0;
    prepSelectedSourceNode = null;
    holdPrepCountdown = false;
    _accumulatorSec = 0.0;
    clearRailPreview();
    particles.clear();
    synth.resetMatch();
    lastPrepStatus =
        '1v1 ROOM ${pvp.roomCode} (${pvp.localSide.name.toUpperCase()}): Configure your logic bay & tap READY!';
    notifyListeners();
  }

  void _onOnlinePrepEditApplied(ArenaTopology updated, PrepEditEvent edit) {
    topology = updated;
    if (edit.kind == PrepEditKind.gateSwap) {
      if (edit.side == ArenaSide.cyan) {
        cyanGateEdits++;
      } else {
        amberGateEdits++;
      }
      lastPrepStatus =
          '${edit.side.name.toUpperCase()} configured socket #${edit.nodeOrSrc} → ${edit.gateType.shortLabel}';
    } else {
      if (edit.side == ArenaSide.cyan) {
        cyanJumpersPlaced++;
      } else {
        amberJumpersPlaced++;
      }
      lastPrepStatus =
          '${edit.side.name.toUpperCase()} routed jumper #${edit.nodeOrSrc} → #${edit.typeOrDst}';
    }
    final int sparkNode = edit.kind == PrepEditKind.gateSwap
        ? edit.nodeOrSrc
        : edit.typeOrDst;
    if (sparkNode >= 0 && sparkNode < updated.nodeCount) {
      particles.spawnBurst(
        normX: updated.nodeX[sparkNode],
        normY: updated.nodeY[sparkNode],
        count: 10,
        colorArgb: edit.side == ArenaSide.cyan ? 0xFF00E5FF : 0xFFFFB000,
      );
    }
    synth.handleEvents(<SimEvent>[
      SimEvent(
        tick: 0,
        type: SimEventType.pulserDeployed,
        nodeId: sparkNode.clamp(0, updated.nodeCount - 1),
        side: edit.side,
      ),
    ]);
    notifyListeners();
  }

  void _onOnlineLiveRoundStarted() {
    if (pvp.session == null) return;
    topology = pvp.session!.topology;
    state = pvp.session!.liveState;
    prepSelectedSourceNode = null;
    clearRailPreview();
    _accumulatorSec = 0.0;
    synth.handleEvents(<SimEvent>[
      const SimEvent(
        tick: 0,
        type: SimEventType.latchLocked,
        nodeId: 0,
        side: ArenaSide.cyan,
      ),
    ]);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // INTERACTIVE SANDBOX CIRCUIT EDITOR MODE
  // ---------------------------------------------------------------------------

  void enterSandboxBuilder({bool loadCurrentBoard = false}) {
    if (mode == ArenaGameMode.onlinePvp) {
      pvp.disconnect();
    }
    mode = ArenaGameMode.sandboxBuilder;
    aiController = null;
    activeDaily = null;
    sandboxWireSourceNode = null;
    sandboxDraggingNode = null;

    if (loadCurrentBoard) {
      sandboxDraft = SandboxCircuitDraft.fromTopology(
        topology,
        autoMirror: false,
      );
      sandboxStatus =
          'Loaded "${topology.title}" into Sandbox Editor — place, move, wire, or export!';
    }
    _syncSandboxPreview();
  }

  void resetSandboxScaffold() {
    sandboxDraft = SandboxCircuitDraft.scaffold(
      railsPerSide: 4,
      busCount: 5,
      autoMirror: sandboxDraft.autoMirror,
    );
    sandboxWireSourceNode = null;
    sandboxStatus =
        'Created clean 4v4 Rail + 5-Node Central Bus scaffold. Place gates on silicon!';
    _syncSandboxPreview();
  }

  void clearSandboxInterior() {
    sandboxDraft.clearInteriorGates();
    sandboxWireSourceNode = null;
    sandboxStatus = 'Cleared interior gates & traces (kept Rails and Bus).';
    _syncSandboxPreview();
  }

  void setSandboxTool(SandboxTool tool) {
    activeSandboxTool = tool;
    if (tool != SandboxTool.wireTrace) {
      sandboxWireSourceNode = null;
      highlightedNodes = const <int>{};
      highlightedWires = const <int>{};
    }
    notifyListeners();
  }

  void toggleSandboxMirror() {
    sandboxDraft.autoMirror = !sandboxDraft.autoMirror;
    sandboxStatus = sandboxDraft.autoMirror
        ? 'Mirror Symmetry ON: Cyan edits automatically mirror across the Central Bus.'
        : 'Mirror Symmetry OFF: Asymmetric freeform placement enabled.';
    _syncSandboxPreview();
  }

  void toggleSandboxResetPin() {
    sandboxResetPinMode = !sandboxResetPinMode;
    sandboxStatus = sandboxResetPinMode
        ? 'SR-Latch Wire Pin set to RESET (snipe pin).'
        : 'SR-Latch Wire Pin set to SET (capture pin).';
    notifyListeners();
  }

  void adjustSandboxPulsers({required ArenaSide side, required int delta}) {
    if (side == ArenaSide.cyan) {
      sandboxDraft.cyanInitialPulsers =
          (sandboxDraft.cyanInitialPulsers + delta).clamp(1, 9);
    } else {
      sandboxDraft.amberInitialPulsers =
          (sandboxDraft.amberInitialPulsers + delta).clamp(1, 9);
    }
    _syncSandboxPreview();
  }

  void handleSandboxPointerDown(double normX, double normY) {
    synth.unlock();
    final int? hit = sandboxDraft.findNearestNode(normX, normY);

    if (activeSandboxTool == SandboxTool.eraser) {
      if (hit != null) {
        final String label = sandboxDraft.nodes[hit].type.shortLabel;
        sandboxDraft.deleteNode(hit);
        sandboxStatus = 'Deleted $label #$hit.';
        _syncSandboxPreview();
      }
      return;
    }

    if (activeSandboxTool == SandboxTool.wireTrace) {
      if (hit == null) {
        sandboxWireSourceNode = null;
        highlightedNodes = const <int>{};
        highlightedWires = const <int>{};
        notifyListeners();
        return;
      }
      if (sandboxWireSourceNode == null) {
        sandboxWireSourceNode = hit;
        highlightedNodes = <int>{hit};
        sandboxStatus =
            'Source #${hit} (${sandboxDraft.nodes[hit].type.shortLabel}) selected — tap target gate or Bus Node!';
        notifyListeners();
      } else {
        final int src = sandboxWireSourceNode!;
        sandboxWireSourceNode = null;
        highlightedNodes = const <int>{};
        sandboxStatus = sandboxDraft.connectOrToggleWire(
          src: src,
          dst: hit,
          requestedPinRole:
              sandboxResetPinMode ? PinRole.reset : PinRole.set,
        );
        _syncSandboxPreview();
      }
      return;
    }

    if (activeSandboxTool == SandboxTool.moveEdit) {
      if (hit != null) {
        sandboxDraggingNode = hit;
        sandboxDraggedMoved = false;
        highlightedNodes = <int>{hit};
        notifyListeners();
      }
      return;
    }

    // Component placement tool: if tapping an existing node, allow dragging it; otherwise place new component!
    if (hit != null) {
      sandboxDraggingNode = hit;
      sandboxDraggedMoved = false;
      highlightedNodes = <int>{hit};
      notifyListeners();
      return;
    }

    final NodeType? placeType = activeSandboxTool.placeType;
    if (placeType != null) {
      final int? placed = sandboxDraft.placeComponent(
        type: placeType,
        x: normX,
        y: normY,
      );
      if (placed != null) {
        particles.spawnBurst(
          normX: sandboxDraft.nodes[placed].x,
          normY: sandboxDraft.nodes[placed].y,
          count: 8,
          colorArgb: normX <= 0.50 ? 0xFF00E5FF : 0xFFFFB000,
        );
        sandboxStatus = sandboxDraft.autoMirror && placeType != NodeType.busNode
            ? 'Placed mirrored ${placeType.shortLabel} pair (#$placed).'
            : 'Placed ${placeType.shortLabel} #$placed.';
        _syncSandboxPreview();
      } else {
        sandboxStatus = 'Maximum 64-node circuit limit reached.';
        notifyListeners();
      }
    }
  }

  void handleSandboxPointerMove(double normX, double normY) {
    final int? dragId = sandboxDraggingNode;
    if (dragId == null || dragId >= sandboxDraft.nodes.length) return;
    final SandboxNodeDraft n = sandboxDraft.nodes[dragId];
    if ((n.x - normX).abs() > 0.012 || (n.y - normY).abs() > 0.012) {
      sandboxDraggedMoved = true;
      sandboxDraft.moveNode(dragId, normX, normY);
      _syncSandboxPreview();
    }
  }

  void handleSandboxPointerUp() {
    final int? dragId = sandboxDraggingNode;
    if (dragId != null &&
        !sandboxDraggedMoved &&
        activeSandboxTool == SandboxTool.moveEdit &&
        dragId < sandboxDraft.nodes.length) {
      sandboxDraft.cycleNodeParam(dragId);
      final SandboxNodeDraft n = sandboxDraft.nodes[dragId];
      sandboxStatus =
          'Updated #${dragId} (${n.type.shortLabel}) parameter → ${n.param}.';
      _syncSandboxPreview();
    }
    sandboxDraggingNode = null;
    sandboxDraggedMoved = false;
    if (activeSandboxTool != SandboxTool.wireTrace) {
      highlightedNodes = const <int>{};
    }
    notifyListeners();
  }

  String? launchSandboxMatch({required bool vsAi, bool hostOnline = false}) {
    final SandboxValidationReport report = sandboxDraft.validate();
    sandboxReport = report;
    if (!report.ok || report.urlHash == null) {
      sandboxStatus = report.error ?? 'Circuit validation failed.';
      notifyListeners();
      return sandboxStatus;
    }

    final ArenaTopology built = sandboxDraft.buildTopology();
    if (hostOnline) {
      hostOnlinePvpRoom(customBoardHash: report.urlHash);
      return null;
    }

    mode = ArenaGameMode.customSandboxHash;
    activeDaily = null;
    _configureMatch(
      board: built,
      vsAi: vsAi,
      aiPersona: vsAi ? DroidPersona.forCode(selectedDroidCode) : null,
    );
    return null;
  }

  void _syncSandboxPreview() {
    topology = sandboxDraft.buildTopology();
    state = ArenaState.initial(topology, startPhase: MatchPhase.prepPhase)
      ..phaseTicksRemaining = defaultPrepDurationTicks;
    sandboxReport = sandboxDraft.validate();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // OFFLINE & CAMPAIGN MODES
  // ---------------------------------------------------------------------------

  void startAiLadderMatch({
    required int droidCode,
    BoardArchetype? archetypeOverride,
  }) {
    if (mode == ArenaGameMode.onlinePvp) pvp.disconnect();
    mode = ArenaGameMode.aiLadder;
    selectedDroidCode = droidCode.clamp(1, 999);
    activeDaily = null;

    final ArenaTopology board;
    if (selectedDroidCode == 999) {
      board = ProceduralGenerator.generate(
        seedLo: 0x999B055 + _proceduralCounter++,
        archetype: BoardArchetype.latchHeavy,
        busNodeCount: 9,
        cyanPulsers: 5,
        amberPulsers: 7,
        customTitle: 'Command Sector 999: Cyborg Core',
      );
    } else if (_proceduralCounter == 1 && archetypeOverride == null) {
      board = PresetBoards.symmetricClassic();
      _proceduralCounter++;
    } else {
      final BoardArchetype arch = archetypeOverride ??
          BoardArchetype.values[_proceduralCounter % 4];
      board = ProceduralGenerator.generate(
        seedLo: 0xA1000 + selectedDroidCode * 31 + (_proceduralCounter++ * 97),
        archetype: arch,
      );
    }

    _configureMatch(
      board: board,
      vsAi: true,
      aiPersona: DroidPersona.forCode(selectedDroidCode),
    );
  }

  void startDailyUnderdog({DateTime? date}) {
    if (mode == ArenaGameMode.onlinePvp) pvp.disconnect();
    mode = ArenaGameMode.dailyUnderdog;
    final DailyUnderdogChallenge daily =
        DailyUnderdogChallenge.forDate(date ?? DateTime.now().toUtc());
    activeDaily = daily;
    _configureMatch(
      board: daily.topology,
      vsAi: true,
      aiPersona: daily.aiPersona,
    );
  }

  void startLocalHotseat({ArenaTopology? preset}) {
    if (mode == ArenaGameMode.onlinePvp) pvp.disconnect();
    mode = ArenaGameMode.localHotseat;
    activeDaily = null;
    final ArenaTopology board = preset ??
        ProceduralGenerator.generate(
          seedLo: 0x2200 + (_proceduralCounter++ * 131),
          archetype: BoardArchetype.mirrorSymmetric,
        );
    _configureMatch(board: board, vsAi: false);
  }

  void startBestOfFiveDuel({bool resetSeries = true, BoardArchetype? pick}) {
    if (mode == ArenaGameMode.onlinePvp) pvp.disconnect();
    mode = ArenaGameMode.bestOfFiveDuel;
    activeDaily = null;
    if (resetSeries) {
      cyanSeriesWins = 0;
      amberSeriesWins = 0;
      seriesLoserPicker = null;
    }
    final BoardArchetype arch = pick ?? BoardArchetype.mirrorSymmetric;
    final ArenaTopology board = ProceduralGenerator.generate(
      seedLo: 0xB0500 + (_proceduralCounter++ * 257),
      archetype: arch,
    );
    _configureMatch(
      board: board,
      vsAi: true,
      aiPersona: DroidPersona.forCode(674),
    );
  }

  String? importCustomUrlHash(String urlOrFragment) {
    try {
      final ArenaTopology decoded =
          CircuitUrlCodec.decodeUrlFragment(urlOrFragment);
      final ({bool ok, String? error}) check =
          CircuitUrlCodec.validateSandboxCircuit(decoded);
      if (!check.ok) {
        return check.error ?? 'Invalid custom circuit.';
      }
      if (mode == ArenaGameMode.onlinePvp) pvp.disconnect();
      mode = ArenaGameMode.customSandboxHash;
      activeDaily = null;
      _configureMatch(
        board: decoded,
        vsAi: true,
        aiPersona: DroidPersona.forCode(selectedDroidCode),
      );
      return null;
    } catch (e) {
      return 'Could not decode circuit link: $e';
    }
  }

  void rematchCurrent() {
    switch (mode) {
      case ArenaGameMode.aiLadder:
        startAiLadderMatch(droidCode: selectedDroidCode);
      case ArenaGameMode.dailyUnderdog:
        if (activeDaily != null) {
          _configureMatch(
            board: activeDaily!.topology,
            vsAi: true,
            aiPersona: activeDaily!.aiPersona,
          );
        } else {
          startDailyUnderdog();
        }
      case ArenaGameMode.localHotseat:
        _configureMatch(board: topology, vsAi: false);
      case ArenaGameMode.bestOfFiveDuel:
        startBestOfFiveDuel(resetSeries: true);
      case ArenaGameMode.onlinePvp:
        pvp.requestRematch();
      case ArenaGameMode.sandboxBuilder:
        _syncSandboxPreview();
      case ArenaGameMode.customSandboxHash:
        _configureMatch(
          board: topology,
          vsAi: true,
          aiPersona: DroidPersona.forCode(selectedDroidCode),
        );
    }
  }

  void _configureMatch({
    required ArenaTopology board,
    required bool vsAi,
    DroidPersona? aiPersona,
  }) {
    topology = board;
    state = ArenaState.initial(board, startPhase: MatchPhase.prepPhase)
      ..phaseTicksRemaining = defaultPrepDurationTicks;

    cyanGateEdits = 0;
    amberGateEdits = 0;
    cyanJumpersPlaced = 0;
    amberJumpersPlaced = 0;
    manualAmberEdited = false;
    holdPrepCountdown = false;
    prepSelectedSourceNode = null;
    lastPrepStatus = vsAi
        ? 'Configure Cyan gates on the left (or tap right-side gates to customize both sides) before 0.0s!'
        : '2P PREP: Configure real logic gates & jumper wires on BOTH Cyan & Amber sides before 0.0s!';

    clearRailPreview();
    particles.clear();
    synth.resetMatch();
    _accumulatorSec = 0.0;
    _lastHeartbeatSecond = -1;
    _lastPrepTickSecond = -1;
    paused = false;

    if (vsAi && aiPersona != null) {
      final BoardTacticalProfile profile = BoardTacticalProfile.analyze(board);
      aiController = DroidProbeController(
        side: ArenaSide.amber,
        persona: aiPersona,
        profile: profile,
        rng: Xoshiro128PlusPlus.fromSeed(
          board.id.hashCode,
          aiPersona.code,
        ),
      );
    } else {
      aiController = null;
    }
    notifyListeners();
  }

  /// Frame update driven by Flutter `Ticker` at 60-120fps.
  void onFrame(double dtSec) {
    final double clampedDt = dtSec.clamp(0.0, 0.10) * timeScale;
    elapsedSec += clampedDt;
    particles.step(clampedDt);

    if (mode == ArenaGameMode.sandboxBuilder) {
      notifyListeners();
      return;
    }

    if (mode == ArenaGameMode.onlinePvp &&
        (pvp.stage == OnlineRoomStage.connecting ||
            pvp.stage == OnlineRoomStage.waitingForOpponent ||
            pvp.stage == OnlineRoomStage.disconnected ||
            pvp.stage == OnlineRoomStage.error)) {
      notifyListeners();
      return;
    }

    if (paused ||
        state.phase == MatchPhase.finished ||
        (state.phase == MatchPhase.prepPhase && holdPrepCountdown)) {
      notifyListeners();
      return;
    }

    _accumulatorSec += clampedDt;
    while (_accumulatorSec >= tickStepSec &&
        state.phase != MatchPhase.finished) {
      _accumulatorSec -= tickStepSec;
      _advanceOneSimTick();
    }
    notifyListeners();
  }

  /// Advances a single deterministic 50ms simulation tick (callable from Debug Step button).
  void stepSingleDebugTick() {
    if (mode == ArenaGameMode.sandboxBuilder ||
        state.phase == MatchPhase.finished) {
      return;
    }
    _advanceOneSimTick();
    notifyListeners();
  }

  void _advanceOneSimTick() {
    if (mode == ArenaGameMode.onlinePvp) {
      _advanceOnlineSimTick();
      return;
    }

    final MatchPhase prevPhase = state.phase;
    final List<SimEvent> tickEvents = <SimEvent>[];

    // AI Opponent configures its own Amber gates during the Pre-Round Countdown!
    if (state.phase == MatchPhase.prepPhase &&
        aiController != null &&
        !manualAmberEdited) {
      if (state.phaseTicksRemaining == 135 || state.phaseTicksRemaining == 70) {
        _performAiPrepGateUpgrade();
      }
      if (state.phaseTicksRemaining <= 60 && state.phaseTicksRemaining > 0) {
        final int prepSec = (state.phaseTicksRemaining + 19) ~/ 20;
        if (prepSec != _lastPrepTickSecond) {
          _lastPrepTickSecond = prepSec;
          synth.playCountdownHeartbeat(urgent: prepSec <= 1);
        }
      }
    }

    if (aiController != null && state.phase == MatchPhase.liveCountdown) {
      final int? fireRail = aiController!.updateTick(state);
      if (fireRail != null) {
        ArenaSolver.deployPulser(
          topology,
          state,
          ArenaSide.amber,
          fireRail,
          events: tickEvents,
        );
      }
    }

    ArenaSolver.step(topology, state, events: tickEvents);

    if (prevPhase == MatchPhase.prepPhase &&
        state.phase == MatchPhase.liveCountdown) {
      prepSelectedSourceNode = null;
      holdPrepCountdown = false;
      synth.handleEvents(<SimEvent>[
        SimEvent(
          tick: state.tick,
          type: SimEventType.clockAwakened,
          nodeId: 0,
          side: ArenaSide.cyan,
        ),
      ]);
    }

    if (tickEvents.isNotEmpty) {
      synth.handleEvents(tickEvents);
      particles.spawnFromEvents(topology, tickEvents);
    }

    if (state.phase == MatchPhase.liveCountdown &&
        state.phaseTicksRemaining <= 100 &&
        state.phaseTicksRemaining > 0) {
      final int secRemaining = (state.phaseTicksRemaining + 19) ~/ 20;
      if (secRemaining != _lastHeartbeatSecond) {
        _lastHeartbeatSecond = secRemaining;
        synth.playCountdownHeartbeat(urgent: secRemaining <= 2);
      }
    }

    if (prevPhase != MatchPhase.finished &&
        state.phase == MatchPhase.finished) {
      clearRailPreview();
      final ({int cyan, int amber, int neutral}) sc =
          state.computeBusScore(topology);
      if (mode == ArenaGameMode.aiLadder && sc.cyan > sc.amber) {
        final int idx =
            DroidPersona.campaignLadderCodes.indexOf(selectedDroidCode);
        if (idx >= 0 && idx + 1 > unlockedLadderIndex) {
          unlockedLadderIndex =
              (idx + 1).clamp(0, DroidPersona.campaignLadderCodes.length - 1);
        }
      } else if (mode == ArenaGameMode.bestOfFiveDuel) {
        if (sc.cyan > sc.amber) {
          cyanSeriesWins++;
          seriesLoserPicker = ArenaSide.amber;
        } else if (sc.amber > sc.cyan) {
          amberSeriesWins++;
          seriesLoserPicker = ArenaSide.cyan;
        } else {
          seriesLoserPicker = ArenaSide.cyan;
        }
      }
    }
  }

  void _advanceOnlineSimTick() {
    final LockstepSession? ses = pvp.session;
    if (ses == null) return;

    pvp.stepAttachedBotTick();

    if (state.phase == MatchPhase.prepPhase) {
      if (state.phaseTicksRemaining > 1) {
        state.phaseTicksRemaining--;
      }
      return;
    }

    final MatchPhase prevPhase = state.phase;
    final List<SimEvent> tickEvents = <SimEvent>[];
    ses.stepTick(simEvents: tickEvents);

    if (tickEvents.isNotEmpty) {
      synth.handleEvents(tickEvents);
      particles.spawnFromEvents(topology, tickEvents);
    }

    if (ses.currentTick > 0 && ses.currentTick % 20 == 0) {
      pvp.sendHashCheck(ses.currentTick, ses.computeStateHash());
    }

    if (prevPhase != MatchPhase.finished &&
        state.phase == MatchPhase.finished) {
      clearRailPreview();
      final ({int cyan, int amber, int neutral}) sc =
          state.computeBusScore(topology);
      pvp.reportRoundFinished(cyanPoints: sc.cyan, amberPoints: sc.amber);
    }
  }

  void _performAiPrepGateUpgrade() {
    if (aiController == null) return;
    final Xoshiro128PlusPlus rng = aiController!.rng;
    final List<int> amberSockets = <int>[
      for (int i = 0; i < topology.nodeCount; i++)
        if (topology.configurableSideOf(i) == ArenaSide.amber) i,
    ];
    if (amberSockets.isEmpty) return;

    final int targetSocket = amberSockets[rng.nextInt(amberSockets.length)];
    final int inDeg =
        topology.inEdgeStart[targetSocket + 1] - topology.inEdgeStart[targetSocket];
    final List<NodeType> smartChoices = inDeg >= 2
        ? const <NodeType>[
            NodeType.orGate,
            NodeType.xorGate,
            NodeType.nandGate,
            NodeType.andGate,
          ]
        : const <NodeType>[
            NodeType.buffer,
            NodeType.orGate,
            NodeType.notGate,
          ];
    final NodeType chosen = smartChoices[rng.nextInt(smartChoices.length)];
    if (chosen == topology.typeOf(targetSocket)) return;

    final ArenaTopology? updated = topology.tryConfigureGate(
      side: ArenaSide.amber,
      nodeId: targetSocket,
      newType: chosen,
    );
    if (updated != null) {
      aiController!.probePosition = topology.nodeY[targetSocket];
      amberGateEdits++;
      lastPrepStatus =
          'Unit ${aiController!.persona.designation} configured Amber socket #$targetSocket → ${chosen.shortLabel}';
      _commitPrepTopology(updated, side: ArenaSide.amber, nodeId: targetSocket);
    }
  }

  /// Begins press-and-hold downstream wire preview on a rail or gate node.
  void beginRailHoldPreview(int nodeId) {
    synth.unlock();
    heldRailNode = nodeId;
    final ({Set<int> nodes, Set<int> wireIndices}) trace =
        topology.traceDownstream(nodeId, maxHops: 3);
    highlightedNodes = trace.nodes;
    highlightedWires = trace.wireIndices;
    notifyListeners();
  }

  void clearRailPreview() {
    if (heldRailNode == null &&
        highlightedNodes.isEmpty &&
        highlightedWires.isEmpty) {
      return;
    }
    heldRailNode = null;
    highlightedNodes = const <int>{};
    highlightedWires = const <int>{};
    notifyListeners();
  }

  /// Fires a Pulser on [railNodeId] if owned by an interactive human side.
  bool tryFireRail(int railNodeId) {
    synth.unlock();
    if (railNodeId < 0 || railNodeId >= topology.nodeCount) return false;
    final int sideCode = topology.nodeParam[railNodeId];
    final ArenaSide? railSide = ArenaSide.fromCode(sideCode);
    if (railSide == null) return false;

    if (mode == ArenaGameMode.onlinePvp) {
      if (railSide != pvp.localSide || state.phase != MatchPhase.liveCountdown) {
        return false;
      }
      final Uint8List ownRails = topology.railsFor(pvp.localSide);
      final int rIdx = ownRails.indexOf(railNodeId);
      if (rIdx < 0) return false;
      if (!state.canDeployOnRail(topology, railSide, railNodeId)) return false;
      pvp.sendDeployRailIndex(state.tick, rIdx);
      return true;
    }

    if (railSide == ArenaSide.amber && aiController != null) {
      return false;
    }

    final List<SimEvent> events = <SimEvent>[];
    final bool ok = ArenaSolver.deployPulser(
      topology,
      state,
      railSide,
      railNodeId,
      events: events,
    );
    if (ok) {
      synth.handleEvents(events);
      particles.spawnFromEvents(topology, events);
      notifyListeners();
    }
    return ok;
  }

  /// Configures real Boolean gates (`AND`, `OR`, `XOR`, `NAND`, `NOR`, `NOT`, `BUF`)
  /// or routes Jumper Wires during the Pre-Round Countdown!
  void handlePrepNodeTap(int nodeId) {
    synth.unlock();
    if (state.phase != MatchPhase.prepPhase) return;
    if (nodeId < 0 || nodeId >= topology.nodeCount) return;

    // 1. Jumper Wire Tool (`+WIRE`): tap source node then destination gate on the same side!
    if (activePrepTool == PrepTool.jumperWire) {
      if (prepSelectedSourceNode == null) {
        if (topology.typeOf(nodeId) != NodeType.busNode &&
            topology.typeOf(nodeId) != NodeType.deadEnd) {
          final ArenaSide srcSide =
              topology.nodeX[nodeId] < 0.50 ? ArenaSide.cyan : ArenaSide.amber;
          if (mode == ArenaGameMode.onlinePvp && srcSide != pvp.localSide) {
            lastPrepStatus =
                'Online 1v1: You can only route jumpers in your ${pvp.localSide.name.toUpperCase()} bay.';
            notifyListeners();
            return;
          }
          prepSelectedSourceNode = nodeId;
          final ({Set<int> nodes, Set<int> wireIndices}) trace =
              topology.traceDownstream(nodeId, maxHops: 2);
          highlightedNodes = trace.nodes;
          highlightedWires = trace.wireIndices;
          lastPrepStatus =
              'Wire source #$nodeId selected — tap a target gate on the same side to connect!';
          notifyListeners();
        }
        return;
      }

      final int src = prepSelectedSourceNode!;
      prepSelectedSourceNode = null;
      clearRailPreview();
      if (src == nodeId) {
        notifyListeners();
        return;
      }

      final ArenaSide wireSide =
          topology.nodeX[src] < 0.50 ? ArenaSide.cyan : ArenaSide.amber;
      if (mode == ArenaGameMode.onlinePvp && wireSide != pvp.localSide) {
        return;
      }

      final int usedJumpers =
          wireSide == ArenaSide.cyan ? cyanJumpersPlaced : amberJumpersPlaced;
      if (usedJumpers >= maxJumpersPerSide) {
        lastPrepStatus =
            '${wireSide.name.toUpperCase()} jumper limit ($maxJumpersPerSide/$maxJumpersPerSide) reached!';
        notifyListeners();
        return;
      }

      final ArenaTopology? jumped = topology.tryAddHomeJumper(
        side: wireSide,
        srcNode: src,
        dstNode: nodeId,
      );
      if (jumped != null) {
        if (mode == ArenaGameMode.onlinePvp) {
          pvp.sendPrepJumperWire(src, nodeId);
          return;
        }
        if (wireSide == ArenaSide.cyan) {
          cyanJumpersPlaced++;
        } else {
          amberJumpersPlaced++;
          manualAmberEdited = true;
        }
        lastPrepStatus =
            'Routed ${wireSide.name.toUpperCase()} jumper wire: #$src → #$nodeId';
        _commitPrepTopology(jumped, side: wireSide, nodeId: nodeId);
      } else {
        lastPrepStatus =
            'Invalid jumper target (must stay in same territory and <= 3 gate inputs).';
        notifyListeners();
      }
      return;
    }

    // 2. Real Logic Gate Socket Configuration!
    final ArenaSide? socketSide = topology.configurableSideOf(nodeId);
    if (socketSide == null) {
      if (topology.typeOf(nodeId).isRail) {
        beginRailHoldPreview(nodeId);
      }
      return;
    }

    if (mode == ArenaGameMode.onlinePvp && socketSide != pvp.localSide) {
      lastPrepStatus =
          'Online 1v1: You control the ${pvp.localSide.name.toUpperCase()} Logic Bay.';
      notifyListeners();
      return;
    }

    final NodeType currentType = topology.typeOf(nodeId);
    const List<NodeType> palette = NodeType.configurablePalette;
    NodeType desiredType;
    if (activePrepTool == PrepTool.cycleGate ||
        activePrepTool.targetNodeType == currentType) {
      final int curIdx = palette.indexOf(currentType);
      desiredType = palette[(curIdx + 1) % palette.length];
    } else {
      desiredType = activePrepTool.targetNodeType!;
    }

    final ArenaTopology? swapped = topology.tryConfigureGate(
      side: socketSide,
      nodeId: nodeId,
      newType: desiredType,
    );
    if (swapped != null) {
      if (mode == ArenaGameMode.onlinePvp) {
        pvp.sendPrepGateSwap(nodeId, desiredType);
        return;
      }
      if (socketSide == ArenaSide.cyan) {
        cyanGateEdits++;
      } else {
        amberGateEdits++;
        manualAmberEdited = true;
      }
      lastPrepStatus =
          '${socketSide.name.toUpperCase()} socket #$nodeId: ${currentType.shortLabel} → ${desiredType.shortLabel}';
      _commitPrepTopology(swapped, side: socketSide, nodeId: nodeId);
    }
  }

  /// Locks in Pre-Round Gate Prep (sends `CMD_PREP_READY` in Online 1v1, or starts immediately offline).
  void lockInAndStartLiveRound() {
    synth.unlock();
    if (state.phase != MatchPhase.prepPhase) return;
    if (mode == ArenaGameMode.onlinePvp) {
      pvp.sendPrepReady(ready: true);
      lastPrepStatus =
          'Locked in ${pvp.localSide.name.toUpperCase()} gates — waiting for opponent READY...';
      notifyListeners();
      return;
    }

    state.phase = MatchPhase.liveCountdown;
    state.phaseTicksRemaining = topology.liveDurationTicks;
    holdPrepCountdown = false;
    prepSelectedSourceNode = null;
    clearRailPreview();
    synth.handleEvents(<SimEvent>[
      SimEvent(
        tick: state.tick,
        type: SimEventType.latchLocked,
        nodeId: 0,
        side: ArenaSide.cyan,
      ),
    ]);
    notifyListeners();
  }

  void skipPrepPhase() => lockInAndStartLiveRound();

  void _commitPrepTopology(
    ArenaTopology updated, {
    required ArenaSide side,
    required int nodeId,
  }) {
    final int remainingTicks = state.phaseTicksRemaining;
    topology = updated;
    state = ArenaState.initial(updated, startPhase: MatchPhase.prepPhase)
      ..phaseTicksRemaining = remainingTicks;
    if (aiController != null) {
      aiController = DroidProbeController(
        side: ArenaSide.amber,
        persona: aiController!.persona,
        profile: BoardTacticalProfile.analyze(updated),
        rng: aiController!.rng,
      )..probePosition = aiController!.probePosition;
    }
    particles.spawnBurst(
      normX: updated.nodeX[nodeId],
      normY: updated.nodeY[nodeId],
      count: 10,
      colorArgb: side == ArenaSide.cyan ? 0xFF00E5FF : 0xFFFFB000,
    );
    synth.handleEvents(<SimEvent>[
      SimEvent(
        tick: state.tick,
        type: SimEventType.pulserDeployed,
        nodeId: nodeId,
        side: side,
      ),
    ]);
    notifyListeners();
  }
}
