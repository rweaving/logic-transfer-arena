import 'dart:async';
import 'dart:math' as math;

import 'package:arena_core/arena_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'game/arena_match_controller.dart';
import 'net/online_pvp_coordinator.dart';
import 'render/arena_board_painter.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LogicTransferArenaApp());
}

class LogicTransferArenaApp extends StatelessWidget {
  const LogicTransferArenaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Happy Logic Simulator: Logic Transfer Arena',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: ArenaPalette.bgDeep,
        colorScheme: const ColorScheme.dark(
          primary: ArenaPalette.cyanCore,
          secondary: ArenaPalette.amberCore,
          surface: ArenaPalette.panelBg,
        ),
      ),
      home: const ArenaShellScreen(),
    );
  }
}

class ArenaShellScreen extends StatefulWidget {
  const ArenaShellScreen({super.key});

  @override
  State<ArenaShellScreen> createState() => _ArenaShellScreenState();
}

class _ArenaShellScreenState extends State<ArenaShellScreen>
    with SingleTickerProviderStateMixin {
  late final ArenaMatchController _ctrl;
  late final Ticker _ticker;
  Duration? _lastTickElapsed;
  Timer? _holdPreviewTimer;
  int? _pointerDownNode;
  final FocusNode _keyboardFocus = FocusNode();
  final TextEditingController _joinRoomCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _ctrl = ArenaMatchController();

    final String fragment = Uri.base.fragment;
    if (fragment.startsWith('arena=v1.')) {
      _ctrl.importCustomUrlHash('#$fragment');
    }

    _ticker = createTicker((Duration elapsed) {
      final Duration prev = _lastTickElapsed ?? elapsed;
      _lastTickElapsed = elapsed;
      final double dt = (elapsed - prev).inMicroseconds / 1000000.0;
      _ctrl.onFrame(dt);
    })
      ..start();
  }

  @override
  void dispose() {
    _holdPreviewTimer?.cancel();
    _ticker.dispose();
    _ctrl.dispose();
    _keyboardFocus.dispose();
    _joinRoomCtrl.dispose();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (_ctrl.mode == ArenaGameMode.sandboxBuilder) {
      return KeyEventResult.ignored;
    }

    final LogicalKeyboardKey key = event.logicalKey;

    if (_ctrl.state.phase == MatchPhase.prepPhase &&
        (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.space)) {
      _ctrl.lockInAndStartLiveRound();
      return KeyEventResult.handled;
    }

    final List<LogicalKeyboardKey> cyanKeys = <LogicalKeyboardKey>[
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
    ];
    final int cIdx = cyanKeys.indexOf(key);
    if (cIdx >= 0 && cIdx < _ctrl.topology.leftRails.length) {
      _ctrl.tryFireRail(_ctrl.topology.leftRails[cIdx]);
      return KeyEventResult.handled;
    }

    final List<LogicalKeyboardKey> amberKeys = <LogicalKeyboardKey>[
      LogicalKeyboardKey.keyU,
      LogicalKeyboardKey.keyI,
      LogicalKeyboardKey.keyO,
      LogicalKeyboardKey.keyJ,
      LogicalKeyboardKey.keyK,
      LogicalKeyboardKey.keyL,
    ];
    final int aIdx = amberKeys.indexOf(key);
    if (aIdx >= 0 && aIdx < _ctrl.topology.rightRails.length) {
      _ctrl.tryFireRail(_ctrl.topology.rightRails[aIdx]);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyR) {
      _ctrl.rematchCurrent();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  int? _hitTestNode(Offset localPos, Size canvasSize, bool isPortrait) {
    final double hitRadius =
        (math.min(canvasSize.width, canvasSize.height) * 0.062).clamp(26.0, 42.0);
    int? closest;
    double bestDistSq = hitRadius * hitRadius;

    for (int i = 0; i < _ctrl.topology.nodeCount; i++) {
      final Offset nodePos = boardToScreen(
        _ctrl.topology.nodeX[i],
        _ctrl.topology.nodeY[i],
        canvasSize,
        isPortrait: isPortrait,
      );
      final double dx = localPos.dx - nodePos.dx;
      final double dy = localPos.dy - nodePos.dy;
      final double d2 = dx * dx + dy * dy;
      if (d2 <= bestDistSq) {
        bestDistSq = d2;
        closest = i;
      }
    }
    return closest;
  }

  void _onPointerDown(Offset localPos, Size canvasSize, bool isPortrait) {
    _ctrl.synth.unlock();
    if (_ctrl.mode == ArenaGameMode.sandboxBuilder) {
      final (double bx, double by) = screenToBoard(
        localPos,
        canvasSize,
        isPortrait: isPortrait,
      );
      _ctrl.handleSandboxPointerDown(bx, by);
      return;
    }

    final int? hit = _hitTestNode(localPos, canvasSize, isPortrait);
    _pointerDownNode = hit;
    _holdPreviewTimer?.cancel();

    if (hit == null) {
      _ctrl.clearRailPreview();
      return;
    }
    if (_ctrl.state.phase == MatchPhase.prepPhase) {
      _ctrl.handlePrepNodeTap(hit);
      return;
    }

    if (_ctrl.topology.typeOf(hit).isRail) {
      _holdPreviewTimer = Timer(const Duration(milliseconds: 120), () {
        if (_pointerDownNode == hit) {
          _ctrl.beginRailHoldPreview(hit);
        }
      });
    }
  }

  void _onPointerMove(Offset localPos, Size canvasSize, bool isPortrait) {
    if (_ctrl.mode == ArenaGameMode.sandboxBuilder) {
      final (double bx, double by) = screenToBoard(
        localPos,
        canvasSize,
        isPortrait: isPortrait,
      );
      _ctrl.handleSandboxPointerMove(bx, by);
      return;
    }

    if (_pointerDownNode == null || _ctrl.state.phase == MatchPhase.prepPhase) {
      return;
    }
    final int? hit = _hitTestNode(localPos, canvasSize, isPortrait);
    if (hit != _pointerDownNode) {
      _holdPreviewTimer?.cancel();
      _pointerDownNode = null;
      _ctrl.clearRailPreview();
    }
  }

  void _onPointerUp(Offset localPos, Size canvasSize, bool isPortrait) {
    if (_ctrl.mode == ArenaGameMode.sandboxBuilder) {
      _ctrl.handleSandboxPointerUp();
      return;
    }

    _holdPreviewTimer?.cancel();
    final int? downNode = _pointerDownNode;
    _pointerDownNode = null;
    if (_ctrl.state.phase == MatchPhase.prepPhase) {
      return;
    }
    _ctrl.clearRailPreview();

    if (downNode == null || _ctrl.state.phase != MatchPhase.liveCountdown) {
      return;
    }
    final int? releaseHit = _hitTestNode(localPos, canvasSize, isPortrait);
    if (releaseHit == downNode && _ctrl.topology.typeOf(downNode).isRail) {
      _ctrl.tryFireRail(downNode);
    }
  }

  bool get _showOnlineLobbyOverlay {
    if (_ctrl.mode != ArenaGameMode.onlinePvp) return false;
    final OnlineRoomStage st = _ctrl.pvp.stage;
    return st == OnlineRoomStage.disconnected ||
        st == OnlineRoomStage.connecting ||
        st == OnlineRoomStage.waitingForOpponent ||
        st == OnlineRoomStage.error;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _keyboardFocus,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: ListenableBuilder(
        listenable: _ctrl,
        builder: (BuildContext context, _) {
          return Scaffold(
            body: SafeArea(
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  final bool isPortrait =
                      constraints.maxHeight > constraints.maxWidth * 1.08;
                  return Column(
                    children: <Widget>[
                      _buildTopHud(isPortrait: isPortrait),
                      _buildModeToolbar(context),
                      if (_ctrl.mode == ArenaGameMode.onlinePvp &&
                          _ctrl.pvp.roomCode.isNotEmpty)
                        _buildOnlineStatusStrip(context),
                      if (_ctrl.showDebugBar) _buildDebugInspectorBar(),
                      if (_ctrl.mode == ArenaGameMode.sandboxBuilder)
                        _buildSandboxEditorTray(context)
                      else if (_ctrl.state.phase == MatchPhase.prepPhase &&
                          !_showOnlineLobbyOverlay)
                        _buildPrepConfigurationTray(),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
                          child: _buildBoardViewport(
                            context,
                            isPortrait: isPortrait,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTopHud({required bool isPortrait}) {
    final ({int cyan, int amber, int neutral}) busScore =
        _ctrl.state.computeBusScore(_ctrl.topology);
    final bool isSandbox = _ctrl.mode == ArenaGameMode.sandboxBuilder;
    final String phaseLabel = isSandbox
        ? 'SANDBOX ARCHITECT'
        : switch (_ctrl.state.phase) {
            MatchPhase.coinFlip => 'SYNC',
            MatchPhase.prepPhase => _ctrl.holdPrepCountdown
                ? 'GATE PREP (HELD)'
                : 'GATE PREP COUNTDOWN',
            MatchPhase.liveCountdown => 'TRANSFER LIVE',
            MatchPhase.overtime => 'OVERTIME SETTLE',
            MatchPhase.finished => 'BUS LOCKED',
          };
    final bool isPrep = !isSandbox && _ctrl.state.phase == MatchPhase.prepPhase;
    final bool urgent = !isSandbox &&
        (_ctrl.state.phase == MatchPhase.overtime ||
            (_ctrl.state.phase == MatchPhase.liveCountdown &&
                _ctrl.state.phaseTicksRemaining <= 100) ||
            (isPrep && _ctrl.state.phaseTicksRemaining <= 60));

    final String cyanLabel = _ctrl.mode == ArenaGameMode.onlinePvp &&
            _ctrl.pvp.localSide == ArenaSide.cyan
        ? 'CYAN (YOU)'
        : (isPortrait ? 'CYAN (BOTTOM)' : 'CYAN (LEFT)');

    final String oppTitle = _ctrl.mode == ArenaGameMode.onlinePvp
        ? (_ctrl.pvp.localSide == ArenaSide.amber
            ? 'AMBER (YOU)'
            : 'AMBER (REMOTE)')
        : (_ctrl.aiController != null
            ? 'UNIT ${_ctrl.aiController!.persona.designation}'
            : 'AMBER P2');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: const BoxDecoration(
        color: ArenaPalette.panelBg,
        border: Border(
          bottom: BorderSide(color: ArenaPalette.panelBorder, width: 1),
        ),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: _buildSideReadout(
              label: cyanLabel,
              score: busScore.cyan,
              pulsersRemaining: _ctrl.state.cyanPulsersRemaining,
              maxPulsers: _ctrl.topology.cyanInitialPulsers,
              color: ArenaPalette.cyanCore,
              alignRight: false,
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
            decoration: BoxDecoration(
              color: ArenaPalette.bgDeep,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: (isPrep || isSandbox)
                    ? ArenaPalette.cyanCore
                    : (urgent
                        ? ArenaPalette.amberCore
                        : ArenaPalette.panelBorder),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  phaseLabel,
                  style: TextStyle(
                    fontSize: 10,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                    color: (isPrep || isSandbox)
                        ? ArenaPalette.cyanCore
                        : (urgent
                            ? ArenaPalette.amberCore
                            : ArenaPalette.textMuted),
                  ),
                ),
                Text(
                  isSandbox
                      ? '${_ctrl.topology.nodeCount}N • ${_ctrl.topology.edgeCount}W'
                      : '${_ctrl.displaySecondsRemaining.toStringAsFixed(1)}s',
                  style: TextStyle(
                    fontSize: isSandbox ? 16 : 21,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w800,
                    color: urgent
                        ? ArenaPalette.amberCore
                        : ArenaPalette.textPrimary,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _buildSideReadout(
              label: oppTitle,
              score: busScore.amber,
              pulsersRemaining: _ctrl.state.amberPulsersRemaining,
              maxPulsers: _ctrl.topology.amberInitialPulsers,
              color: ArenaPalette.amberCore,
              alignRight: true,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSideReadout({
    required String label,
    required int score,
    required int pulsersRemaining,
    required int maxPulsers,
    required Color color,
    required bool alignRight,
  }) {
    final List<Widget> pips = List<Widget>.generate(
      math.max(pulsersRemaining, maxPulsers).clamp(1, 9),
      (int idx) {
        final bool active = idx < pulsersRemaining;
        return Container(
          width: 9,
          height: 13,
          margin: const EdgeInsets.symmetric(horizontal: 1.5),
          decoration: BoxDecoration(
            color: active ? color : const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(2),
          ),
        );
      },
    );

    return Column(
      crossAxisAlignment:
          alignRight ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          mainAxisSize: MainAxisSize.min,
          children: alignRight
              ? <Widget>[
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: ArenaPalette.textMuted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '$score',
                    style: TextStyle(
                      fontSize: 22,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w800,
                      color: color,
                    ),
                  ),
                ]
              : <Widget>[
                  Text(
                    '$score',
                    style: TextStyle(
                      fontSize: 22,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w800,
                      color: color,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: ArenaPalette.textMuted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
        ),
        const SizedBox(height: 3),
        Row(mainAxisSize: MainAxisSize.min, children: pips),
      ],
    );
  }

  Widget _buildModeToolbar(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        color: Color(0xFF0C121B),
        border: Border(
          bottom: BorderSide(color: ArenaPalette.panelBorder, width: 1),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: <Widget>[
            _modeButton(
              label: '001-999 Ladder',
              selected: _ctrl.mode == ArenaGameMode.aiLadder,
              onTap: () => _showLadderSelectorModal(context),
            ),
            const SizedBox(width: 6),
            _modeButton(
              label: 'Daily Underdog',
              selected: _ctrl.mode == ArenaGameMode.dailyUnderdog,
              onTap: _ctrl.startDailyUnderdog,
            ),
            const SizedBox(width: 6),
            _modeButton(
              label: '2P Hotseat',
              selected: _ctrl.mode == ArenaGameMode.localHotseat,
              onTap: _ctrl.startLocalHotseat,
            ),
            const SizedBox(width: 6),
            _modeButton(
              label: _ctrl.mode == ArenaGameMode.bestOfFiveDuel
                  ? 'Bo5 (${_ctrl.cyanSeriesWins}-${_ctrl.amberSeriesWins})'
                  : 'Best-of-5 Duel',
              selected: _ctrl.mode == ArenaGameMode.bestOfFiveDuel,
              onTap: () => _ctrl.startBestOfFiveDuel(resetSeries: true),
            ),
            const SizedBox(width: 6),
            _modeButton(
              label: _ctrl.mode == ArenaGameMode.onlinePvp &&
                      _ctrl.pvp.roomCode.isNotEmpty
                  ? '1v1 Online (${_ctrl.pvp.roomCode})'
                  : '1v1 Online Room',
              selected: _ctrl.mode == ArenaGameMode.onlinePvp,
              onTap: () {
                if (_ctrl.mode != ArenaGameMode.onlinePvp) {
                  setState(() {
                    _ctrl.mode = ArenaGameMode.onlinePvp;
                    _ctrl.aiController = null;
                  });
                }
              },
            ),
            const SizedBox(width: 6),
            _modeButton(
              label: 'Sandbox Editor',
              selected: _ctrl.mode == ArenaGameMode.sandboxBuilder,
              onTap: () => _ctrl.enterSandboxBuilder(loadCurrentBoard: false),
            ),
            const SizedBox(width: 6),
            _modeButton(
              label: 'URL Hash Link',
              selected: _ctrl.mode == ArenaGameMode.customSandboxHash,
              onTap: () => _showUrlCodecModal(context),
            ),
            const SizedBox(width: 10),
            IconButton(
              tooltip: 'New Prep Countdown / Rematch (R)',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.refresh, size: 18),
              onPressed: _ctrl.rematchCurrent,
            ),
            IconButton(
              tooltip: 'Toggle Tick Debugger',
              visualDensity: VisualDensity.compact,
              icon: Icon(
                Icons.memory,
                size: 18,
                color: _ctrl.showDebugBar
                    ? ArenaPalette.cyanCore
                    : ArenaPalette.textMuted,
              ),
              onPressed: () =>
                  setState(() => _ctrl.showDebugBar = !_ctrl.showDebugBar),
            ),
            IconButton(
              tooltip: _ctrl.synth.muted ? 'Unmute Audio' : 'Mute Audio',
              visualDensity: VisualDensity.compact,
              icon: Icon(
                _ctrl.synth.muted ? Icons.volume_off : Icons.volume_up,
                size: 18,
                color: ArenaPalette.textMuted,
              ),
              onPressed: () =>
                  setState(() => _ctrl.synth.muted = !_ctrl.synth.muted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOnlineStatusStrip(BuildContext context) {
    final OnlinePvpCoordinator pvp = _ctrl.pvp;
    final Color sideCol = pvp.localSide == ArenaSide.cyan
        ? ArenaPalette.cyanCore
        : ArenaPalette.amberCore;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: const BoxDecoration(
        color: Color(0xFF0A1622),
        border: Border(
          bottom: BorderSide(color: Color(0xFF1E3A52), width: 1),
        ),
      ),
      child: Wrap(
        spacing: 14,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          InkWell(
            onTap: () {
              Clipboard.setData(ClipboardData(text: pvp.roomCode));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Copied Room Code: ${pvp.roomCode}')),
              );
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  'ROOM ${pvp.roomCode}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w800,
                    color: ArenaPalette.cyanCore,
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.copy, size: 12, color: ArenaPalette.cyanCore),
              ],
            ),
          ),
          Text(
            'SIDE: ${pvp.localSide.name.toUpperCase()}',
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              fontWeight: FontWeight.w700,
              color: sideCol,
            ),
          ),
          Text(
            'BO5 SERIES: CYAN ${pvp.cyanWins} - ${pvp.amberWins} AMBER',
            style: const TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: ArenaPalette.textPrimary,
            ),
          ),
          Text(
            pvp.desyncDetected
                ? 'FNV-1a: DESYNC ALERT'
                : 'LOCKSTEP: SYNC OK (${pvp.lastRttMs}ms)',
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: pvp.desyncDetected
                  ? ArenaPalette.amberCore
                  : ArenaPalette.textMuted,
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 6),
            ),
            onPressed: () {
              pvp.disconnect();
              setState(() {});
            },
            child: const Text(
              'Leave Room',
              style: TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }

  /// Interactive Sandbox Circuit Editor Tray (`Sandbox -> Arena Bridge`).
  Widget _buildSandboxEditorTray(BuildContext context) {
    final SandboxValidationReport rep = _ctrl.sandboxReport;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: const BoxDecoration(
        color: Color(0xFF0E1D2B),
        border: Border(
          bottom: BorderSide(color: Color(0xFF1E3A52), width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                const Text(
                  'EDITOR:',
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w700,
                    color: ArenaPalette.textMuted,
                  ),
                ),
                const SizedBox(width: 6),
                ...SandboxTool.values.map((SandboxTool tool) {
                  final bool selected = _ctrl.activeSandboxTool == tool;
                  final bool isAction = tool.placeType == null;
                  final Color activeBg = isAction
                      ? ArenaPalette.amberCore
                      : ArenaPalette.cyanCore;
                  return Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: () => _ctrl.setSandboxTool(tool),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: selected ? activeBg : ArenaPalette.bgDeep,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: selected ? activeBg : ArenaPalette.panelBorder,
                          ),
                        ),
                        child: Text(
                          tool.label,
                          style: TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w700,
                            color: selected
                                ? ArenaPalette.bgDeep
                                : ArenaPalette.textPrimary,
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
          const SizedBox(height: 5),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    side: BorderSide(
                      color: _ctrl.sandboxDraft.autoMirror
                          ? ArenaPalette.cyanCore
                          : ArenaPalette.panelBorder,
                    ),
                  ),
                  onPressed: _ctrl.toggleSandboxMirror,
                  child: Text(
                    _ctrl.sandboxDraft.autoMirror
                        ? 'MIRROR: ON'
                        : 'MIRROR: OFF',
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: _ctrl.sandboxDraft.autoMirror
                          ? ArenaPalette.cyanCore
                          : ArenaPalette.textMuted,
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    side: BorderSide(
                      color: _ctrl.sandboxResetPinMode
                          ? ArenaPalette.amberCore
                          : ArenaPalette.panelBorder,
                    ),
                  ),
                  onPressed: _ctrl.toggleSandboxResetPin,
                  child: Text(
                    _ctrl.sandboxResetPinMode
                        ? 'LATCH PIN: RESET'
                        : 'LATCH PIN: SET',
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: _ctrl.sandboxResetPinMode
                          ? ArenaPalette.amberCore
                          : ArenaPalette.textMuted,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => _ctrl.adjustSandboxPulsers(
                    side: ArenaSide.cyan,
                    delta: _ctrl.sandboxDraft.cyanInitialPulsers >= 7 ? -4 : 1,
                  ),
                  child: Text(
                    'Cyan Ammo:${_ctrl.sandboxDraft.cyanInitialPulsers}',
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: ArenaPalette.cyanCore,
                    ),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => _ctrl.adjustSandboxPulsers(
                    side: ArenaSide.amber,
                    delta: _ctrl.sandboxDraft.amberInitialPulsers >= 7 ? -4 : 1,
                  ),
                  child: Text(
                    'Amber Ammo:${_ctrl.sandboxDraft.amberInitialPulsers}',
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: ArenaPalette.amberCore,
                    ),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: _ctrl.clearSandboxInterior,
                  child: const Text(
                    'Clear Gates',
                    style: TextStyle(fontSize: 11, fontFamily: 'monospace'),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: _ctrl.resetSandboxScaffold,
                  child: const Text(
                    'Reset 4v4',
                    style: TextStyle(fontSize: 11, fontFamily: 'monospace'),
                  ),
                ),
                const SizedBox(width: 6),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    backgroundColor:
                        rep.ok ? ArenaPalette.cyanCore : const Color(0xFF334155),
                    foregroundColor:
                        rep.ok ? ArenaPalette.bgDeep : ArenaPalette.textMuted,
                  ),
                  onPressed: () {
                    final String? err = _ctrl.launchSandboxMatch(vsAi: true);
                    if (err != null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(err)),
                      );
                    }
                  },
                  child: const Text(
                    'Play vs AI →',
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () {
                    final String? err = _ctrl.launchSandboxMatch(vsAi: false);
                    if (err != null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(err)),
                      );
                    }
                  },
                  child: const Text(
                    'Play 2P',
                    style: TextStyle(fontSize: 11, fontFamily: 'monospace'),
                  ),
                ),
                const SizedBox(width: 5),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () {
                    final String? err = _ctrl.launchSandboxMatch(
                      vsAi: false,
                      hostOnline: true,
                    );
                    if (err != null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(err)),
                      );
                    }
                  },
                  child: const Text(
                    'Host 1v1 Room',
                    style: TextStyle(fontSize: 11, fontFamily: 'monospace'),
                  ),
                ),
                const SizedBox(width: 5),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => _showUrlCodecModal(context),
                  child: Text(
                    rep.urlHash != null
                        ? 'Export Hash (${rep.urlHash!.length}ch)'
                        : 'Export #arena=v1',
                    style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 3),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  _ctrl.sandboxStatus,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: ArenaPalette.textMuted,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                rep.ok
                    ? 'VALID • Causal Rails C:${rep.causalCyanRails}/${rep.totalCyanRails} A:${rep.causalAmberRails}/${rep.totalAmberRails}'
                    : 'CHECK: ${rep.error ?? "Incomplete"}',
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w700,
                  color: rep.ok ? ArenaPalette.cyanCore : ArenaPalette.amberCore,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Pre-Round Real Logic Gate Configuration Palette & Countdown Controls!
  Widget _buildPrepConfigurationTray() {
    const List<PrepTool> tools = <PrepTool>[
      PrepTool.andGate,
      PrepTool.orGate,
      PrepTool.xorGate,
      PrepTool.nandGate,
      PrepTool.norGate,
      PrepTool.notGate,
      PrepTool.bufferGate,
      PrepTool.jumperWire,
      PrepTool.cycleGate,
    ];

    final bool isOnline = _ctrl.mode == ArenaGameMode.onlinePvp;
    final int readyCount = (_ctrl.pvp.cyanPrepReady ? 1 : 0) +
        (_ctrl.pvp.amberPrepReady ? 1 : 0);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: const BoxDecoration(
        color: Color(0xFF0E1D2B),
        border: Border(
          bottom: BorderSide(color: Color(0xFF1E3A52), width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                const Text(
                  'GATE PALETTE:',
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w700,
                    color: ArenaPalette.textMuted,
                  ),
                ),
                const SizedBox(width: 8),
                ...tools.map((PrepTool tool) {
                  final bool selected = _ctrl.activePrepTool == tool;
                  return Padding(
                    padding: const EdgeInsets.only(right: 5),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: () => _ctrl.setPrepTool(tool),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: selected
                              ? ArenaPalette.cyanCore
                              : ArenaPalette.bgDeep,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: selected
                                ? ArenaPalette.cyanCore
                                : ArenaPalette.panelBorder,
                          ),
                        ),
                        child: Text(
                          tool.label,
                          style: TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w700,
                            color: selected
                                ? ArenaPalette.bgDeep
                                : ArenaPalette.textPrimary,
                          ),
                        ),
                      ),
                    ),
                  );
                }),
                const SizedBox(width: 6),
                if (!isOnline) ...<Widget>[
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      side: BorderSide(
                        color: _ctrl.holdPrepCountdown
                            ? ArenaPalette.amberCore
                            : ArenaPalette.panelBorder,
                      ),
                    ),
                    onPressed: _ctrl.toggleHoldPrepCountdown,
                    child: Text(
                      _ctrl.holdPrepCountdown ? 'RESUME TIMER' : 'HOLD TIMER',
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: _ctrl.holdPrepCountdown
                            ? ArenaPalette.amberCore
                            : ArenaPalette.textMuted,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    backgroundColor: (isOnline && _ctrl.pvp.localPrepReady)
                        ? const Color(0xFF1E3A52)
                        : ArenaPalette.cyanCore,
                    foregroundColor: (isOnline && _ctrl.pvp.localPrepReady)
                        ? ArenaPalette.cyanCore
                        : ArenaPalette.bgDeep,
                  ),
                  onPressed: _ctrl.lockInAndStartLiveRound,
                  child: Text(
                    isOnline
                        ? (_ctrl.pvp.localPrepReady
                            ? 'READY ($readyCount/2)'
                            : 'READY LOCK-IN ($readyCount/2) →')
                        : 'START ROUND →',
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 5),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  _ctrl.lastPrepStatus,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: ArenaPalette.textMuted,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'Cyan Mods:${_ctrl.cyanGateEdits} Wires:${_ctrl.cyanJumpersPlaced}/2  •  Amber Mods:${_ctrl.amberGateEdits} Wires:${_ctrl.amberJumpersPlaced}/2',
                style: const TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: ArenaPalette.textPrimary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _modeButton({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(5),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF15293B) : Colors.transparent,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: selected ? ArenaPalette.cyanCore : ArenaPalette.panelBorder,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontFamily: 'monospace',
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? ArenaPalette.cyanCore : ArenaPalette.textMuted,
          ),
        ),
      ),
    );
  }

  Widget _buildDebugInspectorBar() {
    final String hexHash = _ctrl.currentStateHash
        .toRadixString(16)
        .toUpperCase()
        .padLeft(8, '0');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: const Color(0xFF111A27),
      child: Wrap(
        spacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          Text(
            'TICK ${_ctrl.state.tick}  FNV1a:0x$hexHash',
            style: const TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: ArenaPalette.cyanCore,
            ),
          ),
          TextButton.icon(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            onPressed: () => setState(() => _ctrl.paused = !_ctrl.paused),
            icon: Icon(_ctrl.paused ? Icons.play_arrow : Icons.pause, size: 15),
            label: Text(
              _ctrl.paused ? 'Resume' : 'Pause',
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
          ),
          TextButton.icon(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            onPressed: _ctrl.stepSingleDebugTick,
            icon: const Icon(Icons.skip_next, size: 15),
            label: const Text(
              '+1 Tick (50ms)',
              style: TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            onPressed: () => setState(
              () => _ctrl.timeScale = _ctrl.timeScale == 1.0 ? 0.5 : 1.0,
            ),
            child: Text(
              'Speed: ${_ctrl.timeScale}x',
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBoardViewport(
    BuildContext context, {
    required bool isPortrait,
  }) {
    final String footerHint = _ctrl.mode == ArenaGameMode.sandboxBuilder
        ? 'SANDBOX EDITOR  •  Tap silicon to place components, select WIRE to connect pins, or drag nodes to reposition'
        : (_ctrl.state.phase == MatchPhase.prepPhase
            ? '${_ctrl.topology.title}  •  PRE-ROUND PREP: Pick a gate above and tap glowing sockets (Enter/Space to lock in)'
            : '${_ctrl.topology.title}  •  LIVE: Tap or hold rail to preview trace & deploy 4.0s Pulser (Keys 1–6 / U–L)');

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final Size canvasSize = Size(box.maxWidth, box.maxHeight);
        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: ArenaPalette.panelBorder),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (PointerDownEvent e) =>
                      _onPointerDown(e.localPosition, canvasSize, isPortrait),
                  onPointerMove: (PointerMoveEvent e) =>
                      _onPointerMove(e.localPosition, canvasSize, isPortrait),
                  onPointerUp: (PointerUpEvent e) =>
                      _onPointerUp(e.localPosition, canvasSize, isPortrait),
                  child: CustomPaint(
                    size: canvasSize,
                    painter: ArenaBoardPainter(
                      topology: _ctrl.topology,
                      state: _ctrl.state,
                      subTickAlpha: _ctrl.subTickAlpha,
                      elapsedSec: _ctrl.elapsedSec,
                      isPortrait: isPortrait,
                      substrateProgram: _ctrl.substrateProgram,
                      particles: _ctrl.particles,
                      highlightedNodes: _ctrl.highlightedNodes,
                      highlightedWires: _ctrl.highlightedWires,
                      prepSelectedNode:
                          _ctrl.mode == ArenaGameMode.sandboxBuilder
                              ? _ctrl.sandboxWireSourceNode
                              : _ctrl.prepSelectedSourceNode,
                      amberProbePos: _ctrl.aiController?.probePosition,
                      amberProbeHovering:
                          _ctrl.aiController?.isHoveringTarget ?? false,
                      showDebugTelemetry: _ctrl.showDebugBar ||
                          _ctrl.mode == ArenaGameMode.sandboxBuilder,
                    ),
                  ),
                ),
                Positioned(
                  left: 10,
                  bottom: 8,
                  child: IgnorePointer(
                    child: Text(
                      footerHint,
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: Color(0x9994A3B8),
                      ),
                    ),
                  ),
                ),
                if (_showOnlineLobbyOverlay)
                  _buildOnlineLobbyOverlay(context)
                else if (_ctrl.mode != ArenaGameMode.sandboxBuilder &&
                    _ctrl.state.phase == MatchPhase.finished)
                  _buildMatchSummaryOverlay(context),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildOnlineLobbyOverlay(BuildContext context) {
    final OnlinePvpCoordinator pvp = _ctrl.pvp;
    final bool waiting = pvp.stage == OnlineRoomStage.waitingForOpponent;
    final bool connecting = pvp.stage == OnlineRoomStage.connecting;

    return Container(
      color: const Color(0xD8090D14),
      alignment: Alignment.center,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 460),
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: ArenaPalette.panelBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: ArenaPalette.cyanCore, width: 1.5),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text(
              '1v1 ONLINE LOCKSTEP ROOM LOBBY',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w800,
                color: ArenaPalette.cyanCore,
                letterSpacing: 1.0,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              pvp.statusMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: ArenaPalette.textMuted,
              ),
            ),
            const SizedBox(height: 16),
            if (waiting) ...<Widget>[
              Container(
                padding: const EdgeInsets.symmetric(
                  vertical: 12,
                  horizontal: 16,
                ),
                decoration: BoxDecoration(
                  color: ArenaPalette.bgDeep,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: ArenaPalette.panelBorder),
                ),
                child: Column(
                  children: <Widget>[
                    const Text(
                      'SHARE 4-LETTER DUEL INVITE CODE',
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: ArenaPalette.textMuted,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      pvp.roomCode,
                      style: const TextStyle(
                        fontSize: 28,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w900,
                        letterSpacing: 4.0,
                        color: ArenaPalette.cyanCore,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: <Widget>[
                        OutlinedButton.icon(
                          icon: const Icon(Icons.copy, size: 15),
                          label: const Text(
                            'Copy Code',
                            style: TextStyle(
                              fontSize: 12,
                              fontFamily: 'monospace',
                            ),
                          ),
                          onPressed: () {
                            Clipboard.setData(
                              ClipboardData(text: pvp.roomCode),
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Copied Room ${pvp.roomCode}'),
                              ),
                            );
                          },
                        ),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: ArenaPalette.amberCore,
                            foregroundColor: ArenaPalette.bgDeep,
                          ),
                          icon: const Icon(Icons.smart_toy_outlined, size: 16),
                          label: const Text(
                            'Spawn WS Bot Challenger',
                            style: TextStyle(
                              fontSize: 12,
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          onPressed: pvp.hasBotChallenger
                              ? null
                              : pvp.spawnSocketBotChallenger,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ] else ...<Widget>[
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: ArenaPalette.cyanCore,
                  foregroundColor: ArenaPalette.bgDeep,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                icon: const Icon(Icons.add_box_outlined, size: 18),
                label: Text(
                  connecting ? 'Connecting...' : 'Create 4-Char Room',
                  style: const TextStyle(
                    fontSize: 13,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w800,
                  ),
                ),
                onPressed: connecting ? null : () => _ctrl.hostOnlinePvpRoom(),
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _joinRoomCtrl,
                      textCapitalization: TextCapitalization.characters,
                      style: const TextStyle(
                        fontSize: 13,
                        fontFamily: 'monospace',
                      ),
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                        hintText: 'Enter Room Code (e.g. K7X2)',
                      ),
                      onSubmitted: (String val) {
                        if (val.trim().isNotEmpty) {
                          _ctrl.joinOnlinePvpRoom(val);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 13,
                      ),
                    ),
                    onPressed: () {
                      if (_joinRoomCtrl.text.trim().isNotEmpty) {
                        _ctrl.joinOnlinePvpRoom(_joinRoomCtrl.text);
                      }
                    },
                    child: const Text(
                      'Join Room',
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMatchSummaryOverlay(BuildContext context) {
    final ({int cyan, int amber, int neutral}) sc =
        _ctrl.state.computeBusScore(_ctrl.topology);
    final bool cyanWon = sc.cyan > sc.amber;
    final bool tied = sc.cyan == sc.amber;
    final Color accent = cyanWon
        ? ArenaPalette.cyanCore
        : (tied ? ArenaPalette.textPrimary : ArenaPalette.amberCore);

    final String headline = cyanWon
        ? 'BUS MAJORITY SECURED'
        : (tied ? 'CENTRAL BUS DEADLOCK' : 'TRANSFER OVERRIDDEN');

    final bool isOnline = _ctrl.mode == ArenaGameMode.onlinePvp;
    final bool canPickOnlineArchetype = isOnline &&
        _ctrl.pvp.seriesWinner == null &&
        _ctrl.pvp.loserPicksNext == _ctrl.pvp.localSide;

    return Container(
      color: const Color(0xCC090D14),
      alignment: Alignment.center,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 440),
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: ArenaPalette.panelBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: accent, width: 1.6),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              headline,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 19,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w800,
                color: accent,
                letterSpacing: 1.0,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'CYAN ${sc.cyan}  —  ${sc.amber} AMBER',
              style: const TextStyle(
                fontSize: 24,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w800,
                color: ArenaPalette.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              isOnline
                  ? 'Room ${_ctrl.pvp.roomCode} Bo5: Cyan ${_ctrl.pvp.cyanWins} - ${_ctrl.pvp.amberWins} Amber  •  Tick ${_ctrl.state.tick}'
                  : 'Pulsers Spared: ${_ctrl.state.cyanPulsersRemaining}  •  Final Tick: ${_ctrl.state.tick}',
              style: const TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: ArenaPalette.textMuted,
              ),
            ),
            const SizedBox(height: 16),
            if (_ctrl.mode == ArenaGameMode.dailyUnderdog &&
                _ctrl.activeDaily != null) ...<Widget>[
              OutlinedButton.icon(
                icon: const Icon(Icons.share, size: 16),
                label: const Text(
                  'Copy Shareable Summary',
                  style: TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                onPressed: () {
                  final String summary = _ctrl.activeDaily!.formatShareSummary(
                    cyanPoints: sc.cyan,
                    amberPoints: sc.amber,
                    cyanPulsersSpared: _ctrl.state.cyanPulsersRemaining,
                  );
                  Clipboard.setData(ClipboardData(text: summary));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Copied: $summary')),
                  );
                },
              ),
              const SizedBox(height: 10),
            ],
            if ((_ctrl.mode == ArenaGameMode.bestOfFiveDuel &&
                    _ctrl.cyanSeriesWins < 3 &&
                    _ctrl.amberSeriesWins < 3) ||
                canPickOnlineArchetype) ...<Widget>[
              const Text(
                'NEXT ROUND ARCHETYPE (LOSER CHOICE):',
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: ArenaPalette.textMuted,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: <Widget>[
                  _archetypePickButton(
                    'Symmetric',
                    BoardArchetype.mirrorSymmetric,
                  ),
                  _archetypePickButton(
                    'Latch-Heavy',
                    BoardArchetype.latchHeavy,
                  ),
                  _archetypePickButton(
                    'Rotational',
                    BoardArchetype.pointSymmetric,
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            Wrap(
              spacing: 10,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: <Widget>[
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: ArenaPalette.cyanCore,
                    foregroundColor: ArenaPalette.bgDeep,
                  ),
                  onPressed: _ctrl.rematchCurrent,
                  icon: const Icon(Icons.replay, size: 17),
                  label: Text(
                    isOnline ? 'Rematch in Room' : 'Prep Next Round',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () =>
                      _ctrl.enterSandboxBuilder(loadCurrentBoard: true),
                  icon: const Icon(Icons.tune, size: 16),
                  label: const Text(
                    'Remix in Sandbox',
                    style: TextStyle(fontFamily: 'monospace'),
                  ),
                ),
                if (_ctrl.mode == ArenaGameMode.aiLadder && cyanWon)
                  OutlinedButton(
                    onPressed: () {
                      final List<int> codes = DroidPersona.campaignLadderCodes;
                      final int cur = codes.indexOf(_ctrl.selectedDroidCode);
                      final int nextCode = (cur >= 0 && cur + 1 < codes.length)
                          ? codes[cur + 1]
                          : 999;
                      _ctrl.startAiLadderMatch(droidCode: nextCode);
                    },
                    child: const Text(
                      'Next Droid Unit →',
                      style: TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _archetypePickButton(String label, BoardArchetype arch) {
    return OutlinedButton(
      onPressed: () {
        if (_ctrl.mode == ArenaGameMode.onlinePvp) {
          _ctrl.pvp.sendLoserArchetypePick(arch);
        } else {
          _ctrl.startBestOfFiveDuel(resetSeries: false, pick: arch);
        }
      },
      child: Text(
        label,
        style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
      ),
    );
  }

  void _showLadderSelectorModal(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: ArenaPalette.panelBg,
      builder: (BuildContext ctx) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                '001 TO 999 DROID LADDER & PRESET SECTORS',
                style: TextStyle(
                  fontSize: 14,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w700,
                  color: ArenaPalette.cyanCore,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: DroidPersona.campaignLadderCodes.map((int code) {
                  final DroidPersona p = DroidPersona.forCode(code);
                  final bool active = _ctrl.selectedDroidCode == code &&
                      _ctrl.mode == ArenaGameMode.aiLadder;
                  return ActionChip(
                    backgroundColor: active
                        ? const Color(0xFF15293B)
                        : ArenaPalette.bgDeep,
                    side: BorderSide(
                      color: active
                          ? ArenaPalette.cyanCore
                          : ArenaPalette.panelBorder,
                    ),
                    label: Text(
                      '${p.designation} • ${p.tierTitle}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _ctrl.startAiLadderMatch(droidCode: code);
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 14),
              const Text(
                'CURATED BENCHMARK BOARDS (2P HOTSEAT)',
                style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: ArenaPalette.textMuted,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: <Widget>[
                  OutlinedButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _ctrl.startLocalHotseat(
                        preset: PresetBoards.symmetricClassic(),
                      );
                    },
                    child: const Text('Bus Crossroads'),
                  ),
                  OutlinedButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _ctrl.startLocalHotseat(
                        preset: PresetBoards.latchVaultDuel(),
                      );
                    },
                    child: const Text('Vault Lockout'),
                  ),
                  OutlinedButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _ctrl.startLocalHotseat(
                        preset: PresetBoards.andHijackGauntlet(),
                      );
                    },
                    child: const Text('Crossfire Hijack'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  void _showUrlCodecModal(BuildContext context) {
    final String currentFragment = _ctrl.exportCurrentUrlHash();
    final TextEditingController inputCtrl =
        TextEditingController(text: currentFragment);

    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) {
        return AlertDialog(
          backgroundColor: ArenaPalette.panelBg,
          title: const Text(
            'Sandbox Bridge: URL Circuit Hash',
            style: TextStyle(fontSize: 15, fontFamily: 'monospace'),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Zero-server shareable hash (${currentFragment.length} chars, CRC-16 verified):',
                style: const TextStyle(
                  fontSize: 12,
                  color: ArenaPalette.textMuted,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: inputCtrl,
                maxLines: 3,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: '#arena=v1....',
                ),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: inputCtrl.text.trim()));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Circuit hash copied!')),
                );
              },
              child: const Text('Copy Hash'),
            ),
            OutlinedButton(
              onPressed: () {
                final String? err =
                    _ctrl.importCustomUrlHash(inputCtrl.text.trim());
                if (err != null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(err)),
                  );
                } else {
                  Navigator.pop(ctx);
                  _ctrl.enterSandboxBuilder(loadCurrentBoard: true);
                }
              },
              child: const Text('Open in Sandbox'),
            ),
            ElevatedButton(
              onPressed: () {
                final String? err =
                    _ctrl.importCustomUrlHash(inputCtrl.text.trim());
                if (err != null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(err)),
                  );
                } else {
                  Navigator.pop(ctx);
                }
              },
              child: const Text('Load & Play'),
            ),
          ],
        );
      },
    );
  }
}
