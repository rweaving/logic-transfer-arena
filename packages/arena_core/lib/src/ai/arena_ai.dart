import 'dart:math' as math;
import 'dart:typed_data';

import '../math/xoshiro128pp.dart';
import '../sim/arena_solver.dart';
import '../sim/arena_state.dart';
import '../sim/arena_topology.dart';
import '../sim/signal_types.dart';

/// Two-rail coordinated macro-action discovered by static analysis to light an AND gate.
final class AndComboCandidate {
  final int firstRailNode;
  final int secondRailNode;
  final int delayBetweenTicks;
  final int targetAndNode;

  const AndComboCandidate({
    required this.firstRailNode,
    required this.secondRailNode,
    required this.delayBetweenTicks,
    required this.targetAndNode,
  });
}

/// Pre-match static topological analysis of an [ArenaTopology] for fast AI tactical reasoning.
final class BoardTacticalProfile {
  static const int unreachableTicks = 9999;

  final ArenaTopology topology;

  /// Shortest propagation ticks from every node `u` to every node `v` (`nodeCount * nodeCount`).
  final Uint16List minTickMatrix;

  /// Static leverage score per node (weighted reachable Bus points + Splitter/Latch bonuses).
  final Float32List nodeLeverage;

  /// Coordinated 2-rail AND combos per side.
  final List<AndComboCandidate> cyanAndCombos;
  final List<AndComboCandidate> amberAndCombos;

  BoardTacticalProfile._({
    required this.topology,
    required this.minTickMatrix,
    required this.nodeLeverage,
    required this.cyanAndCombos,
    required this.amberAndCombos,
  });

  factory BoardTacticalProfile.analyze(ArenaTopology topology) {
    final int n = topology.nodeCount;
    final Uint16List dist =
        Uint16List.fromList(List<int>.filled(n * n, unreachableTicks));

    // All-pairs shortest tick delay on small graph (N <= 64 -> < 0.05ms).
    for (int src = 0; src < n; src++) {
      dist[src * n + src] = 0;
      final Uint8List visited = Uint8List(n);
      for (int step = 0; step < n; step++) {
        int u = -1;
        int best = unreachableTicks;
        for (int v = 0; v < n; v++) {
          if (visited[v] == 0 && dist[src * n + v] < best) {
            best = dist[src * n + v];
            u = v;
          }
        }
        if (u < 0) break;
        visited[u] = 1;
        for (int e = topology.outEdgeStart[u];
            e < topology.outEdgeStart[u + 1];
            e++) {
          final int v = topology.outEdgeDst[e];
          final int w = topology.typeOf(v) == NodeType.busNode
              ? 1
              : math.max(1, topology.delayOf(v));
          final int cand = best + w;
          if (cand < dist[src * n + v]) {
            dist[src * n + v] = cand;
          }
        }
      }
    }

    final Float32List leverage = Float32List(n);
    for (int u = 0; u < n; u++) {
      double score = 0.0;
      for (int bIdx = 0; bIdx < topology.busNodes.length; bIdx++) {
        final int bNode = topology.busNodes[bIdx];
        final int d = dist[u * n + bNode];
        if (d < unreachableTicks) {
          final int weight = topology.nodeParam[bNode].clamp(1, 2);
          score += weight * (1.0 + 6.0 / (d + 2));
        }
      }
      // Bonus for feeding SR-Latch Set or Reset pins.
      for (int v = 0; v < n; v++) {
        if (topology.typeOf(v) == NodeType.srLatch &&
            dist[u * n + v] < unreachableTicks) {
          score += 2.2;
        }
      }
      leverage[u] = score;
    }

    List<AndComboCandidate> findCombos(Uint8List rails) {
      final List<AndComboCandidate> combos = <AndComboCandidate>[];
      for (int gate = 0; gate < n; gate++) {
        if (topology.typeOf(gate) != NodeType.andGate) continue;
        final int s = topology.inEdgeStart[gate];
        final int end = topology.inEdgeStart[gate + 1];
        if (end - s != 2) continue;
        final int inA = topology.inEdgeSrc[s];
        final int inB = topology.inEdgeSrc[s + 1];

        int bestRailA = -1;
        int bestDistA = unreachableTicks;
        int bestRailB = -1;
        int bestDistB = unreachableTicks;

        for (final int r in rails) {
          final int dA = dist[r * n + inA];
          if (dA < bestDistA) {
            bestDistA = dA;
            bestRailA = r;
          }
        }
        for (final int r in rails) {
          if (r == bestRailA) continue;
          final int dB = dist[r * n + inB];
          if (dB < bestDistB) {
            bestDistB = dB;
            bestRailB = r;
          }
        }

        if (bestRailA >= 0 && bestRailB >= 0) {
          if (bestDistA >= bestDistB) {
            combos.add(AndComboCandidate(
              firstRailNode: bestRailA,
              secondRailNode: bestRailB,
              delayBetweenTicks: (bestDistA - bestDistB).clamp(0, 16),
              targetAndNode: gate,
            ));
          } else {
            combos.add(AndComboCandidate(
              firstRailNode: bestRailB,
              secondRailNode: bestRailA,
              delayBetweenTicks: (bestDistB - bestDistA).clamp(0, 16),
              targetAndNode: gate,
            ));
          }
        }
      }
      return combos;
    }

    return BoardTacticalProfile._(
      topology: topology,
      minTickMatrix: dist,
      nodeLeverage: leverage,
      cyanAndCombos: findCombos(topology.leftRails),
      amberAndCombos: findCombos(topology.rightRails),
    );
  }

