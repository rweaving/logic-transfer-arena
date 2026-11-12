import 'dart:typed_data';

import '../ai/arena_ai.dart';
import '../math/xoshiro128pp.dart';
import '../sim/arena_solver.dart';
import '../sim/arena_state.dart';
import '../sim/arena_topology.dart';
import '../sim/signal_types.dart';

/// Diagnostic report returned by [FairnessValidator].
final class FairnessReport {
  final bool isValid;
  final int? minCycleDelayTicks;
  final double cyanViableRailRatio;
  final double amberViableRailRatio;
  final bool hasUncounterableTurnOneLockout;
  final bool underdogProvenSolvable;
  final String? failureReason;

  const FairnessReport({
    required this.isValid,
    required this.minCycleDelayTicks,
    required this.cyanViableRailRatio,
    required this.amberViableRailRatio,
    required this.hasUncounterableTurnOneLockout,
    required this.underdogProvenSolvable,
    this.failureReason,
  });
}

/// Automated pre-match circuit verifier enforcing GDD Section 6.2 invariants.
abstract final class FairnessValidator {
  static FairnessReport validate(
    ArenaTopology topology, {
    bool verifyUnderdogSolvable = false,
    int underdogAiCode = 742,
  }) {
    if (topology.leftRails.isEmpty || topology.rightRails.isEmpty) {
      return const FairnessReport(
        isValid: false,
        minCycleDelayTicks: null,
        cyanViableRailRatio: 0,
        amberViableRailRatio: 0,
        hasUncounterableTurnOneLockout: false,
        underdogProvenSolvable: false,
        failureReason: 'Board requires at least 1 Left Rail and 1 Right Rail.',
      );
    }
    if (topology.busNodes.isEmpty || topology.busNodes.length.isEven) {
      return const FairnessReport(
        isValid: false,
        minCycleDelayTicks: null,
        cyanViableRailRatio: 0,
        amberViableRailRatio: 0,
        hasUncounterableTurnOneLockout: false,
        underdogProvenSolvable: false,
        failureReason: 'Central Bus must contain an odd number of nodes.',
      );
    }

    // 1. Cycle delay check: every directed cycle must accumulate >= 4 ticks of gate delay.
    final int? minCycle = computeMinCycleDelay(topology);
    if (minCycle != null && minCycle < 4) {
      return FairnessReport(
        isValid: false,
        minCycleDelayTicks: minCycle,
        cyanViableRailRatio: 0,
        amberViableRailRatio: 0,
        hasUncounterableTurnOneLockout: false,
        underdogProvenSolvable: false,
        failureReason: 'Feedback cycle delay ($minCycle ticks) is below 4-tick minimum.',
      );
    }

    // 2. Causal rail viability: >= 80% of rails on each side must reach at least 1 Bus Node.
    final double cyanRatio = _viableRailRatio(topology, topology.leftRails);
    final double amberRatio = _viableRailRatio(topology, topology.rightRails);
    if (cyanRatio < 0.80 || amberRatio < 0.80) {
      return FairnessReport(
        isValid: false,
        minCycleDelayTicks: minCycle,
        cyanViableRailRatio: cyanRatio,
        amberViableRailRatio: amberRatio,
        hasUncounterableTurnOneLockout: false,
        underdogProvenSolvable: false,
        failureReason:
            'Insufficient viable causal rails (Cyan: $cyanRatio, Amber: $amberRatio).',
      );
    }

    // 3. Turn-1 lockout check (skip only on intentional Underdog challenges).
    final bool checkLockout =
        topology.archetype != BoardArchetype.underdogAsymmetric;
    final bool hasLockout =
        checkLockout ? _detectTurnOneLockout(topology) : false;
    if (hasLockout) {
      return FairnessReport(
        isValid: false,
        minCycleDelayTicks: minCycle,
        cyanViableRailRatio: cyanRatio,
        amberViableRailRatio: amberRatio,
        hasUncounterableTurnOneLockout: true,
        underdogProvenSolvable: false,
        failureReason: 'Uncounterable 1-Pulser majority lockout detected.',
      );
    }

    // 4. Optional bounded beam-search solvability proof for Daily Underdog puzzles.
    bool solvable = true;
    if (verifyUnderdogSolvable) {
      solvable = proveUnderdogCanWin(
        topology,
        aiCode: underdogAiCode,
      );
      if (!solvable) {
        return FairnessReport(
          isValid: false,
          minCycleDelayTicks: minCycle,
          cyanViableRailRatio: cyanRatio,
          amberViableRailRatio: amberRatio,
          hasUncounterableTurnOneLockout: false,
          underdogProvenSolvable: false,
          failureReason: 'Underdog beam-search solver found no winning sequence.',
        );
      }
    }

    return FairnessReport(
      isValid: true,
      minCycleDelayTicks: minCycle,
      cyanViableRailRatio: cyanRatio,
      amberViableRailRatio: amberRatio,
      hasUncounterableTurnOneLockout: false,
      underdogProvenSolvable: solvable,
    );
  }