  int tickDistance(int fromNode, int toNode) =>
      minTickMatrix[fromNode * topology.nodeCount + toNode];

  List<AndComboCandidate> combosFor(ArenaSide side) =>
      side == ArenaSide.cyan ? cyanAndCombos : amberAndCombos;
}

/// Paradroid-inspired "001 to 999" opponent configuration.
final class DroidPersona {
  final int code;
  final String designation;
  final String tierTitle;
  final int evalIntervalTicks;
  final int travelTicks;
  final int hoverCommitTicks;
  final int rolloutHorizonTicks;
  final int reservePulsersUntilEndgame;
  final double mistakeProbability;
  final double bluffProbability;
  final bool useAndCombos;
  final bool modelOpponentCounter;

  const DroidPersona({
    required this.code,
    required this.designation,
    required this.tierTitle,
    required this.evalIntervalTicks,
    required this.travelTicks,
    required this.hoverCommitTicks,
    required this.rolloutHorizonTicks,
    required this.reservePulsersUntilEndgame,
    required this.mistakeProbability,
    required this.bluffProbability,
    required this.useAndCombos,
    required this.modelOpponentCounter,
  });

  /// Constructs calibrated parameters for any droid number in `001..999`.
  factory DroidPersona.forCode(int rawCode) {
    final int c = rawCode.clamp(1, 999);
    if (c < 300) {
      // 1xx-2xx Maintenance Units: slow cadence, greedy, occasional dead-end blunders.
      return DroidPersona(
        code: c,
        designation: c.toString().padLeft(3, '0'),
        tierTitle: 'Maintenance Unit',
        evalIntervalTicks: 46 - ((c ~/ 20).clamp(0, 12)),
        travelTicks: 16,
        hoverCommitTicks: 10,
        rolloutHorizonTicks: 30,
        reservePulsersUntilEndgame: 0,
        mistakeProbability: (0.24 - c * 0.0005).clamp(0.08, 0.24),
        bluffProbability: 0.0,
        useAndCombos: false,
        modelOpponentCounter: false,
      );
    }
    if (c < 600) {
      // 3xx-5xx Security Units: evaluates splitters/XOR, holds 1 Pulser for final 3.0s.
      return DroidPersona(
        code: c,
        designation: c.toString().padLeft(3, '0'),
        tierTitle: 'Security Unit',
        evalIntervalTicks: 24 - (((c - 300) ~/ 40).clamp(0, 7)),
        travelTicks: 9,
        hoverCommitTicks: 6,
        rolloutHorizonTicks: 160,
        reservePulsersUntilEndgame: 1,
        mistakeProbability: 0.03,
        bluffProbability: 0.05,
        useAndCombos: false,
        modelOpponentCounter: false,
      );
    }
    if (c < 999) {
      // 6xx-8xx/9xx Battle & Logic Units: full horizon rollouts, AND hijacks, Reset snipes.
      return DroidPersona(
        code: c,
        designation: c.toString().padLeft(3, '0'),
        tierTitle: 'Battle Logic Unit',
        evalIntervalTicks: 11 - (((c - 600) ~/ 100).clamp(0, 4)),
        travelTicks: 5,
        hoverCommitTicks: 4,
        rolloutHorizonTicks: 340,
        reservePulsersUntilEndgame: 1,
        mistakeProbability: 0.0,
        bluffProbability: 0.16,
        useAndCombos: true,
        modelOpponentCounter: true,
      );
    }
    // 999 Command Cyborg Boss.
    return const DroidPersona(
      code: 999,
      designation: '999',
      tierTitle: 'Command Cyborg',
      evalIntervalTicks: 6,
      travelTicks: 4,
      hoverCommitTicks: 3,
      rolloutHorizonTicks: 340,
      reservePulsersUntilEndgame: 1,
      mistakeProbability: 0.0,
      bluffProbability: 0.22,
      useAndCombos: true,
      modelOpponentCounter: true,
    );
  }

  static const List<int> campaignLadderCodes = <int>[
    104,
    247,
    385,
    512,
    674,
    820,
    999,
  ];
}

/// Action decision returned by [RolloutEvaluator].
final class AiActionPlan {
  final int? primaryRailNode;
  final int? followUpRailNode;
  final int followUpDelayTicks;
  final double expectedUtility;

  const AiActionPlan.wait(this.expectedUtility)
      : primaryRailNode = null,
        followUpRailNode = null,
        followUpDelayTicks = 0;

  const AiActionPlan.deploy({
    required int railNode,
    required this.expectedUtility,
    this.followUpRailNode,
    this.followUpDelayTicks = 0,
  }) : primaryRailNode = railNode;
}

/// Deterministic forward-simulation evaluator running directly over cloned [ArenaState] arrays.
final class RolloutEvaluator {
  final BoardTacticalProfile profile;
  final ArenaState _workState;
  final ArenaState _counterState;

  RolloutEvaluator(this.profile)
      : _workState = ArenaState.initial(profile.topology),
        _counterState = ArenaState.initial(profile.topology);

  AiActionPlan chooseAction({
    required ArenaState liveState,
    required ArenaSide side,
    required DroidPersona persona,
    required Xoshiro128PlusPlus rng,
  }) {
    final ArenaTopology topo = profile.topology;
    if (liveState.phase != MatchPhase.liveCountdown) {
      return const AiActionPlan.wait(0.0);
    }

    final int remaining = liveState.pulsersRemainingFor(side);
    if (remaining <= 0) {
      return const AiActionPlan.wait(0.0);
    }

    // Reserve rule: hold final Pulser until final 3.0s (60 ticks) unless losing badly.
    final bool inEndgame = liveState.phaseTicksRemaining <= 60;
    if (!inEndgame && remaining <= persona.reservePulsersUntilEndgame) {
      return const AiActionPlan.wait(0.0);
    }

    final Uint8List rails = topo.railsFor(side);
    final List<int> availableRails = <int>[
      for (final int r in rails)
        if (liveState.canDeployOnRail(topo, side, r)) r,
    ];
    if (availableRails.isEmpty) {
      return const AiActionPlan.wait(0.0);
    }

    // Maintenance unit blunder / 1-step greedy behavior.
    if (persona.code < 300) {
      if (rng.nextBool(persona.mistakeProbability)) {
        final int randomRail = availableRails[rng.nextInt(availableRails.length)];
        return AiActionPlan.deploy(railNode: randomRail, expectedUtility: 0.1);
      }
      int bestRail = availableRails.first;
      double bestScore = -1e9;
      for (final int r in availableRails) {
        final double s =
            profile.nodeLeverage[r] + (rng.nextDouble() - 0.5) * 0.8;
        if (s > bestScore) {
          bestScore = s;
          bestRail = r;
        }
      }
      return AiActionPlan.deploy(railNode: bestRail, expectedUtility: bestScore);
    }

    // Baseline WAIT utility.
    final double waitUtility = _simulateCandidate(
      baseState: liveState,
      side: side,
      persona: persona,
      firstRail: null,
      secondRail: null,
      secondDelay: 0,
    );

    // Require positive tactical gain over waiting so the AI doesn't dump all Pulsers at t=0.
    final double urgencyThreshold = inEndgame ? 0.05 : 0.65;
    AiActionPlan bestPlan = AiActionPlan.wait(waitUtility);
    double bestGain = urgencyThreshold;

    for (final int r in availableRails) {
      if (!topo.canReachBus(r) && !rng.nextBool(persona.mistakeProbability)) {
        continue;
      }
      final double u = _simulateCandidate(
        baseState: liveState,
        side: side,
        persona: persona,
        firstRail: r,
        secondRail: null,
        secondDelay: 0,
      );
      final double gain = u - waitUtility + (rng.nextDouble() * 0.04);
      if (gain > bestGain) {
        bestGain = gain;
        bestPlan = AiActionPlan.deploy(railNode: r, expectedUtility: u);
      }
    }

    // Evaluate coordinated 2-Pulser AND gate combos when >= 2 Pulsers remain.
    if (persona.useAndCombos && remaining >= 2) {
      for (final AndComboCandidate combo in profile.combosFor(side)) {
        if (!liveState.canDeployOnRail(topo, side, combo.firstRailNode) ||
            !liveState.canDeployOnRail(topo, side, combo.secondRailNode)) {
          continue;
        }
        final double u = _simulateCandidate(
          baseState: liveState,
          side: side,
          persona: persona,
          firstRail: combo.firstRailNode,
          secondRail: combo.secondRailNode,
          secondDelay: combo.delayBetweenTicks,
        );
        // Slightly higher bar since a combo spends 2 Pulsers.
        final double gain = u - waitUtility - 0.45;
        if (gain > bestGain) {
          bestGain = gain;
          bestPlan = AiActionPlan.deploy(
            railNode: combo.firstRailNode,
            followUpRailNode: combo.secondRailNode,
            followUpDelayTicks: combo.delayBetweenTicks,
            expectedUtility: u,
          );
        }
      }
    }

    return bestPlan;
  }