  /// Returns the minimum tick delay across all simple directed cycles, or `null` if DAG.
  static int? computeMinCycleDelay(ArenaTopology topology) {
    final int n = topology.nodeCount;
    int? minCycle;

    for (int start = 0; start < n; start++) {
      // Bounded Dijkstra from neighbors of `start` back to `start`.
      final List<int> dist = List<int>.filled(n, 999999);
      final Uint8List visited = Uint8List(n);
      for (int e = topology.outEdgeStart[start];
          e < topology.outEdgeStart[start + 1];
          e++) {
        final int v = topology.outEdgeDst[e];
        final int d = topology.delayOf(v) < 1 ? 1 : topology.delayOf(v);
        if (d < dist[v]) dist[v] = d;
      }

      for (int step = 0; step < n; step++) {
        int u = -1;
        int best = 999999;
        for (int i = 0; i < n; i++) {
          if (visited[i] == 0 && dist[i] < best) {
            best = dist[i];
            u = i;
          }
        }
        if (u < 0) break;
        if (u == start) {
          if (minCycle == null || best < minCycle) {
            minCycle = best;
          }
          break;
        }
        visited[u] = 1;
        for (int e = topology.outEdgeStart[u];
            e < topology.outEdgeStart[u + 1];
            e++) {
          final int v = topology.outEdgeDst[e];
          final int addDelay =
              v == start ? 0 : (topology.delayOf(v) < 1 ? 1 : topology.delayOf(v));
          if (best + addDelay < dist[v]) {
            dist[v] = best + addDelay;
          }
        }
      }
    }
    return minCycle;
  }

  static double _viableRailRatio(ArenaTopology topology, Uint8List rails) {
    int viable = 0;
    for (final int r in rails) {
      if (topology.canReachBus(r)) viable++;
    }
    return viable / rails.length;
  }

  static bool _detectTurnOneLockout(ArenaTopology topology) {
    final int majorityThreshold = (topology.maxBusPoints ~/ 2) + 1;

    bool sideHasUncounterableOpener(ArenaSide attacker) {
      final ArenaSide defender = attacker.opponent;
      final Uint8List atkRails = topology.railsFor(attacker);
      final Uint8List defRails = topology.railsFor(defender);

      for (final int ar in atkRails) {
        // Quick check: does `ar` alone even reach majority?
        final ArenaState solo = ArenaState.initial(topology);
        ArenaSolver.deployPulser(topology, solo, attacker, ar);
        for (int t = 0; t < 110; t++) {
          ArenaSolver.step(topology, solo);
        }
        final ({int cyan, int amber, int neutral}) soloScore =
            solo.computeBusScore(topology);
        final int atkSoloPts =
            attacker == ArenaSide.cyan ? soloScore.cyan : soloScore.amber;
        if (atkSoloPts < majorityThreshold) continue;

        // Check whether defender has ANY 1-rail response that prevents attacker majority.
        bool counterFound = false;
        for (final int dr in defRails) {
          final ArenaState duel = ArenaState.initial(topology);
          ArenaSolver.deployPulser(topology, duel, attacker, ar);
          ArenaSolver.deployPulser(topology, duel, defender, dr);
          for (int t = 0; t < 110; t++) {
            ArenaSolver.step(topology, duel);
          }
          final ({int cyan, int amber, int neutral}) s =
              duel.computeBusScore(topology);
          final int atkPts = attacker == ArenaSide.cyan ? s.cyan : s.amber;
          final int defPts = defender == ArenaSide.cyan ? s.cyan : s.amber;
          if (atkPts < majorityThreshold || defPts >= atkPts) {
            counterFound = true;
            break;
          }
        }
        if (!counterFound) return true;
      }
      return false;
    }

    return sideHasUncounterableOpener(ArenaSide.cyan) ||
        sideHasUncounterableOpener(ArenaSide.amber);
  }