  double _simulateCandidate({
    required ArenaState baseState,
    required ArenaSide side,
    required DroidPersona persona,
    required int? firstRail,
    required int? secondRail,
    required int secondDelay,
  }) {
    final ArenaTopology topo = profile.topology;
    _workState.copyFrom(baseState);

    if (firstRail != null) {
      ArenaSolver.deployPulser(topo, _workState, side, firstRail);
    }

    // Optional 1-ply opponent greedy counter check after 6 ticks (300ms human reaction).
    int? opponentReplyRail;
    if (persona.modelOpponentCounter &&
        firstRail != null &&
        _workState.pulsersRemainingFor(side.opponent) > 0) {
      opponentReplyRail = _bestImmediateCounterRail(
        baseState: _workState,
        oppSide: side.opponent,
      );
    }

    final int maxSteps = persona.rolloutHorizonTicks;
    for (int step = 0;
        step < maxSteps && _workState.phase != MatchPhase.finished;
        step++) {
      if (secondRail != null &&
          step == secondDelay &&
          _workState.phase == MatchPhase.liveCountdown) {
        ArenaSolver.deployPulser(topo, _workState, side, secondRail);
      }
      if (opponentReplyRail != null &&
          step == 6 &&
          _workState.phase == MatchPhase.liveCountdown) {
        ArenaSolver.deployPulser(
          topo,
          _workState,
          side.opponent,
          opponentReplyRail,
        );
      }
      ArenaSolver.step(topo, _workState);
    }

    return _evaluateBoardValue(_workState, side, baseState.phaseTicksRemaining);
  }

  int? _bestImmediateCounterRail({
    required ArenaState baseState,
    required ArenaSide oppSide,
  }) {
    final ArenaTopology topo = profile.topology;
    final Uint8List oppRails = topo.railsFor(oppSide);
    int? bestRail;
    double bestVal = -1e9;
    for (final int r in oppRails) {
      if (!topo.canReachBus(r) || !baseState.canDeployOnRail(topo, oppSide, r)) {
        continue;
      }
      _counterState.copyFrom(baseState);
      ArenaSolver.deployPulser(topo, _counterState, oppSide, r);
      for (int k = 0; k < 24 && _counterState.phase != MatchPhase.finished; k++) {
        ArenaSolver.step(topo, _counterState);
      }
      final double v = _evaluateBoardValue(_counterState, oppSide, 60);
      if (v > bestVal) {
        bestVal = v;
        bestRail = r;
      }
    }
    return bestRail;
  }

  double _evaluateBoardValue(
    ArenaState state,
    ArenaSide side,
    int initialPhaseTicksLeft,
  ) {
    final ArenaTopology topo = profile.topology;
    final ({int cyan, int amber, int neutral}) bus = state.computeBusScore(topo);
    final int myBus = side == ArenaSide.cyan ? bus.cyan : bus.amber;
    final int oppBus = side == ArenaSide.cyan ? bus.amber : bus.cyan;

    double latchDelta = 0.0;
    double clampDelta = 0.0;
    for (int i = 0; i < topo.nodeCount; i++) {
      final NodeType t = topo.typeOf(i);
      if (t == NodeType.srLatch) {
        final ArenaSide? owner = state.latchStoredOwner(i);
        if (owner == side) {
          latchDelta += 1.6;
        } else if (owner == side.opponent) {
          latchDelta -= 1.6;
        }
      } else if (t == NodeType.busNode) {
        final BusNodeStatus st = state.busNodeStatus(i);
        if (st ==
            (side == ArenaSide.cyan
                ? BusNodeStatus.clampedCyan
                : BusNodeStatus.clampedAmber)) {
          clampDelta += 0.45 * topo.nodeParam[i];
        } else if (st ==
            (side == ArenaSide.cyan
                ? BusNodeStatus.clampedAmber
                : BusNodeStatus.clampedCyan)) {
          clampDelta -= 0.45 * topo.nodeParam[i];
        }
      }
    }

    // Pulser conservation decays linearly to 0 as match approaches 0.0s.
    final double timeRatio =
        (initialPhaseTicksLeft / math.max(1, topo.liveDurationTicks))
            .clamp(0.0, 1.0);
    final double ammoBonus =
        state.pulsersRemainingFor(side) * 0.55 * timeRatio;

    return (myBus - oppBus) * 2.5 + latchDelta + clampDelta + ammoBonus;
  }
}

/// Stateful controller animating the enemy's rail probe cursor and humanized trigger cadence.
final class DroidProbeController {
  final ArenaSide side;
  final DroidPersona persona;
  final RolloutEvaluator evaluator;
  final Xoshiro128PlusPlus rng;

  double probePosition = 0.50;
  double _startPos = 0.50;
  double _targetPos = 0.50;

  int _cooldownTicks = 12;
  int _travelTicksTotal = 1;
  int _travelTicksElapsed = 0;
  int _hoverTicksRemaining = 0;

  int? _queuedRail;
  int? _bluffTargetRail;
  int? _comboFollowUpRail;
  int _comboFollowUpCountdown = -1;

  bool isHoveringTarget = false;

  DroidProbeController({
    required this.side,
    required this.persona,
    required BoardTacticalProfile profile,
    required this.rng,
  }) : evaluator = RolloutEvaluator(profile);