  /// Bounded beam-search solver checking if Cyan (underdog) has a winning play sequence vs AI.
  static bool proveUnderdogCanWin(
    ArenaTopology topology, {
    int aiCode = 742,
  }) {
    final BoardTacticalProfile profile = BoardTacticalProfile.analyze(topology);
    final DroidPersona persona = DroidPersona.forCode(aiCode);
    final List<int> decisionTicks = <int>[4, 70, 145, 215, 255];

    List<({ArenaState state, DroidProbeController ai, double score})> beam =
        <({ArenaState state, DroidProbeController ai, double score})>[
      (
        state: ArenaState.initial(topology),
        ai: DroidProbeController(
          side: ArenaSide.amber,
          persona: persona,
          profile: profile,
          rng: Xoshiro128PlusPlus.fromSeed(0xCAFE1234, aiCode),
        ),
        score: 0.0,
      ),
    ];

    int prevTick = 0;
    for (final int targetTick in decisionTicks) {
      // Advance existing beam candidates up to `targetTick`.
      for (final entry in beam) {
        while (entry.state.tick < targetTick &&
            entry.state.phase != MatchPhase.finished) {
          final int? aiRail = entry.ai.updateTick(entry.state);
          if (aiRail != null) {
            ArenaSolver.deployPulser(
              topology,
              entry.state,
              ArenaSide.amber,
              aiRail,
            );
          }
          ArenaSolver.step(topology, entry.state);
        }
      }
      prevTick = targetTick;

      // Branch Cyan choices: WAIT + each available Left Rail.
      final List<({ArenaState state, DroidProbeController ai, double score})>
          expanded = <({ArenaState state, DroidProbeController ai, double score})>[];

      for (final entry in beam) {
        expanded.add(entry);
        if (entry.state.cyanPulsersRemaining <= 0) continue;

        for (final int r in topology.leftRails) {
          if (!topology.canReachBus(r) ||
              !entry.state.canDeployOnRail(topology, ArenaSide.cyan, r)) {
            continue;
          }
          final ArenaState nextState = entry.state.clone();
          ArenaSolver.deployPulser(topology, nextState, ArenaSide.cyan, r);
          // Clone deterministic AI RNG stream at this decision point.
          final DroidProbeController nextAi = DroidProbeController(
            side: ArenaSide.amber,
            persona: persona,
            profile: profile,
            rng: entry.ai.rng.clone(),
          )..probePosition = entry.ai.probePosition;

          // Step 12 ticks to score immediate impact for beam pruning.
          for (int k = 0; k < 12 && nextState.phase != MatchPhase.finished; k++) {
            final int? aiRail = nextAi.updateTick(nextState);
            if (aiRail != null) {
              ArenaSolver.deployPulser(
                topology,
                nextState,
                ArenaSide.amber,
                aiRail,
              );
            }
            ArenaSolver.step(topology, nextState);
          }
          final ({int cyan, int amber, int neutral}) sc =
              nextState.computeBusScore(topology);
          final double val =
              (sc.cyan - sc.amber) * 2.0 + nextState.cyanPulsersRemaining * 0.4;
          expanded.add((state: nextState, ai: nextAi, score: val));
        }
      }

      expanded.sort((a, b) => b.score.compareTo(a.score));
      if (expanded.length > 10) {
        beam = expanded.sublist(0, 10);
      } else {
        beam = expanded;
      }
    }

    // Finish remaining match + overtime ticks for top beam candidates.
    assert(prevTick >= 0);
    for (final entry in beam) {
      while (entry.state.phase != MatchPhase.finished &&
          entry.state.tick < topology.liveDurationTicks + topology.maxOvertimeTicks + 5) {
        final int? aiRail = entry.ai.updateTick(entry.state);
        if (aiRail != null) {
          ArenaSolver.deployPulser(
            topology,
            entry.state,
            ArenaSide.amber,
            aiRail,
          );
        }
        ArenaSolver.step(topology, entry.state);
      }
      final ({int cyan, int amber, int neutral}) finalScore =
          entry.state.computeBusScore(topology);
      if (finalScore.cyan > finalScore.amber) {
        return true;
      }
    }
    return false;
  }
}