  /// Updates probe movement and returns a `railNodeId` to fire on this tick (or `null`).
  int? updateTick(ArenaState state) {
    final ArenaTopology topo = evaluator.profile.topology;
    if (state.phase != MatchPhase.liveCountdown) {
      isHoveringTarget = false;
      return null;
    }

    // Execute queued second half of a 2-Pulser AND combo if scheduled.
    if (_comboFollowUpRail != null) {
      if (_comboFollowUpCountdown <= 0) {
        final int follow = _comboFollowUpRail!;
        _comboFollowUpRail = null;
        probePosition = topo.nodeY[follow];
        if (state.canDeployOnRail(topo, side, follow)) {
          return follow;
        }
      } else {
        _comboFollowUpCountdown--;
        probePosition +=
            (topo.nodeY[_comboFollowUpRail!] - probePosition) * 0.35;
        return null;
      }
    }

    // Active travel/hover toward a chosen rail.
    if (_queuedRail != null) {
      if (_travelTicksElapsed < _travelTicksTotal) {
        _travelTicksElapsed++;
        final double t = (_travelTicksElapsed / _travelTicksTotal).clamp(0.0, 1.0);
        // Smoothstep easing so cursor movement reads naturally to the human eye.
        final double smooth = t * t * (3.0 - 2.0 * t);
        probePosition = _startPos + (_targetPos - _startPos) * smooth;
        isHoveringTarget = false;
        return null;
      }

      isHoveringTarget = true;
      if (_hoverTicksRemaining > 0) {
        _hoverTicksRemaining--;
        return null;
      }

      // If currently executing a bluff decoy hover, snap to the real target rail!
      if (_bluffTargetRail != null) {
        final int realTarget = _bluffTargetRail!;
        _bluffTargetRail = null;
        _queuedRail = realTarget;
        _startPos = probePosition;
        _targetPos = topo.nodeY[realTarget];
        _travelTicksTotal = math.max(2, persona.travelTicks ~/ 2);
        _travelTicksElapsed = 0;
        _hoverTicksRemaining = 2;
        isHoveringTarget = false;
        return null;
      }

      final int fireRail = _queuedRail!;
      _queuedRail = null;
      isHoveringTarget = false;
      _cooldownTicks = persona.evalIntervalTicks;
      if (state.canDeployOnRail(topo, side, fireRail)) {
        return fireRail;
      }
      return null;
    }

    if (_cooldownTicks > 0) {
      _cooldownTicks--;
      return null;
    }

    final AiActionPlan plan = evaluator.chooseAction(
      liveState: state,
      side: side,
      persona: persona,
      rng: rng,
    );

    if (plan.primaryRailNode == null) {
      _cooldownTicks = math.max(4, persona.evalIntervalTicks ~/ 2);
      return null;
    }

    final int chosenRail = plan.primaryRailNode!;
    if (plan.followUpRailNode != null) {
      _comboFollowUpRail = plan.followUpRailNode;
      _comboFollowUpCountdown = plan.followUpDelayTicks;
    }

    final Uint8List rails = topo.railsFor(side);
    if (rails.length > 2 &&
        plan.followUpRailNode == null &&
        rng.nextBool(persona.bluffProbability)) {
      int decoy = rails[rng.nextInt(rails.length)];
      if (decoy != chosenRail) {
        _queuedRail = decoy;
        _bluffTargetRail = chosenRail;
        _startPos = probePosition;
        _targetPos = topo.nodeY[decoy];
        _travelTicksTotal = math.max(2, persona.travelTicks);
        _travelTicksElapsed = 0;
        _hoverTicksRemaining = 5;
        return null;
      }
    }

    _queuedRail = chosenRail;
    _startPos = probePosition;
    _targetPos = topo.nodeY[chosenRail];
    _travelTicksTotal = math.max(1, persona.travelTicks);
    _travelTicksElapsed = 0;
    _hoverTicksRemaining = persona.hoverCommitTicks;
    return null;
  }
}
